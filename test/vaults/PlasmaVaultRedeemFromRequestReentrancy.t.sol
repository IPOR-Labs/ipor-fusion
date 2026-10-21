// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, MarketSubstratesConfig, FeeConfig, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesPlugin} from "../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InstantWithdrawalFusesParamsStruct, PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {IFuseCommon} from "../../contracts/fuses/IFuseCommon.sol";
import {IMarketBalanceFuse} from "../../contracts/fuses/IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../contracts/libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";

/// @notice Minimal external "market" used only by this regression suite. It parks the vault's underlying
///         asset outside the vault so that a redemption is forced to go through the instant withdrawal path.
contract MockExternalMarket {
    using SafeERC20 for IERC20;

    address public immutable ASSET;

    mapping(address account => uint256 amount) public balances;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function supply(uint256 amount_) external {
        IERC20(ASSET).safeTransferFrom(msg.sender, address(this), amount_);
        balances[msg.sender] += amount_;
    }

    function withdraw(uint256 amount_) external {
        balances[msg.sender] -= amount_;
        IERC20(ASSET).safeTransfer(msg.sender, amount_);
    }

    function balanceOf(address account_) external view returns (uint256) {
        return balances[account_];
    }
}

/// @notice Supply fuse for MockExternalMarket. Stateless, delegatecalled by the PlasmaVault.
contract MockMarketSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    struct MockMarketSupplyFuseEnterData {
        uint256 amount;
    }

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    function enter(MockMarketSupplyFuseEnterData memory data_) external {
        address underlyingAsset = IERC4626(address(this)).asset();
        IERC20(underlyingAsset).forceApprove(MARKET, data_.amount);
        MockExternalMarket(MARKET).supply(data_.amount);
        IERC20(underlyingAsset).forceApprove(MARKET, 0);
    }
}

/// @notice Balance fuse for MockExternalMarket. Stateless, delegatecalled by the PlasmaVault.
contract MockMarketBalanceFuse is IMarketBalanceFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    function balanceOf() external view override returns (uint256) {
        uint256 amount = MockExternalMarket(MARKET).balanceOf(address(this));

        if (amount == 0) {
            return 0;
        }

        address underlyingAsset = IERC4626(address(this)).asset();

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(underlyingAsset);

        return IporMath.convertToWad(amount * price, IERC20Metadata(underlyingAsset).decimals() + priceDecimals);
    }
}

/// @notice Instant withdrawal fuse that models a real-world integration handing control to a third party
///         in the middle of the unwind (ETH forwarding adapters, token hooks, protocol callbacks).
///         Stateless, delegatecalled by the PlasmaVault.
contract MaliciousInstantWithdrawFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    /// @param params_ [0] amount to withdraw (set by the vault), [1] address of the callback receiver
    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);
        uint256 available = MockExternalMarket(MARKET).balanceOf(address(this));

        if (amount > available) {
            amount = available;
        }

        if (amount > 0) {
            MockExternalMarket(MARKET).withdraw(amount);
        }

        /// @dev at this point the withdrawn assets already sit in the vault's balanceOf, while the market
        ///      balance recorded in storage has NOT been refreshed yet -> totalAssets() is transiently inflated
        ReentrancyAttacker(PlasmaVaultConfigLib.bytes32ToAddress(params_[1])).onInstantWithdraw();
    }
}

