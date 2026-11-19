// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {RescueResidualRealVaultBase} from "./RescueResidualRealVaultBase.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, UpdateVaults, SweepFloor} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title RescueResidualRealVaultScenarios
/// @notice IL-9654, residual shares of a removed vault on a dispatcher, on a real `PlasmaVault` with a real access
///         manager and `WithdrawManager`. The residual sits on the dispatcher outside both of its vault sets, so the
///         fence lets a generic rescue touch it with the allowed shapes only. The scenarios prove what each shape
///         really does on the real vault: `transfer` fails on the share-transfer restriction, a plain `redeem` fails
///         on the released reserve, and the two-step recovery (`requestShares`, `releaseFunds`, `redeemFromRequest`)
///         recovers the funds. The request fee of the manager is NOT bounded on this path (Pete D-004, option A):
///         the fee is taken, also when it is raised during the timelock, and the fixed amount of the second step
///         must then be a request-after-fee amount. Every error is asserted by its full selector and arguments.
/// @dev Run once per transport (the two concrete contracts below).
abstract contract RescueResidualRealVaultScenarios is RescueResidualRealVaultBase {
    uint256 internal constant WAD = 1e18;

    // -------------------------------------------------------------------------------------------------------------
    // Calldata of the allowed shapes
    // -------------------------------------------------------------------------------------------------------------

    function _transferData(uint256 shares_) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (RECEIVER, shares_));
    }

    function _redeemData(uint256 shares_, address owner_) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC4626.redeem, (shares_, RECEIVER, owner_));
    }

    function _redeemFromRequestData(uint256 shares_, address owner_) internal pure returns (bytes memory) {
        return abi.encodeCall(PlasmaVault.redeemFromRequest, (shares_, RECEIVER, owner_));
    }

    function _requestSharesData(uint256 shares_) internal pure returns (bytes memory) {
        return abi.encodeCall(WithdrawManager.requestShares, (shares_));
    }

    /// @dev The request the manager records after taking its fee.
    function _afterFee(uint256 shares_, uint256 fee_) internal pure returns (uint256) {
        return shares_ - Math.mulDiv(shares_, fee_, WAD);
    }

    function _shapeError(address target_, bytes4 selector_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CrosschainErrors.RescueCallShapeNotAllowed.selector, target_, selector_);
    }

    function _trackedVaultError() internal view returns (bytes memory) {
        return abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault));
    }

    /// @dev The one-argument error of `PlasmaVault.redeemFromRequest` (a refused request).
    function _vaultRequestRefused(uint256 shares_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PlasmaVault.WithdrawManagerInvalidSharesToRelease.selector, shares_);
    }

    /// @dev Schedules the two steps of the last resort together: the request of `requested_` shares and the redemption
    ///      of `redeemed_` shares, the dispatcher as the owner.
    function _scheduleBothSteps(
        uint256 requested_,
        uint256 redeemed_
    ) internal returns (uint256 requestId, uint256 redeemId) {
        requestId = _schedule(address(withdrawManager), _requestSharesData(requested_));
        redeemId = _schedule(address(vault), _redeemFromRequestData(redeemed_, _host()));
    }

    /// @dev After the first step: ALPHA releases `reserve_` shares with a stamp later than the request.
    function _releaseAfterRequest(uint256 reserve_) internal {
        _release(reserve_);
    }

    // -------------------------------------------------------------------------------------------------------------
    // C1, C2, C3: what the plain shapes do on the real vault
    // -------------------------------------------------------------------------------------------------------------

    /// @notice C1: the removal leaves the whole position on the dispatcher, outside both vault sets.
    function testShouldLeaveTheWholePositionOutsideBothVaultSetsAfterRemoval() public {
        uint256 shares = _createResidual();
        assertEq(withdrawManager.getSharesToRelease(), vault.totalSupply(), "the reserve covers the whole supply");
        assertEq(vault.totalSupply(), shares, "the host is the only holder");
    }

    /// @notice C2: `transfer` passes the fence at schedule and fails at execution on the share-transfer restriction.
    function testShouldFailTransferOfTheResidualOnTheShareTransferRestriction() public {
        uint256 shares = _createResidual();
        bytes memory data = _transferData(shares);
        uint256 id = _schedule(address(vault), data);
        _warpTimelock();

        _expectExecuteRevert(
            id,
            data,
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, _host())
        );
        assertEq(vault.balanceOf(_host()), shares, "shares untouched");
        assertEq(vault.balanceOf(RECEIVER), 0, "nothing moved");
    }

    /// @notice C3: a plain `redeem` fails when the cash covers only the reserve. The revert is the THREE-argument
    ///         `WithdrawManager.WithdrawManagerInvalidSharesToRelease`, not the one-argument error of the vault.
    function testShouldFailPlainRedeemOfTheResidualOnTheReserve() public {
        uint256 shares = _createResidual();
        assertTrue(
            WithdrawManager.WithdrawManagerInvalidSharesToRelease.selector !=
                PlasmaVault.WithdrawManagerInvalidSharesToRelease.selector,
            "two different errors share one name"
        );
        bytes memory data = _redeemData(shares, _host());
        uint256 id = _schedule(address(vault), data);
        _warpTimelock();

        uint256 unallocated = vault.convertToShares(asset.balanceOf(address(vault)));
        _expectExecuteRevert(
            id,
            data,
            abi.encodeWithSelector(
                WithdrawManager.WithdrawManagerInvalidSharesToRelease.selector,
                withdrawManager.getSharesToRelease(),
                shares,
                unallocated
            )
        );
        assertEq(vault.balanceOf(_host()), shares, "shares untouched");
        assertEq(asset.balanceOf(RECEIVER), 0, "nothing paid");
    }

    // -------------------------------------------------------------------------------------------------------------
    // C4, C5: the recovery
    // -------------------------------------------------------------------------------------------------------------

    /// @notice C4: last resort without a request fee. `requestShares` and `redeemFromRequest` are scheduled together;
    ///         the first runs, ALPHA releases, the second runs inside the window. The receiver gets the assets and
    ///         the residual is gone.
    function testShouldRecoverTheResidualWithTheTwoStepRescueWithoutFee() public {
        uint256 shares = _createResidual();
        uint256 backing = _fundHostAsset(7);
        assertEq(withdrawManager.getRequestFee(), 0, "no request fee");
        bytes memory requestData = _requestSharesData(shares);
        bytes memory redeemData = _redeemFromRequestData(shares, _host());
        (uint256 requestId, uint256 redeemId) = _scheduleBothSteps(shares, shares);
        _warpTimelock();

        _execute(requestId, requestData);
        assertEq(vault.balanceOf(_host()), shares, "the request moves no shares without a fee");
        assertEq(withdrawManager.requestInfo(_host()).shares, shares, "the request is on record");
        _assertHostAssetFloor(backing, "ASSET floor after the request step");

        _releaseAfterRequest(shares);
        assertTrue(withdrawManager.requestInfo(_host()).canWithdraw, "the request is released and in its window");
        uint256 expectedAssets = vault.convertToAssets(shares);
        _execute(redeemId, redeemData);

        assertEq(vault.balanceOf(_host()), 0, "the residual is gone");
        assertEq(asset.balanceOf(RECEIVER), expectedAssets, "the receiver got the assets");
        assertGt(expectedAssets, 0, "a real payout");
        _assertHostAssetFloor(backing, "ASSET floor after the redeem step");
    }

    /// @notice C5: only the second step is needed when a request filed by a command before the removal is released
    ///         and still inside its window (the window is longer than the timelock).
    /// @dev The request is filed by the dispatcher itself, which is exactly what the `REQUEST_SHARES` command does on
    ///      a tracked vault; the command encoding is not the subject here.
    function testShouldRecoverTheResidualWithTheSecondStepAloneAfterACommandRequest() public {
        uint256 shares = _depositForHost();
        _trackVault();
        vm.prank(_host());
        withdrawManager.requestShares(shares);
        _release(vault.totalSupply());
        _removeVault();
        _assertResidual(shares);
        uint256 backing = _fundHostAsset(7);
        assertGt(WITHDRAW_WINDOW, RESCUE_DELAY, "the window is longer than the timelock");

        bytes memory data = _redeemFromRequestData(shares, _host());
        uint256 id = _schedule(address(vault), data);
        _warpTimelock();
        assertTrue(withdrawManager.requestInfo(_host()).canWithdraw, "still inside the window");
        uint256 expectedAssets = vault.convertToAssets(shares);
        _execute(id, data);

        assertEq(vault.balanceOf(_host()), 0, "the residual is gone");
        assertEq(asset.balanceOf(RECEIVER), expectedAssets, "the receiver got the assets");
        _assertHostAssetFloor(backing, "ASSET floor after the redeem step");
    }

    // -------------------------------------------------------------------------------------------------------------
    // C6, C7: refusals at schedule
    // -------------------------------------------------------------------------------------------------------------

    /// @notice C6: `requestShares` on the manager of a TRACKED vault is refused at schedule, naming the vault (not the
    ///         manager, which is the rescue target).
    function testShouldRefuseRequestSharesOnTheManagerOfATrackedVault() public {
        uint256 shares = _depositForHost();
        _trackVault();
        assertTrue(_isTracked(), "tracked");
        _expectScheduleRevert(address(withdrawManager), _requestSharesData(shares), _trackedVaultError());
        assertEq(_rescue().rescueCount(), 0, "nothing queued");
    }

    /// @notice C7: `redeem` and `redeemFromRequest` with an owner other than the dispatcher are refused at schedule.
    function testShouldRefuseAnOwnerOtherThanTheDispatcher() public {
        uint256 shares = _createResidual();
        address other = address(0x0DD);
        _expectScheduleRevert(
            address(vault),
            _redeemFromRequestData(shares, other),
            _shapeError(address(vault), PlasmaVault.redeemFromRequest.selector)
        );
        _expectScheduleRevert(
            address(vault),
            _redeemData(shares, other),
            _shapeError(address(vault), IERC4626.redeem.selector)
        );
        assertEq(_rescue().rescueCount(), 0, "nothing queued");
    }

    // -------------------------------------------------------------------------------------------------------------
    // C8: the vault comes back between schedule and execute
    // -------------------------------------------------------------------------------------------------------------

    /// @notice C8: re-adding the vault during the timelock makes `redeem` fail at execution (the vault is now tracked).
    function testShouldRefuseRedeemAtExecuteWhenTheVaultIsReAdded() public {
        uint256 shares = _createResidual();
        bytes memory data = _redeemData(shares, _host());
        uint256 id = _schedule(address(vault), data);
        _warpTimelock();
        _trackVault();
        assertTrue(_isTracked(), "re-added and tracked");

        _expectExecuteRevert(id, data, _trackedVaultError());
        assertEq(vault.balanceOf(_host()), shares, "shares untouched");
    }

    /// @notice C8: the same for `redeemFromRequest`.
    function testShouldRefuseRedeemFromRequestAtExecuteWhenTheVaultIsReAdded() public {
        uint256 shares = _createResidual();
        bytes memory data = _redeemFromRequestData(shares, _host());
        uint256 id = _schedule(address(vault), data);
        _warpTimelock();
        _trackVault();
        assertTrue(_isTracked(), "re-added and tracked");

        _expectExecuteRevert(id, data, _trackedVaultError());
        assertEq(vault.balanceOf(_host()), shares, "shares untouched");
    }

    /// @notice C8: and for `requestShares`, where the rescue target is the manager and the error names the vault.
    function testShouldRefuseRequestSharesAtExecuteWhenTheVaultIsReAdded() public {
        uint256 shares = _createResidual();
        bytes memory data = _requestSharesData(shares);
        uint256 id = _schedule(address(withdrawManager), data);
        _warpTimelock();
        _trackVault();
        assertTrue(_isTracked(), "re-added and tracked");

        _expectExecuteRevert(id, data, _trackedVaultError());
        assertEq(withdrawManager.requestInfo(_host()).shares, 0, "no request was filed");
        assertEq(vault.balanceOf(_host()), shares, "shares untouched");
    }

    // -------------------------------------------------------------------------------------------------------------
    // C9, C10: the request fee is not bounded on the rescue path (Pete D-004, option A)
    // -------------------------------------------------------------------------------------------------------------

    /// @notice C9: with a non-zero request fee the first step takes the fee (it is not refused), the second step is
    ///         planned with the request after the fee, and both pass.
    function testShouldTakeTheRequestFeeAndRecoverTheRest() public {
        uint256 shares = _createResidual();
        uint256 backing = _fundHostAsset(7);
        uint256 fee = 0.1e18;
        _setRequestFee(fee);
        uint256 net = _afterFee(shares, fee);
        assertLt(net, shares, "the fee takes shares");
        bytes memory requestData = _requestSharesData(shares);
        bytes memory redeemData = _redeemFromRequestData(net, _host());
        (uint256 requestId, uint256 redeemId) = _scheduleBothSteps(shares, net);
        _warpTimelock();

        _execute(requestId, requestData);
        assertEq(vault.balanceOf(address(withdrawManager)), shares - net, "the manager took the fee");
        assertEq(vault.balanceOf(_host()), net, "the rest stays on the dispatcher");
        assertEq(withdrawManager.requestInfo(_host()).shares, net, "the request is the amount after the fee");
        _assertHostAssetFloor(backing, "ASSET floor after the request step");

        _releaseAfterRequest(net);
        uint256 expectedAssets = vault.convertToAssets(net);
        _execute(redeemId, redeemData);

        assertEq(vault.balanceOf(_host()), 0, "the dispatcher holds nothing");
        assertEq(asset.balanceOf(RECEIVER), expectedAssets, "the receiver got the assets of the rest");
        _assertHostAssetFloor(backing, "ASSET floor after the redeem step");
    }

    /// @notice C10: the fee is raised during the timelock. The first step still runs without a revert and takes the
    ///         higher fee. The second step planned with the old amount exceeds the request and reverts with the
    ///         one-argument vault error; the variant planned in parallel with the lower amount passes.
    function testShouldTakeAFeeRaisedDuringTheTimelockAndRecoverWithTheLowerAmountVariant() public {
        uint256 shares = _createResidual();
        uint256 plannedFee = 0.05e18;
        uint256 raisedFee = 0.5e18;
        _setRequestFee(plannedFee);
        uint256 stale = _afterFee(shares, plannedFee);
        uint256 lower = _afterFee(shares, raisedFee);
        assertLt(lower, stale, "the raised fee lowers the request");
        bytes memory requestData = _requestSharesData(shares);
        bytes memory staleData = _redeemFromRequestData(stale, _host());
        bytes memory lowerData = _redeemFromRequestData(lower, _host());
        (uint256 requestId, uint256 staleId) = _scheduleBothSteps(shares, stale);
        uint256 lowerId = _schedule(address(vault), lowerData);
        _warpTimelock();
        _setRequestFee(raisedFee);

        _execute(requestId, requestData);
        assertEq(vault.balanceOf(address(withdrawManager)), shares - lower, "the raised fee was taken");
        assertEq(withdrawManager.requestInfo(_host()).shares, lower, "the request is the lower amount");

        _releaseAfterRequest(lower);
        _expectExecuteRevert(staleId, staleData, _vaultRequestRefused(stale));
        assertEq(vault.balanceOf(_host()), lower, "the refused step moved nothing");

        uint256 expectedAssets = vault.convertToAssets(lower);
        _execute(lowerId, lowerData);
        assertEq(vault.balanceOf(_host()), 0, "the dispatcher holds nothing");
        assertEq(asset.balanceOf(RECEIVER), expectedAssets, "the receiver got the assets of the lower amount");
    }

    /// @notice C10 at 100 %: the first step passes without a revert and the whole residual goes to the manager; the
    ///         second step reverts, there is nothing left to redeem.
    function testShouldHandTheWholeResidualToTheManagerWhenTheFeeIsRaisedToOneHundredPercent() public {
        uint256 shares = _createResidual();
        uint256 plannedFee = 0.05e18;
        _setRequestFee(plannedFee);
        uint256 stale = _afterFee(shares, plannedFee);
        bytes memory requestData = _requestSharesData(shares);
        bytes memory staleData = _redeemFromRequestData(stale, _host());
        (uint256 requestId, uint256 staleId) = _scheduleBothSteps(shares, stale);
        _warpTimelock();
        _setRequestFee(WAD);

        _execute(requestId, requestData);
        assertEq(vault.balanceOf(address(withdrawManager)), shares, "the whole residual went to the manager");
        assertEq(vault.balanceOf(_host()), 0, "nothing is left on the dispatcher");
        assertEq(withdrawManager.requestInfo(_host()).shares, 0, "the request is empty");

        _releaseAfterRequest(stale);
        _expectExecuteRevert(staleId, staleData, _vaultRequestRefused(stale));
        assertEq(asset.balanceOf(RECEIVER), 0, "nothing was paid");
    }
}

