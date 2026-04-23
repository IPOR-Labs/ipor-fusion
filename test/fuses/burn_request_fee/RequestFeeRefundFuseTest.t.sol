// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, MarketSubstratesConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesPlugin} from "../../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager, WithdrawRequestInfo} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {RequestFeeRefundFuse, RequestFeeRefundDataEnter} from "../../../contracts/fuses/burn_request_fee/RequestFeeRefundFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

/**
 * @title RequestFeeRefundFuseTest
 * @notice Fork-based integration test suite for RequestFeeRefundFuse.
 *         Uses PlasmaVaultFactory to create the vault (no mocks).
 */
contract RequestFeeRefundFuseTest is Test {
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _USER_B = address(13131313);
    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _USDC_HOLDER = 0x47c031236e19d024b42f8AE6780E44A573170703;

    uint256 private constant _WITHDRAW_WINDOW = 1 days;
    uint256 private constant _REQUEST_FEE_RATE = 0.01e18;
    uint256 private constant _USER_REQUEST_AMOUNT = 1_000e8;

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
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER_B, 10_000e6);

        _createAccessManager();
        _createWithdrawManager();
        _createPlasmaVault();
        _initAccessManager();

        IporFusionAccessManager(_accessManager).grantRole(Roles.WHITELIST_ROLE, _USER_B, 0);

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        vm.startPrank(_USER_B);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER_B);
        vm.stopPrank();

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(_WITHDRAW_WINDOW);

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(_REQUEST_FEE_RATE);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();
    }

    // ================================================================
    // Fixture setup — real contracts via PlasmaVaultFactory
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
        FuseAction[] memory actions = _buildRefundAction(recipient_, amount_);
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _buildRefundAction(address recipient_, uint256 amount_)
        private
        view
        returns (FuseAction[] memory actions)
    {
        actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_requestFeeRefundFuse),
            data: abi.encodeWithSelector(
                RequestFeeRefundFuse.enter.selector,
                RequestFeeRefundDataEnter({recipient: recipient_, amount: amount_})
            )
        });
    }

    // ================================================================
    // 6.1 Happy paths
    // ================================================================

    function testEnter_refundsSharesFromWithdrawManagerToRecipient_whenRequestExpired() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(feeAmount, 0, "fee must be non-zero");

        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(_withdrawManager);
        vm.prank(_USER);
        IVotes(_plasmaVault).delegate(_USER);

        vm.warp(endTs + 1);

        uint256 userBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_USER);
        uint256 wmBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        uint256 userVotesBefore = IVotes(_plasmaVault).getVotes(_USER);
        uint256 wmVotesBefore = IVotes(_plasmaVault).getVotes(_withdrawManager);

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
            "withdraw manager balance must fall by feeAmount"
        );
        assertEq(IVotes(_plasmaVault).getVotes(_USER), userVotesBefore + feeAmount, "user votes must grow");
        assertEq(
            IVotes(_plasmaVault).getVotes(_withdrawManager),
            wmVotesBefore - feeAmount,
            "withdraw manager votes must fall"
        );
    }

    function testEnter_partialRefund_allowsMultipleCalls() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(feeAmount, 1, "fee must be splittable in two");
        uint256 half = feeAmount / 2;

        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(_withdrawManager);
        vm.prank(_USER);
        IVotes(_plasmaVault).delegate(_USER);

        vm.warp(endTs + 1);

        uint256 userBalStart = PlasmaVaultBase(_plasmaVault).balanceOf(_USER);
        uint256 wmBalStart = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        vm.expectEmit(true, true, true, true, address(_plasmaVault));
        emit RequestFeeRefundFuse.RequestFeeRefundEnter(address(_requestFeeRefundFuse), _USER, half, endTs);
        _executeRefund(_USER, half);

        assertEq(PlasmaVaultBase(_plasmaVault).balanceOf(_USER), userBalStart + half, "after first refund: user");
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            wmBalStart - half,
            "after first refund: wm"
        );

        vm.expectEmit(true, true, true, true, address(_plasmaVault));
        emit RequestFeeRefundFuse.RequestFeeRefundEnter(address(_requestFeeRefundFuse), _USER, half, endTs);
        _executeRefund(_USER, half);

        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_USER),
            userBalStart + 2 * half,
            "after second refund: user"
        );
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            wmBalStart - 2 * half,
            "after second refund: wm"
        );
    }

    function testEnter_refundToDifferentRecipient_whenRecipientExpired() external {
        (uint256 feeA, uint256 endA) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);

        vm.warp(endA + 1);
        (uint256 feeB, uint256 endB) = _userRequestShares(_USER_B, _USER_REQUEST_AMOUNT);
        assertGt(feeA, 0);
        assertGt(feeB, 0);
        assertGt(endB, block.timestamp, "USER_B request must still be active");

        uint256 userABefore = PlasmaVaultBase(_plasmaVault).balanceOf(_USER);
        _executeRefund(_USER, feeA);
        assertEq(PlasmaVaultBase(_plasmaVault).balanceOf(_USER), userABefore + feeA);

        FuseAction[] memory actions = _buildRefundAction(_USER_B, feeB);
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                RequestFeeRefundFuse.RequestFeeRefundRequestStillActive.selector,
                _USER_B,
                endB,
                block.timestamp
            )
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @notice Fuzz partial refund amounts in [1, feeAmount]. Invariant:
    ///         recipient balance grows by exactly `amount` and withdraw
    ///         manager balance drops by exactly `amount`.
    function testFuzz_partialRefund_recipientReceivesExactAmount(uint256 amount_) external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        amount_ = bound(amount_, 1, feeAmount);

        vm.warp(endTs + 1);

        uint256 userBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_USER);
        uint256 wmBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        _executeRefund(_USER, amount_);

        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_USER),
            userBalBefore + amount_,
            "user balance must grow by amount"
        );
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            wmBalBefore - amount_,
            "withdraw manager balance must fall by amount"
        );
    }

    // ================================================================
    // 6.2 Reverts / branches
    // ================================================================

    function testEnter_reverts_whenRecipientIsZero() external {
        FuseAction[] memory actions = _buildRefundAction(address(0), 1);
        vm.prank(_ALPHA);
        vm.expectRevert(RequestFeeRefundFuse.RequestFeeRefundInvalidRecipient.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testEnter_reverts_whenRecipientHasNoRequest() external {
        address fresh = address(0xDEADBEEF);
        FuseAction[] memory actions = _buildRefundAction(fresh, 1);
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(RequestFeeRefundFuse.RequestFeeRefundNoActiveRequest.selector, fresh)
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testEnter_reverts_whenRecipientIsWithdrawManager() external {
        FuseAction[] memory actions = _buildRefundAction(_withdrawManager, 1);
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                RequestFeeRefundFuse.RequestFeeRefundNoActiveRequest.selector,
                _withdrawManager
            )
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testEnter_reverts_whenRequestStillActive() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(endTs, block.timestamp, "request must still be active");

        FuseAction[] memory actions = _buildRefundAction(_USER, feeAmount);
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                RequestFeeRefundFuse.RequestFeeRefundRequestStillActive.selector,
                _USER,
                endTs,
                block.timestamp
            )
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @notice A second requestShares call overwrites endWithdrawWindowTimestamp.
    ///         Refund must observe the refreshed expiry, not the original one.
    function testEnter_reverts_whenNewRequestOverwritesExpiredOne() external {
        (, uint256 endTs1) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);

        vm.warp(endTs1 + 1);

        (, uint256 endTs2) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(endTs2, endTs1, "second request must refresh endTs forward");
        assertGt(endTs2, block.timestamp, "second request must be active");

        FuseAction[] memory actions = _buildRefundAction(_USER, 1);
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                RequestFeeRefundFuse.RequestFeeRefundRequestStillActive.selector,
                _USER,
                endTs2,
                block.timestamp
            )
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testEnter_reverts_atExactExpiryBoundary() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        vm.warp(endTs);

        FuseAction[] memory actions = _buildRefundAction(_USER, feeAmount);
        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                RequestFeeRefundFuse.RequestFeeRefundRequestStillActive.selector,
                _USER,
                endTs,
                endTs
            )
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    /// @notice Zero-amount short-circuits before recipient validation: passing
    ///         recipient=0 proves the amount check runs first.
    function testEnter_isNoOp_whenAmountZero() external {
        uint256 totalSupplyBefore = PlasmaVaultBase(_plasmaVault).totalSupply();
        uint256 wmBalBefore = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        FuseAction[] memory actions = _buildRefundAction(address(0), 0);

        vm.recordLogs();
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = RequestFeeRefundFuse.RequestFeeRefundEnter.selector;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != sig, "RequestFeeRefundEnter must not be emitted on zero amount");
        }

        assertEq(PlasmaVaultBase(_plasmaVault).totalSupply(), totalSupplyBefore, "totalSupply unchanged");
        assertEq(
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            wmBalBefore,
            "wm balance unchanged"
        );
    }

    function testEnter_reverts_whenAmountExceedsBalance() external {
        (, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        vm.warp(endTs + 1);

        uint256 wmBal = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        uint256 tooMuch = wmBal + 1;

        FuseAction[] memory actions = _buildRefundAction(_USER, tooMuch);

        vm.prank(_ALPHA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                _withdrawManager,
                wmBal,
                tooMuch
            )
        );
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function testExit_reverts() external {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_requestFeeRefundFuse),
            data: abi.encodeWithSelector(RequestFeeRefundFuse.exit.selector)
        });
        vm.prank(_ALPHA);
        vm.expectRevert(RequestFeeRefundFuse.RequestFeeRefundExitNotImplemented.selector);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    // ================================================================
    // 6.3 Voting-checkpoint regression
    // ================================================================

    /// @notice Proves voting checkpoints are updated on both sides of the
    ///         refund transfer when delegates differ from token holders.
    function testEnter_updatesERC20VotesCheckpoints_onBothSides() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        assertGt(feeAmount, 0);

        address managerDelegatee = address(0xD11D);
        address recipientDelegatee = address(0xD22D);

        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(managerDelegatee);
        vm.prank(_USER);
        IVotes(_plasmaVault).delegate(recipientDelegatee);

        vm.warp(endTs + 1);

        uint256 mdVotesBefore = IVotes(_plasmaVault).getVotes(managerDelegatee);
        uint256 rdVotesBefore = IVotes(_plasmaVault).getVotes(recipientDelegatee);
        assertEq(
            mdVotesBefore,
            PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager),
            "manager delegatee votes must mirror balance pre-refund"
        );

        vm.expectEmit(true, true, true, true, address(_plasmaVault));
        emit RequestFeeRefundFuse.RequestFeeRefundEnter(address(_requestFeeRefundFuse), _USER, feeAmount, endTs);
        _executeRefund(_USER, feeAmount);

        assertEq(
            IVotes(_plasmaVault).getVotes(managerDelegatee),
            mdVotesBefore - feeAmount,
            "manager delegatee votes must fall by feeAmount"
        );
        assertEq(
            IVotes(_plasmaVault).getVotes(recipientDelegatee),
            rdVotesBefore + feeAmount,
            "recipient delegatee votes must grow by feeAmount"
        );
    }

    // ================================================================
    // 6.4 Access control
    // ================================================================

    function testExecute_reverts_whenCallerIsNotAllowed() external {
        (uint256 feeAmount, uint256 endTs) = _userRequestShares(_USER, _USER_REQUEST_AMOUNT);
        vm.warp(endTs + 1);

        FuseAction[] memory actions = _buildRefundAction(_USER, feeAmount);
        vm.prank(_USER);
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER));
        PlasmaVault(_plasmaVault).execute(actions);
    }
}
