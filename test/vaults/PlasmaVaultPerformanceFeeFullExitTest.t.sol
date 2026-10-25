// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseExitData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultMock} from "../fuses/PlasmaVaultMock.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title PlasmaVaultPerformanceFeeFullExitTest
/// @notice Regression suite for IL-8489 (review items B-50/B-52) - withdraw and redeem crystallize a pending
///         performance fee (rate above the high-water mark) before they check the limit, but maxWithdraw only
///         simulates the pending management fee. withdraw(maxWithdraw(owner)) then reverts with
///         ERC4626ExceededMaxWithdraw, so a parent vault that fully exited a nested PlasmaVault through
///         Erc4626SupplyFuse reverted in execute and was silently skipped in instantWithdraw. The fuse now does a
///         full exit with redeem. Two non-malicious triggers: rewards vesting in the RewardsClaimManager, and the
///         withdraw fee burn of an earlier exit.
contract PlasmaVaultPerformanceFeeFullExitTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 10%
    uint256 public constant PERFORMANCE_FEE = 1000;
    /// @dev 1% in WAD
    uint256 public constant WITHDRAW_FEE = 1e16;
    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    uint256 public constant VESTED_REWARDS = 20_000e6;
    uint256 public constant VESTING_TIME = 30 days;

    bytes4 internal constant EXCEEDED_MAX_WITHDRAW =
        bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"));

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    RewardsClaimManager public rewardsClaimManager;
    PlasmaVaultMock public parent;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

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

        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
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

        bytes4[] memory vaultSigs = new bytes4[](1);
        vaultSigs[0] = PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), vaultSigs, Roles.ATOMIST_ROLE);

        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);

        _fund(user, USER_DEPOSIT);
        _fund(other, USER_DEPOSIT);

        Erc4626SupplyFuse fuse = new Erc4626SupplyFuse(1);
        parent = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory substrates = new address[](1);
        substrates[0] = address(plasmaVault);
        parent.grantAssetsToMarket(fuse.MARKET_ID(), substrates);
    }

    /// @dev execute path, trigger: rewards vesting in the RewardsClaimManager lift totalAssets every block
    function testShouldFullyExitNestedPlasmaVault_whenPerformanceFeePendingFromVestingRewards() public {
        _setupVestingRewardsScenario();
        uint256 expectedAssets = _assertPendingPerformanceFeeBreaksMaxWithdraw();

        parent.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: address(plasmaVault),
                vaultAssetAmount: type(uint256).max,
                maxSharesBurned: 0
            })
        );

        _assertFullyExited(expectedAssets);
    }

    /// @dev instantWithdraw path, trigger: rewards vesting; the old fuse caught the revert and exited nothing
    function testShouldFullyInstantWithdrawNestedPlasmaVault_whenPerformanceFeePendingFromVestingRewards() public {
        _setupVestingRewardsScenario();
        uint256 expectedAssets = _assertPendingPerformanceFeeBreaksMaxWithdraw();

        parent.instantWithdraw(_instantWithdrawParams());

        _assertFullyExited(expectedAssets);
    }

    /// @dev execute path, trigger: the withdraw fee shares of an earlier exit are burned after its performance fee
    ///      check, which lifts the rate above the high-water mark
    function testShouldFullyExitNestedPlasmaVault_whenPerformanceFeePendingFromWithdrawFeeBurn() public {
        _setupWithdrawFeeBurnScenario();
        uint256 expectedAssets = _assertPendingPerformanceFeeBreaksMaxWithdraw();

        parent.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: address(plasmaVault),
                vaultAssetAmount: type(uint256).max,
                maxSharesBurned: 0
            })
        );

        _assertFullyExited(expectedAssets);
    }

    /// @dev instantWithdraw path, trigger: withdraw fee burn
    function testShouldFullyInstantWithdrawNestedPlasmaVault_whenPerformanceFeePendingFromWithdrawFeeBurn() public {
        _setupWithdrawFeeBurnScenario();
        uint256 expectedAssets = _assertPendingPerformanceFeeBreaksMaxWithdraw();

        parent.instantWithdraw(_instantWithdrawParams());

        _assertFullyExited(expectedAssets);
    }

    /// @dev A full exit that would burn more shares than maxSharesBurned reverts, it is not cut down
    function testShouldRevertFullExitOfNestedPlasmaVault_whenMaxSharesBurnedBelowBalance() public {
        _setupVestingRewardsScenario();
        uint256 parentShares = plasmaVault.balanceOf(address(parent));

        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseExcessiveSharesBurned.selector,
                parentShares,
                parentShares - 1
            )
        );
        parent.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: address(plasmaVault),
                vaultAssetAmount: type(uint256).max,
                maxSharesBurned: parentShares - 1
            })
        );
    }

    /// @dev Partial exits below maxWithdraw keep using withdraw and receive exactly the requested amount
    function testShouldWithdrawExactAmount_whenPartialExitWithPerformanceFeePending() public {
        _setupVestingRewardsScenario();
        uint256 sharesBefore = plasmaVault.balanceOf(address(parent));

        parent.exitErc4626Supply(
            Erc4626SupplyFuseExitData({
                vault: address(plasmaVault),
                vaultAssetAmount: USER_DEPOSIT / 2,
                maxSharesBurned: 0
            })
        );

        assertEq(asset.balanceOf(address(parent)), USER_DEPOSIT / 2, "parent received the requested amount");
        assertGt(plasmaVault.balanceOf(address(parent)), 0, "parent keeps the rest of its shares");
        assertLt(plasmaVault.balanceOf(address(parent)), sharesBefore, "parent burned shares");
    }

    /// @dev Proves the fixture reaches the defect: the pending performance fee makes withdraw(maxWithdraw) revert
    ///      for the parent. Returns what redeeming the whole parent position pays in the same state.
    function _assertPendingPerformanceFeeBreaksMaxWithdraw() internal returns (uint256 expectedAssets) {
        uint256 maxAssets = plasmaVault.maxWithdraw(address(parent));
        uint256 parentShares = plasmaVault.balanceOf(address(parent));

        uint256 snapshot = vm.snapshotState();
        vm.prank(address(parent));
        (bool ok, bytes memory ret) = address(plasmaVault).call(
            abi.encodeCall(PlasmaVault.withdraw, (maxAssets, address(parent), address(parent)))
        );
        assertFalse(ok, "precondition: withdraw(maxWithdraw) reverts");
        assertEq(bytes4(ret), EXCEEDED_MAX_WITHDRAW, "precondition: ERC4626ExceededMaxWithdraw");
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        vm.prank(address(parent));
        expectedAssets = plasmaVault.redeem(parentShares, address(parent), address(parent));
        vm.revertToState(snapshot);

        assertGt(expectedAssets, 0, "precondition: full redeem pays assets");
        assertLt(expectedAssets, maxAssets, "precondition: the performance fee lowers the payout below maxWithdraw");
    }

    function _assertFullyExited(uint256 expectedAssets_) internal view {
        assertEq(plasmaVault.balanceOf(address(parent)), 0, "parent redeemed all its shares");
        assertEq(asset.balanceOf(address(parent)), expectedAssets_, "parent received the full redeem payout");
    }

    function _instantWithdrawParams() internal view returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(type(uint256).max);
        params[1] = bytes32(uint256(uint160(address(plasmaVault))));
    }

    function _setupVestingRewardsScenario() internal {
        vm.prank(user);
        plasmaVault.deposit(USER_DEPOSIT, address(parent));
        _deposit(other, USER_DEPOSIT);

        rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(plasmaVault));
        bytes4[] memory rcmSigs = new bytes4[](2);
        rcmSigs[0] = RewardsClaimManager.setupVestingTime.selector;
        rcmSigs[1] = RewardsClaimManager.updateBalance.selector;
        accessManager.setTargetFunctionRole(address(rewardsClaimManager), rcmSigs, Roles.ATOMIST_ROLE);
        PlasmaVaultGovernance(address(plasmaVault)).setRewardsClaimManagerAddress(address(rewardsClaimManager));

        /// @dev empty manager: anchors the schedule
        rewardsClaimManager.setupVestingTime(VESTING_TIME);
        /// @dev rewards claimed and swapped into the underlying, then linear vesting starts
        asset.mint(address(rewardsClaimManager), VESTED_REWARDS);
        rewardsClaimManager.updateBalance();

        vm.warp(block.timestamp + 10 days);
    }

    function _setupWithdrawFeeBurnScenario() internal {
        withdrawManager.updateWithdrawFee(WITHDRAW_FEE);

        vm.prank(user);
        plasmaVault.deposit(USER_DEPOSIT, address(parent));
        _deposit(other, USER_DEPOSIT);
        vm.warp(block.timestamp + 1 days);

        /// @dev an unrelated holder exits: _addPerformanceFee runs with the rate at the high-water mark (no fee),
        ///      then the withdraw fee shares are burned, which lifts the rate above the high-water mark
        vm.prank(other);
        plasmaVault.withdraw(USER_DEPOSIT / 2, other, other);

        assertGt(
            plasmaVault.convertToAssets(10 ** plasmaVault.decimals()),
            _feeManager().getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark,
            "setup: the withdraw fee burn left the rate above the high-water mark"
        );
    }

    function _feeManager() internal view returns (FeeManager) {
        return
            FeeManager(
                FeeAccount(PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
            );
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

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