/// @notice Attacker contract re-entering the vault from inside the instant withdrawal callback.
contract ReentrancyAttacker {
    enum Mode {
        NONE,
        REDEEM,
        DEPOSIT
    }

    PlasmaVault public immutable VAULT;
    IERC20 public immutable ASSET;

    Mode public mode;
    uint256 public reentrancyAmount;
    bool public callbackFired;
    bool public reentrancySucceeded;
    uint256 public totalAssetsSeenDuringCallback;

    constructor(address vault_, address asset_) {
        VAULT = PlasmaVault(vault_);
        ASSET = IERC20(asset_);
    }

    function setAttack(Mode mode_, uint256 amount_) external {
        mode = mode_;
        reentrancyAmount = amount_;
        callbackFired = false;
        reentrancySucceeded = false;
        totalAssetsSeenDuringCallback = 0;
    }

    function approveVault(uint256 amount_) external {
        ASSET.approve(address(VAULT), amount_);
    }

    function deposit(uint256 assets_) external returns (uint256) {
        ASSET.approve(address(VAULT), assets_);
        return VAULT.deposit(assets_, address(this));
    }

    function requestShares(address withdrawManager_, uint256 shares_) external {
        WithdrawManager(withdrawManager_).requestShares(shares_);
    }

    function redeemFromRequest(uint256 shares_) external returns (uint256) {
        return VAULT.redeemFromRequest(shares_, address(this), address(this));
    }

    function redeem(uint256 shares_) external returns (uint256) {
        return VAULT.redeem(shares_, address(this), address(this));
    }

    /// @dev Invoked by the malicious instant withdrawal fuse while the vault is mid-unwind.
    function onInstantWithdraw() external {
        if (callbackFired || mode == Mode.NONE) {
            return;
        }

        callbackFired = true;
        totalAssetsSeenDuringCallback = VAULT.totalAssets();

        if (mode == Mode.REDEEM) {
            VAULT.redeem(reentrancyAmount, address(this), address(this));
        } else {
            ASSET.approve(address(VAULT), reentrancyAmount);
            VAULT.deposit(reentrancyAmount, address(this));
        }

        reentrancySucceeded = true;
    }
}