/// @notice The Stargate dispatcher: tracking and removal go through real `UPDATE_VAULTS` messages.
contract StargateRescueResidualRealVaultTest is RescueResidualRealVaultScenarios {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");
    address internal constant STARGATE_ADMIN = address(0xADADAD);

    MockLzEndpoint internal endpoint;
    StargateCrosschainDispatcher internal dispatcher;
    uint64 internal nextSequence;
    uint64 internal nextEpoch = 1;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStargatePool pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        _deployVault(usdc);
        _deployDispatcher(usdc, pool);
    }

    function _host() internal view override returns (address) {
        return address(dispatcher);
    }

    function _admin() internal pure override returns (address) {
        return STARGATE_ADMIN;
    }

    function _isTracked() internal view override returns (bool) {
        return dispatcher.isTrackedVault(address(vault));
    }

    function _isAllowed() internal view override returns (bool) {
        return dispatcher.isAllowedVault(address(vault));
    }

    function _trackVault() internal override {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _updateVaults(vaults);
    }

    function _removeVault() internal override {
        _updateVaults(new address[](0));
    }

    /// @dev `UPDATE_VAULTS` replaces the allowlist: the host re-tracks the allowlisted vaults it holds shares of and
    ///      sweeps and untracks the vaults that left.
    function _updateVaults(address[] memory vaults_) internal {
        bytes memory envelope = CrosschainMessages.encodeUpdateVaults(
            UpdateVaults({
                commandId: keccak256(abi.encode("uv", nextSequence)),
                sequence: nextSequence,
                newConfigEpoch: nextEpoch,
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                vaults: vaults_,
                floors: new SweepFloor[](0)
            })
        );
        ++nextSequence;
        ++nextEpoch;
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope
        );
    }

    /// @notice C6 on Stargate: a vault that is only ALLOWLISTED (no shares yet, so not tracked) blocks the request
    ///         rescue on its manager as well; the rule uses the set of banned vaults, not the tracked set alone.
    function testShouldRefuseRequestSharesOnTheManagerOfAnAllowlistedUntrackedVault() public {
        _trackVault();
        assertTrue(_isAllowed(), "allowlisted");
        assertFalse(_isTracked(), "not tracked: the host holds no shares yet");
        _expectScheduleRevert(address(withdrawManager), _requestSharesData(1), _trackedVaultError());
        assertEq(_rescue().rescueCount(), 0, "nothing queued");
    }

    function _deployDispatcher(MockERC20 usdc_, MockStargatePool pool_) internal {
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](2);
        enforced[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforced[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc_),
            address(pool_),
            ASSET_ID,
            address(0xF),
            STARGATE_ADMIN,
            address(0x6A6A6A),
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforced)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }
}

/// @notice The CCIP dispatcher: tracking and removal go through real `UPDATE_VAULTS` messages sent by the executor.
contract CcipRescueResidualRealVaultTest is RescueResidualRealVaultScenarios {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant CCIP_ADMIN = address(0xA11);

    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.warp(365 days);
        MockERC20 token = new MockERC20("USD", "USD", 18);
        _deployVault(token);
        _deployPair(token);
    }

    function _host() internal view override returns (address) {
        return address(dispatcher);
    }

    function _admin() internal pure override returns (address) {
        return CCIP_ADMIN;
    }

    function _isTracked() internal view override returns (bool) {
        return dispatcher.isTrackedVault(address(vault));
    }

    function _isAllowed() internal view override returns (bool) {
        return dispatcher.isAllowedVault(address(vault));
    }

    /// @dev Allowlisting a vault on CCIP tracks it at once.
    function _trackVault() internal override {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _removeVault() internal override {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, false, false, 0, address(0), 2_000_000);
    }

    function _deployPair(MockERC20 token_) internal {
        MockCcipRouter router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token_),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token_),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            CCIP_ADMIN,
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);

        token_.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        vm.warp(block.timestamp + 1);
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            100e18,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }
}
