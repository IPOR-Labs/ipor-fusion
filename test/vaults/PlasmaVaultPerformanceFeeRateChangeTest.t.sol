// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {
    PlasmaVault,
    FuseAction,
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
import {FeeManagerFactory, FeeConfig, RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title Performance fee rate change is not retroactive (IL-9632, Olympix 2026-11-06 L01)
/// @notice Before IL-9632 `FeeManager.updatePerformanceFee` harvested the shares already minted and wrote the new
///         rate and recipient split, but did not crystallize first. The gain above the high-water mark that accrued
///         under the old rate was charged at the next crystallization at the NEW rate and paid to the NEW recipients.
///         With IL-9632 the FeeManager first calls `PlasmaVault.realizePerformanceFee()` (the vault's regular
///         crystallization), harvests the minted shares to the old recipients and only then writes the new settings.
/// @dev The vault is set up through the production role initializer (`IporFusionAccessManagerInitializerLibV1`), so
///      the FeeManager reaches `realizePerformanceFee` with the role the initializer maps. All economic assertions are
///      in asset terms (`convertToAssets`), never in high-water-mark units, so the file compiles and runs against the
///      code before IL-9632 and IL-9601 (base copy); the new entry is called through `abi.encodeWithSignature`.
///      Gains and losses are applied to the idle balance of the vault, which `totalAssets()` reads live.
contract PlasmaVaultPerformanceFeeRateChangeTest is Test {
    address public constant OWNER = address(0x0E1);
    address public constant ATOMIST = address(0xA70);
    address public constant ALPHA = address(0xA1FA);
    address public constant USER = address(0xA11CE);
    address public constant CURATOR = address(0xC0FFEE);
    address public constant NEW_CURATOR = address(0xBEEF);
    address public constant DAO_RECIPIENT = address(98989898);
    address public constant DUMMY_MANAGER = address(0x123);

    /// @dev FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant DAO_PERFORMANCE_FEE = 500;
    /// @dev curator part of the old 10% total (DAO 5% + curator 5%)
    uint256 public constant OLD_CURATOR_FEE = 500;
    /// @dev curator part of the new 50% total (DAO 5% + curator 45%)
    uint256 public constant NEW_CURATOR_FEE = 4500;
    uint256 public constant OLD_TOTAL_FEE = DAO_PERFORMANCE_FEE + OLD_CURATOR_FEE;
    uint256 public constant NEW_TOTAL_FEE = DAO_PERFORMANCE_FEE + NEW_CURATOR_FEE;

    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    /// @dev 10% of the deposit
    uint256 public constant GAIN = 100_000e6;
    /// @dev 0.01% relative tolerance (1e18 = 100%) on fee values; 10% and 50% differ by a factor of 5
    uint256 public constant REL_TOLERANCE = 1e14;

    MockERC20Decimals public asset;
    IporFusionAccessManager public accessManager;
    PlasmaVault public plasmaVault;
    FeeManager public feeManager;
    address public performanceFeeAccount;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        _deployVault();

        _setPerformanceRecipient(CURATOR, OLD_CURATOR_FEE);
        assertEq(_vaultPerformanceFee(), OLD_TOTAL_FEE, "setUp: vault rate is the old 10% total");

        asset.mint(USER, USER_DEPOSIT);
        vm.startPrank(USER);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(USER_DEPOSIT, USER);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------
    // L01 - the gain earned under the old rate is charged at the old rate and paid to the old split
    // ---------------------------------------------------------------------------------------------

    /// @dev Gain of 10% at a 10% fee, then a raise to 50%. Before IL-9632 the next crystallization charged 50% of the
    ///      gain earned under the 10% rate; with IL-9632 the change crystallizes 10% of it first.
    function testShouldChargeGainEarnedBeforeRaiseAtOldRate() public {
        // given
        uint256 userShares = plasmaVault.balanceOf(USER);
        asset.mint(address(plasmaVault), GAIN);

        // when
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        _crystallize();
        feeManager.harvestPerformanceFee();

        // then
        assertEq(_vaultPerformanceFee(), NEW_TOTAL_FEE, "new 50% total stored");
        assertApproxEqRel(
            _totalFeeValue(),
            (GAIN * OLD_TOTAL_FEE) / 10000,
            REL_TOLERANCE,
            "fee on the gain before the raise is 10% of it, not 50%"
        );
        assertApproxEqRel(
            plasmaVault.convertToAssets(userShares),
            USER_DEPOSIT + (GAIN * (10000 - OLD_TOTAL_FEE)) / 10000,
            REL_TOLERANCE,
            "depositor keeps 90% of the gain earned under the old rate"
        );
    }

    /// @dev The shares crystallized at the change are harvested before the new split is written: the DAO and the old
    ///      curator each receive half of the 10% fee (DAO 500 / total 1000)
    function testShouldPayGainEarnedBeforeRaiseToOldSplit() public {
        // given
        asset.mint(address(plasmaVault), GAIN);

        // when
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);

        // then
        uint256 oldFee = (GAIN * OLD_TOTAL_FEE) / 10000;
        assertApproxEqRel(
            _value(DAO_RECIPIENT),
            (oldFee * DAO_PERFORMANCE_FEE) / OLD_TOTAL_FEE,
            REL_TOLERANCE,
            "DAO received its old-split part (1/2) of the 10% fee in the update call"
        );
        assertApproxEqRel(
            _value(CURATOR),
            (oldFee * OLD_CURATOR_FEE) / OLD_TOTAL_FEE,
            REL_TOLERANCE,
            "curator received its old-split part (1/2) of the 10% fee in the update call"
        );
        assertLe(plasmaVault.balanceOf(performanceFeeAccount), 2, "fee account harvested in the update call");
    }

    /// @dev Recipient change with the same total: the gain before the change goes to the old curator, nothing of it
    ///      to the new one (before IL-9632 the next harvest paid it to the new curator)
    function testShouldPayGainEarnedBeforeRecipientChangeToOldRecipient() public {
        // given
        asset.mint(address(plasmaVault), GAIN);

        // when
        _setPerformanceRecipient(NEW_CURATOR, OLD_CURATOR_FEE);
        _crystallize();
        feeManager.harvestPerformanceFee();

        // then
        assertEq(_vaultPerformanceFee(), OLD_TOTAL_FEE, "total unchanged");
        uint256 oldFee = (GAIN * OLD_TOTAL_FEE) / 10000;
        assertApproxEqRel(
            _value(CURATOR),
            (oldFee * OLD_CURATOR_FEE) / OLD_TOTAL_FEE,
            REL_TOLERANCE,
            "old curator paid for the gain before the change"
        );
        assertEq(plasmaVault.balanceOf(NEW_CURATOR), 0, "new curator gets nothing of the gain before the change");
    }

    /// @dev Symmetric case: a cut from 50% to 10% does not forgive the fee owed at 50% on the gain before the cut
    function testShouldChargeGainEarnedBeforeCutAtOldRate() public {
        // given - raise to 50% while there is no gain (nothing to crystallize), then a gain of 10%
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "no fee minted by a change without a gain");
        asset.mint(address(plasmaVault), GAIN);

        // when
        _setPerformanceRecipient(CURATOR, OLD_CURATOR_FEE);
        _crystallize();
        feeManager.harvestPerformanceFee();

        // then
        assertEq(_vaultPerformanceFee(), OLD_TOTAL_FEE, "cut to the 10% total stored");
        assertApproxEqRel(
            _totalFeeValue(),
            (GAIN * NEW_TOTAL_FEE) / 10000,
            REL_TOLERANCE,
            "fee on the gain before the cut is 50% of it, not 10%"
        );
    }

    /// @dev The new rate applies to the gain after the change: 10% of the first gain at the change, 50% of the second
    ///      gain at the next crystallization (measured on the fee account, which the change emptied)
    function testShouldChargeOnlyGainAfterChangeAtNewRate() public {
        // given
        asset.mint(address(plasmaVault), GAIN);
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        uint256 feeValueAtChange = _totalFeeValue();
        assertApproxEqRel(feeValueAtChange, (GAIN * OLD_TOTAL_FEE) / 10000, REL_TOLERANCE, "10% of the first gain");

        // when
        uint256 secondGain = GAIN / 2;
        asset.mint(address(plasmaVault), secondGain);
        _crystallize();

        // then
        assertApproxEqRel(
            _value(performanceFeeAccount),
            (secondGain * NEW_TOTAL_FEE) / 10000,
            REL_TOLERANCE,
            "fee minted after the change is 50% of the second gain only"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // No gain above the high-water mark - nothing is minted, the mark is kept
    // ---------------------------------------------------------------------------------------------

    function testShouldNotMintWhenChangedWithoutGain() public {
        // given
        uint256 supplyBefore = plasmaVault.totalSupply();
        uint256 curatorBefore = plasmaVault.balanceOf(CURATOR);
        uint256 daoBefore = plasmaVault.balanceOf(DAO_RECIPIENT);

        // when
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        _crystallize();

        // then
        assertEq(plasmaVault.totalSupply(), supplyBefore, "no shares minted");
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "fee account empty");
        assertEq(plasmaVault.balanceOf(CURATOR), curatorBefore, "curator unchanged");
        assertEq(plasmaVault.balanceOf(DAO_RECIPIENT), daoBefore, "DAO unchanged");
    }

    /// @dev Below the mark with interval lowering disabled (interval 0): the change mints nothing and keeps the mark,
    ///      so the recovery back to the old price is fee-free also at the new rate
    function testShouldKeepHighWaterMarkWhenChangedBelowItWithoutInterval() public {
        // given
        uint256 loss = GAIN / 2;
        deal(address(asset), address(plasmaVault), USER_DEPOSIT - loss);
        uint256 supplyBefore = plasmaVault.totalSupply();

        // when
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        asset.mint(address(plasmaVault), loss);
        _crystallize();

        // then
        assertEq(plasmaVault.totalSupply(), supplyBefore, "recovery to the old mark charges no fee");
    }

    // ---------------------------------------------------------------------------------------------
    // High-water mark with an update interval - the change crystallizes like any other call
    // ---------------------------------------------------------------------------------------------

    /// @dev Interval not elapsed: the change does not lower the mark, the recovery back to the old price is fee-free
    function testShouldKeepHighWaterMarkWhenChangedBeforeIntervalElapsed() public {
        // given
        _setHighWaterMarkInterval(7 days);
        uint256 loss = GAIN / 2;
        deal(address(asset), address(plasmaVault), USER_DEPOSIT - loss);
        vm.warp(block.timestamp + 1 days);
        uint256 supplyBefore = plasmaVault.totalSupply();

        // when
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        asset.mint(address(plasmaVault), loss);
        _crystallize();

        // then
        assertEq(plasmaVault.totalSupply(), supplyBefore, "mark kept, recovery to it charges no fee");
    }

    /// @dev Interval elapsed: the change lowers the mark to the current price, as the next execute, withdraw or redeem
    ///      would, and the recovery after the change is charged at the new rate (before IL-9632 the mark was lowered
    ///      only at the first crystallization after the recovery, at the recovered price)
    function testShouldLowerHighWaterMarkAtChangeWhenIntervalElapsed() public {
        // given
        _setHighWaterMarkInterval(1 days);
        uint256 loss = GAIN / 2;
        deal(address(asset), address(plasmaVault), USER_DEPOSIT - loss);
        vm.warp(block.timestamp + 2 days);

        // when
        _setPerformanceRecipient(CURATOR, NEW_CURATOR_FEE);
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "no fee minted below the mark");
        uint256 recovery = loss / 2;
        asset.mint(address(plasmaVault), recovery);
        _crystallize();

        // then
        assertApproxEqRel(
            _value(performanceFeeAccount),
            (recovery * NEW_TOTAL_FEE) / 10000,
            REL_TOLERANCE,
            "recovery after the change charged at the new 50% from the lowered mark"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // realizePerformanceFee - access and equivalence with the other crystallization paths
    // ---------------------------------------------------------------------------------------------

    function testShouldMapRealizePerformanceFeeToTechPerformanceFeeManagerRole() public view {
        assertEq(
            accessManager.getTargetFunctionRole(address(plasmaVault), bytes4(keccak256("realizePerformanceFee()"))),
            Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE,
            "realizePerformanceFee requires TECH_PERFORMANCE_FEE_MANAGER_ROLE"
        );
        (bool isMember, ) = accessManager.hasRole(Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE, address(feeManager));
        assertTrue(isMember, "the FeeManager holds TECH_PERFORMANCE_FEE_MANAGER_ROLE");
    }

    function testShouldRevertRealizePerformanceFeeForCallersWithoutRole() public {
        asset.mint(address(plasmaVault), GAIN);
        address[4] memory callers = [USER, ALPHA, ATOMIST, OWNER];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok, bytes memory ret) = address(plasmaVault).call(abi.encodeWithSignature("realizePerformanceFee()"));
            assertFalse(ok, "caller without the role cannot crystallize");
            assertEq(
                ret,
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, callers[i]),
                "reverts with AccessManagedUnauthorized(caller)"
            );
        }
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), 0, "nothing minted");
    }

    /// @dev One source of truth: the FeeManager's call mints exactly what execute mints on the same state
    function testShouldMintSameFeeAsExecuteWhenFeeManagerRealizes() public {
        // given
        asset.mint(address(plasmaVault), GAIN);

        uint256 snapshot = vm.snapshotState();
        _crystallize();
        uint256 feeSharesByExecute = plasmaVault.balanceOf(performanceFeeAccount);
        vm.revertToState(snapshot);
        assertGt(feeSharesByExecute, 0, "control: execute mints a fee");

        // when
        vm.prank(address(feeManager));
        (bool ok, ) = address(plasmaVault).call(abi.encodeWithSignature("realizePerformanceFee()"));

        // then
        assertTrue(ok, "the FeeManager can crystallize");
        assertEq(plasmaVault.balanceOf(performanceFeeAccount), feeSharesByExecute, "same fee shares as execute");
        assertEq(_vaultPerformanceFee(), OLD_TOTAL_FEE, "the call does not change the rate");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    function _setPerformanceRecipient(address recipient_, uint256 feeValue_) internal {
        RecipientFee[] memory recipients = new RecipientFee[](1);
        recipients[0] = RecipientFee({recipient: recipient_, feeValue: feeValue_});
        vm.prank(ATOMIST);
        feeManager.updatePerformanceFee(recipients);
    }

    function _setHighWaterMarkInterval(uint32 interval_) internal {
        vm.prank(OWNER);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(interval_);
    }

    /// @dev The regular crystallization of a keeper or ALPHA: execute without actions
    function _crystallize() internal {
        vm.prank(ALPHA);
        plasmaVault.execute(new FuseAction[](0));
    }

    function _value(address account_) internal view returns (uint256) {
        return plasmaVault.convertToAssets(plasmaVault.balanceOf(account_));
    }

    /// @dev Everything charged as performance fee: harvested to the DAO and the curators, or still in the fee account
    function _totalFeeValue() internal view returns (uint256) {
        return
            plasmaVault.convertToAssets(
                plasmaVault.balanceOf(DAO_RECIPIENT) +
                    plasmaVault.balanceOf(CURATOR) +
                    plasmaVault.balanceOf(NEW_CURATOR) +
                    plasmaVault.balanceOf(performanceFeeAccount)
            );
    }

    function _vaultPerformanceFee() internal view returns (uint256) {
        return PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeInPercentage;
    }

    function _deployVault() internal {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddleware = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddleware.setAssetsPricesSources(assets, sources);

        accessManager = new IporFusionAccessManager(address(this), 0);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddleware),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: DAO_PERFORMANCE_FEE,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: DAO_RECIPIENT
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        /// @dev FeeManager.initialize() (sets the first high-water mark) while this contract is still the admin
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            new address[](0),
            new MarketBalanceFuseConfig[](0),
            new MarketSubstratesConfig[](0)
        );

        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        feeManager = FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER());

        accessManager.initialize(_initializationData(address(withdrawManager)));
    }

    function _initializationData(address withdrawManager_) internal returns (InitializationData memory) {
        address[] memory admins = new address[](1);
        admins[0] = address(this);
        address[] memory owners = new address[](1);
        owners[0] = OWNER;
        address[] memory atomists = new address[](1);
        atomists[0] = ATOMIST;
        address[] memory alphas = new address[](1);
        alphas[0] = ALPHA;
        address[] memory whitelist = new address[](1);
        whitelist[0] = USER;
        address[] memory none = new address[](0);

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: none,
            admins: admins,
            owners: owners,
            atomists: atomists,
            alphas: alphas,
            whitelist: whitelist,
            guardians: atomists,
            fuseManagers: atomists,
            claimRewards: none,
            transferRewardsManagers: none,
            configInstantWithdrawalFusesManagers: atomists,
            updateMarketsBalancesAccounts: alphas,
            updateRewardsBalanceAccounts: none,
            withdrawManagerRequestFeeManagers: none,
            withdrawManagerWithdrawFeeManagers: none,
            priceOracleMiddlewareManagers: atomists,
            preHooksManagers: atomists,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: address(plasmaVault),
                accessManager: address(accessManager),
                rewardsClaimManager: DUMMY_MANAGER,
                withdrawManager: withdrawManager_,
                feeManager: address(feeManager),
                contextManager: DUMMY_MANAGER,
                priceOracleMiddlewareManager: DUMMY_MANAGER
            })
        });
        return IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(data);
    }
}
