// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
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

/// @title PlasmaVaultManagementFeeChangeGateTest
/// @notice IL-9431 (F-31): `FeeManager.updateManagementFee` refuses a change while the vault's unrealized management
///         fee would still mint at least one fee share, so the old period is always split by the old recipients.
contract PlasmaVaultManagementFeeChangeGateTest is Test {
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

    function testShouldRevertManagementFeeUpdateWhileFeeIsUnrealized() public {
        vm.warp(block.timestamp + 30 days);
        uint256 unrealized = plasmaVault.getUnrealizedManagementFee();
        assertGt(plasmaVault.convertToShares(unrealized), 0, "premise: realization would mint shares");

        vm.expectRevert(abi.encodeWithSelector(FeeManager.FeeManagerUnrealizedManagementFee.selector, unrealized));
        _setRecipientFee(400);
    }

    function testShouldAllowManagementFeeUpdateRightAfterRealization() public {
        vm.warp(block.timestamp + 30 days);
        _deposit(other, 1e6);
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "premise: nothing pending");

        _setRecipientFee(400);

        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 500);
    }

    /// @dev F-31: the DAO keeps daoFee/oldTotal of the old period when the total is raised after realization
    function testShouldKeepDaoShareOfOldPeriodWhenTotalRaisedAfterRealization() public {
        _deployVault(50);
        _fund(user, USER_DEPOSIT);
        _fund(other, OTHER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        _setRecipientFee(150);

        vm.warp(block.timestamp + 365 days);
        _deposit(other, 1e6);
        uint256 oldPeriodShares = plasmaVault.balanceOf(managementFeeAccount);
        assertGt(oldPeriodShares, 0, "old period minted");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "nothing pending");

        _setRecipientFee(450);

        assertApproxEqAbs(plasmaVault.balanceOf(DAO_RECIPIENT), oldPeriodShares / 4, 2, "DAO 50/200 of the old period");
        assertApproxEqAbs(plasmaVault.balanceOf(curatorRecipient), (oldPeriodShares * 3) / 4, 2, "curator 150/200");
        assertLe(plasmaVault.balanceOf(managementFeeAccount), 2, "old period fully harvested");

        vm.warp(block.timestamp + 365 days);
        _deposit(other, 1e6);
        uint256 newPeriodShares = plasmaVault.balanceOf(managementFeeAccount);
        uint256 daoBefore = plasmaVault.balanceOf(DAO_RECIPIENT);
        feeManager.harvestManagementFee();
        assertApproxEqAbs(
            plasmaVault.balanceOf(DAO_RECIPIENT) - daoBefore,
            newPeriodShares / 10,
            2,
            "next period split by the new total (50/500)"
        );
    }

    /// @dev Replaces IL-8742 `testShouldSplitOldPeriodByNewRecipients_whenRecipientsChange` (the removed behaviour)
    function testShouldRevertThenPayOldRecipientsWhenRecipientsChange() public {
        _setRecipientFee(400);
        vm.warp(block.timestamp + 30 days);

        RecipientFee[] memory recipients = new RecipientFee[](1);
        recipients[0] = RecipientFee({recipient: newRecipient, feeValue: 400});
        vm.expectRevert(
            abi.encodeWithSelector(
                FeeManager.FeeManagerUnrealizedManagementFee.selector,
                plasmaVault.getUnrealizedManagementFee()
            )
        );
        feeManager.updateManagementFee(recipients);

        _deposit(other, 1e6);
        uint256 feeAccountShares = plasmaVault.balanceOf(managementFeeAccount);
        assertGt(feeAccountShares, 0, "old period minted");

        feeManager.updateManagementFee(recipients);

        assertEq(plasmaVault.balanceOf(newRecipient), 0, "new recipient gets nothing of the old period");
        assertApproxEqRel(plasmaVault.balanceOf(curatorRecipient), (feeAccountShares * 4) / 5, 1e16, "old gets 4/5");
        assertApproxEqRel(plasmaVault.balanceOf(DAO_RECIPIENT), feeAccountShares / 5, 1e16, "DAO gets 1/5");
    }

    /// @dev Empty-vault branch (zero supply): assets donated, time passed, the update is not blocked (M-10)
    function testShouldAllowManagementFeeUpdateWhenVaultHasNoShares() public {
        _deployVault(DAO_FEE);
        asset.mint(address(plasmaVault), 1_000e6);
        vm.warp(block.timestamp + 365 days);
        assertEq(plasmaVault.totalSupply(), 0, "premise: no shares");
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "premise: a fee is visible");

        _setRecipientFee(400);

        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 500);
    }

    /// @dev Empty-vault branch (zero assets): shares outstanding with a pending fee, all assets lost (M-14)
    function testShouldAllowManagementFeeUpdateWhenVaultHasNoAssets() public {
        vm.warp(block.timestamp + 365 days);
        vm.prank(address(feeManager));
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, 100);
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "premise: pending fee seeded by the checkpoint");

        uint256 vaultBalance = asset.balanceOf(address(plasmaVault));
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xDEAD), vaultBalance);

        assertGt(plasmaVault.totalSupply(), 0, "premise: shares outstanding");
        assertEq(plasmaVault.totalAssets(), 0, "premise: no assets");
        assertGt(plasmaVault.getUnrealizedManagementFee(), 0, "premise: pending fee still stored");

        _setRecipientFee(400);

        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 500);
    }

    /// @dev Dust: the pending fee is positive but converts to zero shares, so a realization would mint nothing (M-15)
    function testShouldAllowManagementFeeUpdateWhenPendingFeeIsNotMintable() public {
        _deployVault(DAO_FEE);
        _fund(user, 1_000);
        _deposit(user, 1_000);
        asset.mint(address(plasmaVault), 1e18);
        vm.warp(block.timestamp + 1);

        uint256 unrealized = plasmaVault.getUnrealizedManagementFee();
        assertGt(unrealized, 0, "premise: a fee is pending");
        assertEq(plasmaVault.convertToShares(unrealized), 0, "premise: it would not mint a share");

        _setRecipientFee(400);

        assertEq(PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage, 500);
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
