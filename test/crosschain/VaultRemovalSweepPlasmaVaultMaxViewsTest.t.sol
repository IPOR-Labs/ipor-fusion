// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {CrosschainVaultActionLib} from "../../contracts/crosschain/lib/CrosschainVaultActionLib.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {VaultSweepHarness} from "./VaultRemovalSweepTest.t.sol";

/// @title VaultRemovalSweepPlasmaVaultMaxViewsTest
/// @notice IL-9624 follow-up, consumer test: the crosschain vault-removal sweep (`CrosschainVaultActionLib.sweepShares`)
///         against a real PlasmaVault that is closed or whose released-request reserve caps the position.
///         The sweep reads `maxRedeem(dispatcher)` with a 200,000 gas limit and redeems `min(balance, maxRedeem)`.
///         - Closed vault: `maxRedeem` is 0, so `redeem` is not called. Reason 3 (`SWEEP_PARTIAL`, untracked) without a
///           floor, reason 6 (`SWEEP_BELOW_MIN`, still tracked) with a floor.
///         - Capped position: the part below the reserve limit is redeemed (reason 3 without a floor or with a floor
///           the payout reaches), and a floor above the payout rolls the redeem back (reason 6, `SweepBelowMinimum`).
///         - Control: when the `maxRedeem` read fails the sweep takes the whole balance and the redeem reverts with the
///           WithdrawManager error (reason 2 without a floor), the old behaviour that the README describes.
/// @dev Fixture: management fee 2 %, performance fee 10 %, no redemption delay, a WithdrawManager wired to the vault
///      (`updatePlasmaVaultAddress`), a 6-decimal asset. The host (`VaultSweepHarness`, the dispatcher's stand-in)
///      holds 3,000,000 assets of shares, another holder 1,000,000. `setUp()` lets time pass, donates assets and
///      releases half of the supply through the real `releaseFunds`, so both fees are pending (asserted) and the
///      reserve limit is below the host's balance. The expected `maxRedeem` and payout are stored in `setUp()`; the
///      test functions start with the sweep as the first interaction with the vault, the access manager, the
///      WithdrawManager and the FeeManager (`_coolTouchedAccounts` makes this hold under forge 1.9.0 whatever
///      `setUp()` warmed). The redeemed amount being exactly the stored `maxRedeem` proves that the cold read fits in
///      the 200,000 gas limit; otherwise the sweep would take the whole balance.
contract VaultRemovalSweepPlasmaVaultMaxViewsTest is Test {
    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    address public atomist = address(this);
    address public alpha = address(0x1);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 10%
    uint256 public constant PERFORMANCE_FEE = 1000;
    uint8 internal constant ASSET_DECIMALS = 6;
    uint8 internal constant REASON_NONE = 0;
    uint8 internal constant REASON_REVERTED = 2;
    uint8 internal constant REASON_PARTIAL = 3;
    uint8 internal constant REASON_BELOW_MIN = 6;

    bytes4 internal constant INVALID_SHARES_TO_RELEASE =
        bytes4(keccak256("WithdrawManagerInvalidSharesToRelease(uint256,uint256,uint256)"));

    MockERC20Decimals public asset;
    UsersToRoles internal usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    VaultSweepHarness public host;
    FeeManager internal feeManager;

    /// @dev one whole asset in its smallest unit
    uint256 internal unit;

    // Scenario values prepared in setUp()
    uint256 internal hostBalance;
    uint256 internal expectedMaxRedeem;
    uint256 internal expectedPayout;
    uint256 internal fullPositionValue;

    function setUp() public {
        unit = 10 ** ASSET_DECIMALS;
        _deploy();
        _wireWithdrawManager();
        host = new VaultSweepHarness(address(asset));
        feeManager = FeeManager(
            FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
        );

        _fund(address(this), 3_000_000 * unit);
        _fund(other, 1_000_000 * unit);
        plasmaVault.deposit(3_000_000 * unit, address(host));
        vm.prank(other);
        plasmaVault.deposit(1_000_000 * unit, other);

        // time passes (management fee), assets are donated (rate above the high-water mark, performance fee)
        vm.warp(block.timestamp + 30 days);
        asset.mint(address(plasmaVault), 100_000 * unit);
        assertGt(_managementFeeShares(), 0, "precondition: management fee shares are pending");
        assertGt(_crystallizedPerformanceFeeShares(), 0, "precondition: performance fee shares are pending");

        // ALPHA releases half of the supply: the reserve limit drops below the host's balance
        uint256 released = plasmaVault.totalSupply() / 2;
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, released);
        assertEq(withdrawManager.getSharesToRelease(), released, "precondition: shares released");

        hostBalance = plasmaVault.balanceOf(address(host));
        expectedMaxRedeem = _expectedReserveLimit(released);
        expectedPayout = plasmaVault.previewRedeem(expectedMaxRedeem);
        fullPositionValue = plasmaVault.previewRedeem(hostBalance);
        assertGt(expectedMaxRedeem, 0, "precondition: reserve limit positive");
        assertGe(
            hostBalance,
            expectedMaxRedeem + 5 * unit * _shareScale(),
            "precondition: the balance exceeds the reserve limit by at least five whole assets"
        );
        assertGt(plasmaVault.convertToAssets(hostBalance), unit / 100, "precondition: position is not dust");
        assertGt(expectedPayout, 0, "precondition: payout positive");
        assertGt(fullPositionValue, expectedPayout, "precondition: the full position is worth more than the payout");
    }

    // ---------------------------------------------------------------------------------------------
    // (a), (b) closed vault
    // ---------------------------------------------------------------------------------------------

    /// @dev (a) closed, no floor: redeem is not called, reason 3, the vault stops being tracked
    function testShouldNotCallRedeemAndUntrack_whenVaultClosedAndNoFloor() public {
        accessManager.updateTargetClosed(address(plasmaVault), true);

        vm.expectCall(address(plasmaVault), abi.encodeWithSelector(IERC4626.redeem.selector), 0);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(address(plasmaVault), hostBalance, REASON_PARTIAL, bytes4(0), true);
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweep(address(plasmaVault));

        assertEq(redeemed, 0, "nothing redeemed");
        assertEq(assetsLD, 0, "no assets");
        assertEq(left, hostBalance, "the whole position stays");
        assertEq(reason, REASON_PARTIAL, "reason 3");
        assertEq(err, bytes4(0), "no redeem error: redeem was not called");
        assertEq(plasmaVault.balanceOf(address(host)), hostBalance, "shares untouched");
        assertEq(plasmaVault.maxRedeem(address(host)), 0, "maxRedeem is 0 while closed");
    }

    /// @dev (b) closed, floor above zero: redeem is not called, reason 6, the vault stays tracked
    function testShouldNotCallRedeemAndKeepTracking_whenVaultClosedAndFloorSet() public {
        accessManager.updateTargetClosed(address(plasmaVault), true);

        vm.expectCall(address(plasmaVault), abi.encodeWithSelector(IERC4626.redeem.selector), 0);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(address(plasmaVault), hostBalance, REASON_BELOW_MIN, bytes4(0), false);
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweepFloored(
            address(plasmaVault),
            unit
        );

        assertEq(redeemed, 0, "nothing redeemed");
        assertEq(assetsLD, 0, "no assets");
        assertEq(left, hostBalance, "the whole position stays");
        assertEq(reason, REASON_BELOW_MIN, "reason 6");
        assertEq(err, bytes4(0), "no redeem error: redeem was not called");
        assertEq(plasmaVault.balanceOf(address(host)), hostBalance, "shares untouched");
    }

    // ---------------------------------------------------------------------------------------------
    // (c), (d), (e) position capped by the released-request reserve, both fees pending, cold read
    // ---------------------------------------------------------------------------------------------

    /// @dev (c) capped, no floor: exactly maxRedeem is redeemed (so the cold read fit in 200,000 gas), the rest stays,
    ///      reason 3, untracked
    function testShouldRedeemMaxRedeemOnly_whenPositionCappedAndNoFloor() public {
        _coolTouchedAccounts();

        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSwept(address(plasmaVault), expectedMaxRedeem, expectedPayout);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(
            address(plasmaVault),
            hostBalance - expectedMaxRedeem,
            REASON_PARTIAL,
            bytes4(0),
            true
        );
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweep(address(plasmaVault));

        _assertPartialSweep(redeemed, assetsLD, left, reason, err);
    }

    /// @dev (d) capped, floor not above the payout: the same as (c)
    function testShouldRedeemMaxRedeemOnly_whenPositionCappedAndFloorNotAbovePayout() public {
        _coolTouchedAccounts();

        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSwept(address(plasmaVault), expectedMaxRedeem, expectedPayout);
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(
            address(plasmaVault),
            hostBalance - expectedMaxRedeem,
            REASON_PARTIAL,
            bytes4(0),
            true
        );
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweepFloored(
            address(plasmaVault),
            expectedPayout
        );

        _assertPartialSweep(redeemed, assetsLD, left, reason, err);
    }

    /// @dev (e) capped, floor above the payout: the redeem is rolled back, nothing is burned, reason 6, the vault
    ///      stays tracked, `err` is `SweepBelowMinimum`
    function testShouldRollBackAndKeepTracking_whenPositionCappedAndFloorAbovePayout() public {
        _coolTouchedAccounts();

        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(
            address(plasmaVault),
            hostBalance,
            REASON_BELOW_MIN,
            CrosschainVaultActionLib.SweepBelowMinimum.selector,
            false
        );
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweepFloored(
            address(plasmaVault),
            fullPositionValue
        );

        assertEq(redeemed, 0, "nothing burned");
        assertEq(assetsLD, 0, "no assets received");
        assertEq(left, hostBalance, "the whole position stays");
        assertEq(reason, REASON_BELOW_MIN, "reason 6");
        assertEq(err, CrosschainVaultActionLib.SweepBelowMinimum.selector, "SweepBelowMinimum");
        assertEq(plasmaVault.balanceOf(address(host)), hostBalance, "shares untouched");
    }

    /// @dev (e2) the boundary: a floor one unit above the payout of the capped redeem rolls it back, while a floor equal
    ///      to the payout passes (test d). Nothing is burned and no asset is received
    function testShouldRollBackAndKeepTracking_whenFloorOneAbovePayout() public {
        _coolTouchedAccounts();

        uint256 assetsBefore = asset.balanceOf(address(host));
        vm.expectEmit(false, false, false, true, address(host));
        emit TrackedVaultSweepResidual(
            address(plasmaVault),
            hostBalance,
            REASON_BELOW_MIN,
            CrosschainVaultActionLib.SweepBelowMinimum.selector,
            false
        );
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweepFloored(
            address(plasmaVault),
            expectedPayout + 1
        );

        assertEq(redeemed, 0, "nothing burned");
        assertEq(assetsLD, 0, "no assets received");
        assertEq(left, hostBalance, "the whole position stays");
        assertEq(reason, REASON_BELOW_MIN, "reason 6");
        assertEq(err, CrosschainVaultActionLib.SweepBelowMinimum.selector, "SweepBelowMinimum");
        assertEq(plasmaVault.balanceOf(address(host)), hostBalance, "shares untouched");
        assertEq(asset.balanceOf(address(host)), assetsBefore, "no asset receipt on the host");
    }

    // ---------------------------------------------------------------------------------------------
    // (f) control: the maxRedeem read fails
    // ---------------------------------------------------------------------------------------------

    /// @dev (f) control, pins the README statement: when the `maxRedeem` read fails (here the FeeManager reverts), the
    ///      sweep takes the whole balance and the redeem reverts with the WithdrawManager error, reason 2, nothing
    ///      burned. Passes on the base too (there `maxRedeem` is the balance and the same redeem reverts)
    function testShouldTakeWholeBalanceAndRevert_whenMaxRedeemReadFails() public {
        vm.mockCallRevert(
            address(feeManager),
            abi.encodeWithSelector(FeeManager.pendingPerformanceFeeShares.selector),
            abi.encodeWithSignature("Error(string)", "fee manager down")
        );

        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweep(address(plasmaVault));

        assertEq(redeemed, 0, "nothing burned");
        assertEq(assetsLD, 0, "no assets received");
        assertEq(left, hostBalance, "the whole position stays");
        assertEq(reason, REASON_REVERTED, "reason 2");
        assertEq(err, INVALID_SHARES_TO_RELEASE, "the WithdrawManager error");
    }

    // ---------------------------------------------------------------------------------------------
    // Cold read cost (reported, not asserted)
    // ---------------------------------------------------------------------------------------------

    /// @dev Reports the gas of the first `maxRedeem(host)` call of the test (cold accounts, both fees pending, R > 0),
    ///      against the 200,000 gas limit of the sweep read. Not asserted: a number to read in the log
    function testGasReportComparableColdMaxRedeemForSweep() public {
        _coolTouchedAccounts();
        plasmaVault.maxRedeem(address(host));
        uint256 coldGas = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("cold maxRedeem(host) gas, R > 0, both fees pending", coldGas);
        assertLt(coldGas, 200_000, "the cold read fits in the sweep read limit");
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _assertPartialSweep(
        uint256 redeemed_,
        uint256 assetsLD_,
        uint256 left_,
        uint8 reason_,
        bytes4 err_
    ) internal view {
        assertEq(redeemed_, expectedMaxRedeem, "exactly maxRedeem redeemed: the read fit in the gas limit");
        assertLt(redeemed_, hostBalance, "not the whole balance");
        assertEq(assetsLD_, expectedPayout, "payout");
        assertEq(left_, hostBalance - expectedMaxRedeem, "the rest stays on the host");
        assertEq(reason_, REASON_PARTIAL, "reason 3");
        assertEq(err_, bytes4(0), "no error");
        assertEq(plasmaVault.balanceOf(address(host)), left_, "balance after the sweep");
        assertEq(asset.balanceOf(address(host)), assetsLD_, "assets on the host");
    }

    /// @dev setUp() touched the vault, its access manager, the WithdrawManager, the FeeManager and the asset; the sweep
    ///      must be their first user in the test function, so the read is priced cold. The accounts of the read
    ///      `maxRedeem(host)` (the clone, the clone implementation, the linked `PlasmaVaultFeesLib`, the managers, the
    ///      performance FeeAccount, the asset) are recorded in a snapshot and cooled with `vm.cool`
    function _coolTouchedAccounts() internal {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        (bool ok, ) = address(plasmaVault).staticcall(abi.encodeCall(PlasmaVault.maxRedeem, (address(host))));
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.revertToState(snapshot);
        assertTrue(ok, "the recorded read succeeds");
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(this)) {
                vm.cool(accesses[i].account);
            }
        }
        vm.cool(address(plasmaVault));
        vm.cool(address(accessManager));
        vm.cool(address(withdrawManager));
        vm.cool(address(feeManager));
        vm.cool(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount);
        vm.cool(address(asset));
        vm.cool(address(host));
    }

    /// @dev max(C - R, 0) with C = floor(G * (S* + scale) / (G + 1)): all gross assets G in shares on the supply S*
    ///      after both pending fees. Computed here from the vault's public views, not through `maxRedeem` (which a
    ///      sweep reads cold, and which the base does not cap), so `setUp()` also runs on the base
    function _expectedReserveLimit(uint256 released_) internal returns (uint256) {
        uint256 gross = plasmaVault.totalAssets();
        uint256 supplyAfterFees = plasmaVault.totalSupply() +
            _managementFeeShares() +
            _crystallizedPerformanceFeeShares();
        uint256 all = Math.mulDiv(gross, supplyAfterFees + _shareScale(), gross + 1);
        return all > released_ ? all - released_ : 0;
    }

    function _shareScale() internal view returns (uint256) {
        return 10 ** (plasmaVault.decimals() - asset.decimals());
    }

    /// @dev Performance fee shares that an exit mints now: another holder withdraws one unit in a snapshot (the state
    ///      is restored)
    function _crystallizedPerformanceFeeShares() internal returns (uint256 feeShares) {
        address feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        uint256 snapshot = vm.snapshotState();
        uint256 before = plasmaVault.balanceOf(feeAccount);
        vm.prank(other);
        plasmaVault.withdraw(unit, other, other);
        feeShares = plasmaVault.balanceOf(feeAccount) - before;
        vm.revertToState(snapshot);
    }

    /// @dev IL-8870 (D-002): management fee shares V = floor(min(F, G) * (S + scale) / (G - min(F, G) + 1)),
    ///      recomputed from the accrued fee F, the supply S and the gross assets G, not through the vault
    function _managementFeeShares() internal view returns (uint256) {
        uint256 gross = plasmaVault.totalAssets();
        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        if (fee == 0) {
            return 0;
        }
        if (fee > gross) {
            fee = gross;
        }
        return Math.mulDiv(fee, plasmaVault.totalSupply() + _shareScale(), gross - fee + 1);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }

    /// @dev `RoleLib` and the configurator do not call `updatePlasmaVaultAddress`: an unwired manager skips the supply
    ///      bound of `releaseFunds`. The ATOMIST role is mapped to the selector like for `updateWithdrawFee`
    function _wireWithdrawManager() internal {
        bytes4[] memory atomistSigs = new bytes4[](1);
        atomistSigs[0] = WithdrawManager.updatePlasmaVaultAddress.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), atomistSigs, Roles.ATOMIST_ROLE);

        withdrawManager.updatePlasmaVaultAddress(address(plasmaVault));
        assertEq(withdrawManager.getPlasmaVaultAddress(), address(plasmaVault), "withdraw manager wired");
    }

    function _deploy() internal {
        asset = new MockERC20Decimals("Mock Asset", "mAST", ASSET_DECIMALS);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mAST",
                "ipfmAST",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );
    }
}
