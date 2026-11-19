// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultMaxViewsCostTest
/// @notice IL-9624 follow-up (D-007): the cost of the max views and of the entry paths. Structural cost is pinned with
///         call counts (`vm.expectCall` with a count), not with gas numbers: the entries read `isTargetClosed` once
///         more than before (the OpenZeppelin `deposit` / `mint` check `maxDeposit` / `maxMint` inside the call), and
///         `maxWithdraw` / `maxRedeem` value the gross assets and the pending fees once per call when request shares
///         are released (R > 0). With R = 0 `maxRedeem` makes no valuation. The gas reports emit the gas used and
///         assert nothing on the numbers: `testGasReportComparable...` run on the base and on the head,
///         `testGasReportHeadOnly...` only on the head.
/// @dev Fixture: management fee 2 %, performance fee 10 %, no withdraw fee, a WithdrawManager wired to the vault, all
///      assets idle. The scenario (time passes, assets donated, request shares released) is prepared in `setUp` so
///      that the measured call is the first interaction of its test. Each call count test sets exactly one
///      `vm.expectCall` and then makes only the measured call.
contract PlasmaVaultMaxViewsCostTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    uint256 public constant MANAGEMENT_FEE = 200;
    uint256 public constant PERFORMANCE_FEE = 1000;
    uint256 internal constant UNIT = 1e6;

    MockERC20Decimals public asset;
    UsersToRoles internal usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    address internal feeManager;

    function setUp() public {
        _deploy();
        _wireWithdrawManager();

        _fund(user, 3_000_000 * UNIT);
        _fund(other, 1_000_000 * UNIT);
        _deposit(user, 3_000_000 * UNIT);
        _deposit(other, 1_000_000 * UNIT);

        feeManager = FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount)
            .FEE_MANAGER();

        /// @dev both fees pending: time passes (management fee), assets are donated (performance fee)
        vm.warp(block.timestamp + 30 days);
        asset.mint(address(plasmaVault), 100_000 * UNIT);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "precondition: management fee pending");
        assertGt(_pendingPerformanceFeeShares(), 0, "precondition: performance fee shares pending");

        /// @dev funds for the entry tests (the user spent its funds on the setup deposit)
        asset.mint(user, 10_000 * UNIT);
    }

    // ---------------------------------------------------------------------------------------------
    // Call counts: entries (one more access manager read)
    // ---------------------------------------------------------------------------------------------

    /// @dev Fails on the base: deposit read no closed flag there (0 reads)
    function testShouldReadIsTargetClosedOncePerDeposit() public {
        vm.expectCall(address(accessManager), _isTargetClosedCall(), 1);
        vm.prank(user);
        plasmaVault.deposit(1_000 * UNIT, user);
    }

    /// @dev Fails on the base: mint read no closed flag there (0 reads)
    function testShouldReadIsTargetClosedOncePerMint() public {
        vm.expectCall(address(accessManager), _isTargetClosedCall(), 1);
        vm.prank(user);
        plasmaVault.mint(1_000 * UNIT, user);
    }

    /// @dev The asset has no `permit`: the call falls back to the allowance. Fails on the base (0 reads)
    function testShouldReadIsTargetClosedOncePerDepositWithPermit() public {
        vm.expectCall(address(accessManager), _isTargetClosedCall(), 1);
        vm.prank(user);
        plasmaVault.depositWithPermit(1_000 * UNIT, user, block.timestamp, 0, bytes32(0), bytes32(0));
    }

    // ---------------------------------------------------------------------------------------------
    // Call counts: one valuation per max view call
    // ---------------------------------------------------------------------------------------------

    /// @dev Control (also one valuation on the base): guards against a second valuation in `maxWithdraw` with R > 0
    function testShouldValueOncePerMaxWithdraw_whenSharesReleased() public {
        _release();
        vm.expectCall(address(asset), _assetBalanceCall(), 1);
        plasmaVault.maxWithdraw(user);
    }

    function testShouldPriceFeesOncePerMaxWithdraw_whenSharesReleased() public {
        _release();
        vm.expectCall(feeManager, _pendingPerformanceFeeSharesSelector(), 1);
        plasmaVault.maxWithdraw(user);
    }

    /// @dev Fails on the base: `maxRedeem` made no valuation there (0 reads)
    function testShouldValueOncePerMaxRedeem_whenSharesReleased() public {
        _release();
        vm.expectCall(address(asset), _assetBalanceCall(), 1);
        plasmaVault.maxRedeem(user);
    }

    /// @dev Fails on the base: `maxRedeem` made no fee valuation there (0 calls)
    function testShouldPriceFeesOncePerMaxRedeem_whenSharesReleased() public {
        _release();
        vm.expectCall(feeManager, _pendingPerformanceFeeSharesSelector(), 1);
        plasmaVault.maxRedeem(user);
    }

    /// @dev Control: with R = 0 `maxRedeem` is the balance and reads the asset balance of the vault zero times
    function testShouldNotValueMaxRedeem_whenNothingReleased() public {
        assertEq(withdrawManager.getSharesToRelease(), 0, "precondition: nothing released");
        vm.expectCall(address(asset), _assetBalanceCall(), 0);
        assertEq(plasmaVault.maxRedeem(user), plasmaVault.balanceOf(user), "maxRedeem is the balance");
    }

    /// @dev Control: with R = 0 `maxRedeem` does not call the FeeManager either
    function testShouldNotPriceFeesInMaxRedeem_whenNothingReleased() public {
        vm.expectCall(feeManager, _pendingPerformanceFeeSharesSelector(), 0);
        plasmaVault.maxRedeem(user);
    }

    // ---------------------------------------------------------------------------------------------
    // Gas reports (no assertions on the numbers). Warm method: the second identical call is measured.
    // ---------------------------------------------------------------------------------------------

    function testGasReportComparableDeposit() public {
        vm.prank(user);
        plasmaVault.deposit(1_000 * UNIT, user);
        vm.prank(user);
        plasmaVault.deposit(1_000 * UNIT, user);
        emit log_named_uint("gas deposit (warm)", vm.lastCallGas().gasTotalUsed);
    }

    function testGasReportComparableMint() public {
        vm.prank(user);
        plasmaVault.mint(1_000 * UNIT, user);
        vm.prank(user);
        plasmaVault.mint(1_000 * UNIT, user);
        emit log_named_uint("gas mint (warm)", vm.lastCallGas().gasTotalUsed);
    }

    function testGasReportComparableDepositWithPermit() public {
        vm.prank(user);
        plasmaVault.depositWithPermit(1_000 * UNIT, user, block.timestamp, 0, bytes32(0), bytes32(0));
        vm.prank(user);
        plasmaVault.depositWithPermit(1_000 * UNIT, user, block.timestamp, 0, bytes32(0), bytes32(0));
        emit log_named_uint("gas depositWithPermit (warm)", vm.lastCallGas().gasTotalUsed);
    }

    function testGasReportComparableMaxWithdrawNothingReleased() public {
        plasmaVault.maxWithdraw(user);
        plasmaVault.maxWithdraw(user);
        emit log_named_uint("gas maxWithdraw R=0 (warm)", vm.lastCallGas().gasTotalUsed);
    }

    function testGasReportComparableMaxRedeemNothingReleased() public {
        plasmaVault.maxRedeem(user);
        plasmaVault.maxRedeem(user);
        emit log_named_uint("gas maxRedeem R=0 (warm)", vm.lastCallGas().gasTotalUsed);
    }

    function testGasReportComparableMaxWithdrawSharesReleased() public {
        _release();
        plasmaVault.maxWithdraw(user);
        plasmaVault.maxWithdraw(user);
        emit log_named_uint("gas maxWithdraw R>0 (warm)", vm.lastCallGas().gasTotalUsed);
    }

    function testGasReportComparableMaxRedeemSharesReleased() public {
        _release();
        plasmaVault.maxRedeem(user);
        plasmaVault.maxRedeem(user);
        emit log_named_uint("gas maxRedeem R>0 (warm)", vm.lastCallGas().gasTotalUsed);
    }

    /// @dev Cold read with R > 0 and both fees pending: the scenario is prepared in `setUp`, the test only measures
    ///      the first read. Before it, every account that the read touches (the clone, the clone implementation, the
    ///      linked `PlasmaVaultFeesLib`, the access manager, the WithdrawManager, the FeeManager, the performance
    ///      FeeAccount and the asset) is cooled with `vm.cool`, the set being recorded from the same call in a
    ///      snapshot. No call to the vault is made between the cooling and the measured call. Compare the number with
    ///      the 200,000 gas read limit of the crosschain vault-removal sweep
    function testGasReportComparableMaxRedeemSharesReleasedCold() public {
        _releaseShares();
        _coolDependenciesOf(abi.encodeCall(PlasmaVault.maxRedeem, (user)));
        plasmaVault.maxRedeem(user);
        uint256 coldGas = vm.lastCallGas().gasTotalUsed;
        emit log_named_uint("gas maxRedeem R>0 (cold)", coldGas);
        assertLt(coldGas, 200_000, "cold maxRedeem fits in the sweep read limit");
        assertGt(plasmaVault.maxRedeem(user), 0, "maxRedeem positive");
    }

    function testGasReportComparableMaxWithdrawSharesReleasedCold() public {
        _releaseShares();
        _coolDependenciesOf(abi.encodeCall(PlasmaVault.maxWithdraw, (user)));
        plasmaVault.maxWithdraw(user);
        emit log_named_uint("gas maxWithdraw R>0 (cold)", vm.lastCallGas().gasTotalUsed);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev ALPHA releases half of the supply through the real `releaseFunds`; makes no read of the max views
    function _releaseShares() internal {
        uint256 released = plasmaVault.totalSupply() / 2;
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, released);
        assertEq(withdrawManager.getSharesToRelease(), released, "precondition: shares released");
    }

    function _release() internal {
        _releaseShares();
        assertGt(plasmaVault.maxRedeem(user), 0, "precondition: maxRedeem positive");
    }

    /// @dev Cools every account that `callData_` touches on the vault: the call is made once in a snapshot under
    ///      state diff recording, the state is restored, then each recorded account (clone, clone implementation,
    ///      linked library, managers, FeeAccount, asset) is cooled. The same code runs on the base and on the head
    function _coolDependenciesOf(bytes memory callData_) internal {
        uint256 snapshot = vm.snapshotState();
        vm.startStateDiffRecording();
        (bool ok, ) = address(plasmaVault).staticcall(callData_);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        vm.revertToState(snapshot);
        assertTrue(ok, "the recorded call succeeds");
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != address(this)) {
                vm.cool(accesses[i].account);
            }
        }
        vm.cool(address(plasmaVault));
        vm.cool(address(asset));
        vm.cool(address(accessManager));
        vm.cool(address(withdrawManager));
        vm.cool(feeManager);
        vm.cool(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount);
    }

    /// @dev Performance fee shares that an exit mints now: another holder withdraws one unit in a snapshot (the state
    ///      is restored)
    function _pendingPerformanceFeeShares() internal returns (uint256 feeShares) {
        address feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        uint256 snapshot = vm.snapshotState();
        uint256 before = plasmaVault.balanceOf(feeAccount);
        vm.prank(other);
        plasmaVault.withdraw(UNIT, other, other);
        feeShares = plasmaVault.balanceOf(feeAccount) - before;
        vm.revertToState(snapshot);
    }

    function _isTargetClosedCall() internal view returns (bytes memory) {
        return abi.encodeWithSignature("isTargetClosed(address)", address(plasmaVault));
    }

    function _assetBalanceCall() internal view returns (bytes memory) {
        return abi.encodeCall(IERC20.balanceOf, (address(plasmaVault)));
    }

    function _pendingPerformanceFeeSharesSelector() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes4(keccak256("pendingPerformanceFeeShares(uint128,uint256,uint256)")));
    }

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
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
        asset = new MockERC20Decimals("Mock Asset", "mAST", 6);

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
