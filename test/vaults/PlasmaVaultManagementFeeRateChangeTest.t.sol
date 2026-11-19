// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig, RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultManagementFeeRateChangeTest
/// @notice Regression suite for IL-8742 - `PlasmaVaultLib.configureManagementFee` overwrote only the rate, so a new
///         rate was applied retroactively to the time elapsed since the last fee realization (a raise overcharged
///         the depositors, a cut or a change to zero forgave the old period). `PlasmaVaultGovernance` now
///         checkpoints the accrual at the old rate into the pending management fee and restarts the fee clock.
contract PlasmaVaultManagementFeeRateChangeTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);
    address public curatorRecipient = address(0xC0FFEE);
    address public newRecipient = address(0xBEEF);
    address public constant DAO_RECIPIENT = address(98989898);

    /// @dev FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant DAO_FEE = 100;
    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    uint256 public constant OTHER_DEPOSIT = 500e6;
    uint256 public constant TOTAL_ASSETS = USER_DEPOSIT + OTHER_DEPOSIT;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    PlasmaVault public plasmaVault;
    FeeManager public feeManager;
    address public managementFeeAccount;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        _deployVault(DAO_FEE);

        _fund(user, USER_DEPOSIT);
        _fund(other, 10 * OTHER_DEPOSIT);

        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
    }

    /// @dev PoC port (6442e46b): a year at 1%, then a raise to 5% in the same block
    function testShouldNotRepriceAccruedFee_whenRateRaisedAfterOneYear() public {
        vm.warp(block.timestamp + 365 days);
        uint256 userShares = plasmaVault.balanceOf(user);

        uint256 snap = vm.snapshotState();
        _deposit(other, 1e6);
        uint256 userValueControl = plasmaVault.convertToAssets(userShares);
        uint256 feeSharesControl = plasmaVault.balanceOf(managementFeeAccount);
        vm.revertToState(snap);

        uint256 unrealizedBefore = plasmaVault.getUnrealizedManagementFee();
        assertEq(unrealizedBefore, _accrual(TOTAL_ASSETS, 365 days, 100), "old accrual is 1% for a year");

        _configureVaultFeeDirectly(500);

        assertEq(
            plasmaVault.getUnrealizedManagementFee(),
            unrealizedBefore,
            "accrued fee not re-priced; equals the pending fee"
        );
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultGovernance(address(plasmaVault))
            .getManagementFeeData();
        assertEq(feeData.feeInPercentage, 500, "new rate stored");
        assertEq(feeData.lastUpdateTimestamp, block.timestamp, "fee clock restarted");

        _deposit(other, 1e6);

        assertApproxEqAbs(plasmaVault.convertToAssets(userShares), userValueControl, 2, "depositor value unchanged");
        assertApproxEqAbs(plasmaVault.balanceOf(managementFeeAccount), feeSharesControl, 2, "fee shares unchanged");
    }

    function testShouldChargeEachPeriodAtItsOwnRate_whenRateRaised() public {
        vm.warp(block.timestamp + 365 days);
        _configureVaultFeeDirectly(500);
        vm.warp(block.timestamp + 30 days);

        assertEq(
            plasmaVault.getUnrealizedManagementFee(),
            _accrual(TOTAL_ASSETS, 365 days, 100) + _accrual(TOTAL_ASSETS, 30 days, 500),
            "1% for 365 days plus 5% for 30 days"
        );
    }

    function testShouldMintOldAccrualAtNextRealization_whenRateCut() public {
        _setRecipientFee(400);
        vm.warp(block.timestamp + 180 days);

        uint256 snap = vm.snapshotState();
        _deposit(other, 1e6);
        uint256 feeSharesControl = plasmaVault.balanceOf(managementFeeAccount);
        vm.revertToState(snap);

        _configureVaultFeeDirectly(DAO_FEE);

        uint256 oldAccrual = _accrual(TOTAL_ASSETS, 180 days, 500);
        assertEq(plasmaVault.getUnrealizedManagementFee(), oldAccrual, "old 5% accrual kept as pending");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "nothing minted by the rate change");
        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 100);

        _deposit(other, 1e6);

        assertGt(plasmaVault.balanceOf(managementFeeAccount), 0, "old accrual minted");
        assertApproxEqAbs(plasmaVault.balanceOf(managementFeeAccount), feeSharesControl, 2, "minted at the old 5%");
        /// @dev IL-8870: the fee shares are priced as virtual shares before the mint, so they are worth the accrued
        ///      fee F up to rounding (was 3% for the fee account's own dilution)
        assertApproxEqRel(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(managementFeeAccount)),
            oldAccrual,
            1e12,
            "fee account holds the old accrual"
        );
    }

    function testShouldNotChargeOldPeriod_whenRateRaisedFromZero() public {
        _deployVault(0);
        _fund(user, USER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 0);

        vm.warp(block.timestamp + 365 days);
        _setRecipientFee(200);

        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "year at 0% is not charged at 2%");

        vm.warp(block.timestamp + 30 days);
        assertEq(plasmaVault.getUnrealizedManagementFee(), _accrual(USER_DEPOSIT, 30 days, 200), "new rate from now");
    }

    function testShouldNotRevertAndMoveClock_whenVaultIsEmpty() public {
        _deployVault(DAO_FEE);
        vm.warp(block.timestamp + 365 days);

        _setRecipientFee(400);

        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "no pending fee on an empty vault");
        assertEq(
            PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp,
            block.timestamp,
            "clock moved"
        );
    }

    /// @dev Assets without shares (donation after a full exit): nobody to charge, the accrual is dropped (IL-8318)
    function testShouldDropAccrual_whenAssetsHaveNoShares() public {
        _deployVault(DAO_FEE);
        _fund(user, USER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        uint256 shares = plasmaVault.balanceOf(user);
        vm.prank(user);
        plasmaVault.redeem(shares, user, user);
        assertEq(plasmaVault.totalSupply(), 0, "all shares redeemed");

        asset.mint(address(plasmaVault), 1_000e6);
        vm.warp(block.timestamp + 365 days);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "dormant accrual visible before the change");

        _setRecipientFee(400);

        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "accrual without shares is dropped");
        assertEq(
            PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp,
            block.timestamp,
            "clock moved"
        );
    }

    function testShouldAddNothing_whenRateChangedTwiceInOneBlock() public {
        vm.warp(block.timestamp + 365 days);
        _configureVaultFeeDirectly(500);
        uint256 afterFirst = plasmaVault.getUnrealizedManagementFee();

        _configureVaultFeeDirectly(300);

        assertEq(plasmaVault.getUnrealizedManagementFee(), afterFirst, "second change adds nothing");
        assertEq(afterFirst, _accrual(TOTAL_ASSETS, 365 days, 100), "only the first period accrued");
        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 300);
    }

    function testShouldCheckpointAndStoreRate_whenConfiguredDirectlyByTechRole() public {
        vm.warp(block.timestamp + 365 days);
        uint256 expected = _accrual(TOTAL_ASSETS, 365 days, 100);

        vm.prank(address(feeManager));
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, 300);

        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultGovernance(address(plasmaVault))
            .getManagementFeeData();
        assertEq(feeData.feeAccount, managementFeeAccount);
        assertEq(feeData.feeInPercentage, 300);
        assertEq(feeData.lastUpdateTimestamp, block.timestamp);
        assertEq(plasmaVault.getUnrealizedManagementFee(), expected, "old accrual kept");
    }

    function testShouldRevertConfigureManagementFee_whenCallerHasNoRole() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user));
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, 300);
    }

    /// @dev IL-8842 A1: total set to 0 -> shares waiting in the fee account stay there (harvest returns early).
    ///      IL-9431: the fee is realized before the change and the waiting shares are seeded explicitly afterwards.
    function testShouldKeepOldPeriodSharesInFeeAccount_whenTotalSetToZero() public {
        _deployVault(0);
        _fund(user, USER_DEPOSIT);
        _fund(other, OTHER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        _setRecipientFee(400);
        vm.warp(block.timestamp + 20 days);

        _deposit(other, 1e6);
        _setRecipientFees(new RecipientFee[](0));
        uint256 curatorBefore = plasmaVault.balanceOf(curatorRecipient);
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "realized before the change");

        uint256 feeAccountBefore = plasmaVault.balanceOf(managementFeeAccount);
        uint256 feeAccountShares = _seedFeeAccountShares(1_000e6);
        assertEq(feeAccountShares, feeAccountBefore + 1_000e6, "seeded shares are waiting in the fee account");

        feeManager.harvestManagementFee();

        assertEq(plasmaVault.balanceOf(managementFeeAccount), feeAccountShares, "harvest at total 0 keeps the shares");
        assertEq(plasmaVault.balanceOf(curatorRecipient), curatorBefore, "old recipient gets nothing more");

        RecipientFee[] memory recipients = new RecipientFee[](1);
        recipients[0] = RecipientFee({recipient: newRecipient, feeValue: 200});
        _setRecipientFees(recipients);
        feeManager.harvestManagementFee();

        assertApproxEqAbs(plasmaVault.balanceOf(newRecipient), feeAccountShares, 2, "new recipient gets the balance");
        assertLe(plasmaVault.balanceOf(managementFeeAccount), 2, "fee account drained");
        assertEq(plasmaVault.balanceOf(curatorRecipient), curatorBefore, "curator still nothing more");
    }

    /// @dev IL-8842 procedure: realize the fee first, then change -> the old recipients are paid
    function testShouldPayOldRecipients_whenFeeRealizedBeforeChange() public {
        _deployVault(0);
        _fund(user, USER_DEPOSIT);
        _fund(other, OTHER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        _setRecipientFee(400);
        vm.warp(block.timestamp + 20 days);
        uint256 accrual = _accrual(USER_DEPOSIT, 20 days, 400);

        _deposit(other, 1);
        _setRecipientFees(new RecipientFee[](0));

        assertApproxEqRel(
            plasmaVault.convertToAssets(plasmaVault.balanceOf(curatorRecipient)),
            accrual,
            1e16,
            "old recipient paid the old period"
        );
        assertEq(plasmaVault.balanceOf(managementFeeAccount), 0, "fee account empty");
        assertLe(plasmaVault.getUnrealizedManagementFee(), 1, "nothing pending after the change");
    }

    /// @dev IL-8842 recovery: release waiting shares with a temporary recipient in one block
    function testShouldReleaseWaitingShares_withTemporaryRecipientInOneBlock() public {
        _deployVault(0);
        _fund(user, USER_DEPOSIT);
        _fund(other, OTHER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        _setRecipientFee(400);
        vm.warp(block.timestamp + 20 days);
        _deposit(other, 1e6);
        _setRecipientFees(new RecipientFee[](0));
        uint256 curatorBefore = plasmaVault.balanceOf(curatorRecipient);
        uint256 feeAccountShares = _seedFeeAccountShares(1_000e6);
        assertGt(feeAccountShares, 0, "shares waiting");

        _setRecipientFee(1);
        feeManager.harvestManagementFee();
        _setRecipientFees(new RecipientFee[](0));

        assertApproxEqAbs(
            plasmaVault.balanceOf(curatorRecipient) - curatorBefore,
            feeAccountShares,
            2,
            "curator gets the balance"
        );
        assertLe(plasmaVault.balanceOf(managementFeeAccount), 2, "fee account drained");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "no new accrual");
    }

    function _accrual(uint256 assets_, uint256 duration_, uint256 rate_) internal pure returns (uint256) {
        return Math.mulDiv(assets_ * duration_, rate_, 365 days * 1e4);
    }

    /// @dev Sets the single recipient fee through the FeeManager (the production path); total = DAO fee + value
    function _setRecipientFee(uint256 value_) internal {
        RecipientFee[] memory recipients = new RecipientFee[](1);
        recipients[0] = RecipientFee({recipient: curatorRecipient, feeValue: value_});
        _setRecipientFees(recipients);
    }

    function _setRecipientFees(RecipientFee[] memory recipients_) internal {
        feeManager.updateManagementFee(recipients_);
    }

    /// @dev IL-9431: configures the vault fee directly from the TECH role (the FeeManager), bypassing the FeeManager
    ///      gate, to exercise the checkpoint while a fee is pending; the FeeManager's own configuration is unchanged
    function _configureVaultFeeDirectly(uint256 total_) internal {
        vm.prank(address(feeManager));
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, total_);
    }

    /// @dev Places shares in the management fee account explicitly (the "waiting shares" premise of IL-8842)
    function _seedFeeAccountShares(uint256 amount_) internal returns (uint256) {
        vm.prank(user);
        plasmaVault.transfer(managementFeeAccount, amount_);
        return plasmaVault.balanceOf(managementFeeAccount);
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

    function _deployVault(uint256 daoManagementFee_) internal {
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

        IporFusionAccessManager accessManager = _createAccessManager();
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: daoManagementFee_,
                    iporDaoPerformanceFee: 0,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: DAO_RECIPIENT
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

        feeManager = FeeManager(
            FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
        );
        managementFeeAccount = feeManager.MANAGEMENT_FEE_ACCOUNT();
    }

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