/// @notice Regression suite for IL-7980: PlasmaVault.redeemFromRequest must carry the same reentrancy guard
///         as every other value-moving entry point.
contract PlasmaVaultRedeemFromRequestReentrancyTest is Test {
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _USDC_HOLDER = 0x47c031236e19d024b42f8AE6780E44A573170703;

    uint256 private constant _TEST_MARKET_ID = 999_999;

    address private _plasmaVault;
    address private _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;
    address private _accessManager;
    address private _withdrawManager;

    MockExternalMarket private _market;
    MockMarketSupplyFuse private _supplyFuse;
    MockMarketBalanceFuse private _balanceFuse;
    MaliciousInstantWithdrawFuse private _maliciousFuse;
    ReentrancyAttacker private _attacker;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 256415332);

        _market = new MockExternalMarket(_USDC);

        _createAccessManager();
        _createWithdrawManager();
        _createPlasmaVault();

        _attacker = new ReentrancyAttacker(_plasmaVault, _USDC);

        _initAccessManager();

        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 10_000e6);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(address(_attacker), 5_000e6);

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        _attacker.deposit(2_000e6);

        /// @dev park almost all of the underlying in the external market so that any redemption has to
        ///      go through the instant withdrawal (market unwind) path
        _supplyToMarket(11_900e6);

        _configureInstantWithdrawal();

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);
    }

    /// @dev IL-7980: re-entrant redeem() from inside the market unwind started by redeemFromRequest.
    ///      Before the fix the re-entrant redeem goes through against a transiently inflated totalAssets();
    ///      after the fix the shared ReentrancyGuard flag blocks it and the whole transaction reverts.
    function test_redeemFromRequest_revertsWhenReentrantRedeemDuringMarketUnwind() external {
        // given
        uint256 sharesToRedeem = 500e8;
        _attacker.setAttack(ReentrancyAttacker.Mode.REDEEM, 100e8);
        _prepareReleasedRequest(sharesToRedeem);

        // when / then
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        _attacker.redeemFromRequest(sharesToRedeem);
    }

    /// @dev IL-7980: re-entrant deposit() from inside the market unwind started by redeemFromRequest.
    function test_redeemFromRequest_revertsWhenReentrantDepositDuringMarketUnwind() external {
        // given
        uint256 sharesToRedeem = 500e8;
        _attacker.setAttack(ReentrancyAttacker.Mode.DEPOSIT, 1_000e6);
        _prepareReleasedRequest(sharesToRedeem);

        // when / then
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        _attacker.redeemFromRequest(sharesToRedeem);
    }

    /// @dev Control case: the very same malicious fuse reached through redeem() was already blocked before
    ///      the fix, because redeem() carries nonReentrant. This test must be green both before and after
    ///      the fix - it proves the harness itself is not the reason the two tests above revert.
    function test_redeem_controlCase_reentrancyAlreadyBlocked() external {
        // given
        _attacker.setAttack(ReentrancyAttacker.Mode.REDEEM, 100e8);

        // when / then
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        _attacker.redeem(500e8);
    }

    /// @dev The guard must not break the legitimate flow: same unwind machinery, no re-entrancy attempt.
    function test_redeemFromRequest_happyPathStillWorks() external {
        // given
        uint256 sharesToRedeem = 500e8;
        _attacker.setAttack(ReentrancyAttacker.Mode.NONE, 0);
        _prepareReleasedRequest(sharesToRedeem);

        uint256 assetBalanceBefore = ERC20(_USDC).balanceOf(address(_attacker));
        uint256 sharesBefore = PlasmaVault(_plasmaVault).balanceOf(address(_attacker));
        uint256 marketBalanceBefore = _market.balanceOf(_plasmaVault);

        // when
        uint256 withdrawnAssets = _attacker.redeemFromRequest(sharesToRedeem);

        // then
        assertGt(withdrawnAssets, 0, "assets should be withdrawn");
        assertEq(
            ERC20(_USDC).balanceOf(address(_attacker)),
            assetBalanceBefore + withdrawnAssets,
            "attacker underlying balance should grow by the withdrawn assets"
        );
        assertEq(
            PlasmaVault(_plasmaVault).balanceOf(address(_attacker)),
            sharesBefore - sharesToRedeem,
            "redeemed shares should be burned"
        );
        assertLt(_market.balanceOf(_plasmaVault), marketBalanceBefore, "market position should be unwound");
        assertTrue(_market.balanceOf(_plasmaVault) > 0, "only part of the market position should be unwound");
    }

    /// @dev The legitimate deposit path stays open once the guarded redeemFromRequest has finished.
    function test_redeemFromRequest_doesNotLockTheVaultForLaterCalls() external {
        // given
        uint256 sharesToRedeem = 500e8;
        _attacker.setAttack(ReentrancyAttacker.Mode.NONE, 0);
        _prepareReleasedRequest(sharesToRedeem);

        _attacker.redeemFromRequest(sharesToRedeem);

        // when
        uint256 mintedShares = _attacker.deposit(100e6);

        // then
        assertGt(mintedShares, 0, "deposit after redeemFromRequest should still work");
    }

    function _prepareReleasedRequest(uint256 shares_) private {
        _attacker.requestShares(_withdrawManager, shares_);

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, shares_);

        vm.warp(block.timestamp + 1 hours);
    }

    function _supplyToMarket(uint256 amount_) private {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeWithSignature(
                "enter((uint256))",
                MockMarketSupplyFuse.MockMarketSupplyFuseEnterData({amount: amount_})
            )
        });

        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function _createPlasmaVault() private {
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: _USDC,
                priceOracleMiddleware: _priceOracle,
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: address(_accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: _withdrawManager,
                plasmaVaultVotesPlugin: address(new PlasmaVaultVotesPlugin())
            })
        );
        vm.stopPrank();

        _supplyFuse = new MockMarketSupplyFuse(_TEST_MARKET_ID, address(_market));
        _balanceFuse = new MockMarketBalanceFuse(_TEST_MARKET_ID, address(_market));
        _maliciousFuse = new MaliciousInstantWithdrawFuse(_TEST_MARKET_ID, address(_market));

        address[] memory fuses = new address[](2);
        fuses[0] = address(_supplyFuse);
        fuses[1] = address(_maliciousFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({marketId: _TEST_MARKET_ID, fuse: address(_balanceFuse)});

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        marketConfigs[0] = MarketSubstratesConfig({marketId: _TEST_MARKET_ID, substrates: substrates});

        PlasmaVaultConfigurator.setupPlasmaVault(vm, _ATOMIST, _plasmaVault, fuses, balanceFuses, marketConfigs);
    }

    function _configureInstantWithdrawal() private {
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory params = new bytes32[](2);
        params[0] = 0;
        params[1] = PlasmaVaultConfigLib.addressToBytes32(address(_attacker));

        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({fuse: address(_maliciousFuse), params: params});

        vm.prank(_ATOMIST);
        IPlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(instantWithdrawFuses);
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _createWithdrawManager() private {
        _withdrawManager = address(new WithdrawManager(_accessManager));
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](2);
        whitelist[0] = _USER;
        whitelist[1] = address(_attacker);

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: address(0x123),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);

        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }
}
