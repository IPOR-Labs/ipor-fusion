// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, MarketSubstratesConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesPlugin} from "../../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager, WithdrawRequestInfo} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse, BurnRequestFeeDataEnter} from "../../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {RequestFeeRefundFuse, RequestFeeRefundDataEnter} from "../../../contracts/fuses/burn_request_fee/RequestFeeRefundFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

/// @title RequestFeeRefundFuseLegacySlotTest
/// @notice Proves IL-7407 backward compatibility: RequestFeeRefundFuse / BurnRequestFeeFuse
///         can read the WithdrawManager address from the LEGACY storage slot when the
///         corrected (IL-6952) slot is zero — i.e. on pre-IL-6952 deployed PlasmaVaults
///         (e.g. Clearstar vault).
contract RequestFeeRefundFuseLegacySlotTest is Test {
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _USDC_HOLDER = 0x47c031236e19d024b42f8AE6780E44A573170703;

    uint256 private constant _WITHDRAW_WINDOW = 1 days;
    uint256 private constant _REQUEST_FEE_RATE = 0.01e18;
    uint256 private constant _USER_REQUEST_AMOUNT = 1_000e8;

    bytes32 private constant WITHDRAW_MANAGER_NEW_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;
    bytes32 private constant WITHDRAW_MANAGER_LEGACY_SLOT =
        0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;

    address private _plasmaVault;
    address private _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;
    address private _accessManager;
    address private _withdrawManager;
    BurnRequestFeeFuse private _burnRequestFeeFuse;
    RequestFeeRefundFuse private _requestFeeRefundFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 256415332);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 10_000e6);

        _createAccessManager();
        _createWithdrawManager();
        _createPlasmaVault();
        _initAccessManager();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(_WITHDRAW_WINDOW);

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(_REQUEST_FEE_RATE);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();
    }

    // ================================================================
    // Fixture (mirrors RequestFeeRefundFuseTest setup)
    // ================================================================

    function _createPlasmaVault() private {
        PlasmaVaultFactory factory = new PlasmaVaultFactory();
        address baseImpl = address(new PlasmaVault());

        vm.startPrank(_ATOMIST);
        _plasmaVault = factory.clone(
            baseImpl,
            0,
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
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
    }

    function _setupMarketConfigs() private pure returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig({
            marketId: IporFusionMarkets.ZERO_BALANCE_MARKET,
            substrates: new bytes32[](0)
        });
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _burnRequestFeeFuse = new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        _requestFeeRefundFuse = new RequestFeeRefundFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        fuses = new address[](2);
        fuses[0] = address(_burnRequestFeeFuse);
        fuses[1] = address(_requestFeeRefundFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ZeroBalanceFuse zeroBalanceFuse = new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.ZERO_BALANCE_MARKET,
            fuse: address(zeroBalanceFuse)
        });
        balanceFuses[1] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.ERC20_VAULT_BALANCE,
            fuse: address(erc20BalanceFuse)
        });
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

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

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

    // ================================================================
    // Helpers
    // ================================================================

    function _userRequestShares(address user_, uint256 shares_) private returns (uint256, uint256) {
        uint256 balanceBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        vm.prank(user_);
        WithdrawManager(_withdrawManager).requestShares(shares_);
        uint256 balanceAfter = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        uint256 feeAmount = balanceAfter - balanceBefore;
        WithdrawRequestInfo memory info = WithdrawManager(_withdrawManager).requestInfo(user_);
        return (feeAmount, info.endWithdrawWindowTimestamp);
    }

    function _executeRefund(address recipient_, uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_requestFeeRefundFuse),
            data: abi.encodeWithSelector(
                RequestFeeRefundFuse.enter.selector,
                RequestFeeRefundDataEnter({recipient: recipient_, amount: amount_})
            )
        });
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @dev Simulates a legacy (pre-IL-6952) PlasmaVault: clear the NEW slot, set the LEGACY slot.
    function _simulateLegacyPlasmaVault() private {
        vm.store(_plasmaVault, WITHDRAW_MANAGER_NEW_SLOT, bytes32(0));
        vm.store(_plasmaVault, WITHDRAW_MANAGER_LEGACY_SLOT, bytes32(uint256(uint160(_withdrawManager))));
    }

    // ================================================================
    // IL-7407 backward-compat tests
    // ================================================================

    /// @notice Refund must work when WithdrawManager is found only in the LEGACY slot.
    function testRefund_worksWhenWithdrawManagerOnlyInLegacySlot() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(feeAmount, 0, "fee must be non-zero");

        vm.warp(endTs + 1);

        _simulateLegacyPlasmaVault();

        uint256 userBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_USER);
        uint256 wmBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        vm.expectEmit(true, true, true, true, address(_plasmaVault));
        emit RequestFeeRefundFuse.RequestFeeRefundEnter(address(_requestFeeRefundFuse), _USER, feeAmount, endTs);
        _executeRefund(_USER, feeAmount);

        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_USER),
            userBalBefore + feeAmount,
            "user balance must grow by feeAmount"
        );
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            wmBalBefore - feeAmount,
            "wm balance must fall by feeAmount"
        );
    }

    /// @notice Burn must work when WithdrawManager is found only in the LEGACY slot.
    function testBurn_worksWhenWithdrawManagerOnlyInLegacySlot() external {
        (uint256 feeAmount, ) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(feeAmount, 0, "fee must be non-zero");

        _simulateLegacyPlasmaVault();

        uint256 totalSupplyBefore = PlasmaVaultBase(_plasmaVault).totalSupply();
        uint256 wmBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_burnRequestFeeFuse),
            data: abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: feeAmount}))
        });

        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);

        assertEq(
            PlasmaVaultBase(_plasmaVault).totalSupply(),
            totalSupplyBefore - feeAmount,
            "totalSupply must drop by burnt amount"
        );
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            wmBalBefore - feeAmount,
            "wm balance must drop by burnt amount"
        );
    }

    /// @notice Refund must revert when both slots are zero (no WithdrawManager at all).
    function testRefund_reverts_whenBothSlotsAreZero() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        vm.warp(endTs + 1);

        vm.store(_plasmaVault, WITHDRAW_MANAGER_NEW_SLOT, bytes32(0));
        vm.store(_plasmaVault, WITHDRAW_MANAGER_LEGACY_SLOT, bytes32(0));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_requestFeeRefundFuse),
            data: abi.encodeWithSelector(
                RequestFeeRefundFuse.enter.selector,
                RequestFeeRefundDataEnter({recipient: _USER, amount: feeAmount})
            )
        });
        vm.prank(_ALPHA);
        vm.expectRevert(RequestFeeRefundFuse.RequestFeeRefundWithdrawManagerNotSet.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @notice When BOTH slots are populated, the NEW slot must win (precedence guard).
    function testRefund_prefersNewSlot_overLegacy() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        vm.warp(endTs + 1);

        // New slot is already populated with the real _withdrawManager.
        // Plant a bogus address in the legacy slot — refund must still succeed because
        // the new slot wins.
        vm.store(_plasmaVault, WITHDRAW_MANAGER_LEGACY_SLOT, bytes32(uint256(uint160(address(0xDEAD)))));

        uint256 userBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_USER);
        _executeRefund(_USER, feeAmount);
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_USER),
            userBalBefore + feeAmount,
            unicode"new slot must win — refund must come from real WithdrawManager"
        );
    }
}
