// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {MockLzEndpoint} from "../mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "../mocks/MockStargatePool.sol";
import {DEFAULT_COMMAND_BUDGET} from "../CommandBudget.sol";
import {BusinessAction} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer,
    SweepFloor
} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainDispatcher} from "../../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {IChainlinkFeedLike} from "./interfaces/IChainlinkFeedLike.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";

/// @title RescueShapeFenceEvkForkBase
/// @notice IL-9654 fork fixture: a Stargate dispatcher (mock LayerZero endpoint and pool, real USDC) on an Ethereum fork
///         holds tracked shares of a real Euler EVK vault and talks to the real Ethereum Vault Connector. The fixture
///         builds the `(target, calldata)` pairs of three generic-rescue routes and the later uses of the resulting
///         rights; it never schedules or executes anything, so the same builders serve the proof on the base commit
///         and the rejection tests on the changed library.
/// @dev Setup is copied from `StargateDispatcherFixture` and `RescueVaultConnectorFenceTest` of the IL-9654 patch (no
///      import from the unit suite). Concrete tests pick their own fork block (`_forkBlock`): suites sharing a fork URL
///      and block share a backend, and a parallel `vm.warp` would leak between them.
abstract contract RescueShapeFenceEvkForkBase is Test {
    using OptionsBuilder for bytes;

    /// @dev Real Ethereum Vault Connector.
    address internal constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    /// @dev Euler Prime USDC (eUSDC-2): the tracked vault and the collateral of route 3.
    address internal constant TRACKED_VAULT = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    /// @dev eUSDC-22: lending sibling (controller) that lists the tracked vault as collateral.
    address internal constant BORROW_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Chainlink USDC/USD feed that the vaults' price oracle reads for the route-3 account status check.
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant GUID = keccak256("guid");
    address internal constant ADMIN = address(0xADADAD);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant DEPOSIT_AMOUNT = 50e6;
    uint256 internal constant BORROW_AMOUNT = 5e6;

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    StargateCrosschainDispatcher internal dispatcher;
    /// @dev Share balance of the dispatcher in `TRACKED_VAULT` right after the deposit command.
    uint256 internal depositedShares;

    /// @dev Fork block of the concrete test contract.
    function _forkBlock() internal pure virtual returns (uint256);

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _forkBlock());
        vm.chainId(42161);

        pool = new MockStargatePool(USDC, 6);
        endpoint = new MockLzEndpoint();
        dispatcher = _deployStargateDispatcher(address(endpoint), USDC, address(pool), ADMIN, EXECUTOR_EID);
        vm.deal(address(dispatcher), 100 ether);

        // The dispatcher holds tracked shares: allowlist the real vault, bridge assets in, DEPOSIT them.
        address[] memory vaults = new address[](1);
        vaults[0] = TRACKED_VAULT;
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("uv"),
                    sequence: 0,
                    newConfigEpoch: 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults,
                    floors: new SweepFloor[](0)
                })
            )
        );
        deal(USDC, address(dispatcher), 100e6);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            100e6,
            CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: keccak256("t1")}))
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep"),
                    sequence: 1,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(TRACKED_VAULT, DEPOSIT_AMOUNT, 0)
                })
            )
        );
        depositedShares = IERC20(TRACKED_VAULT).balanceOf(address(dispatcher));
        assertTrue(dispatcher.isTrackedVault(TRACKED_VAULT), "vault tracked");
        assertGt(depositedShares, 0, "dispatcher holds shares");
    }

    // ---------------------------------------------------------------------
    // Route 1: operator grant on the dispatcher's EVC account
    // ---------------------------------------------------------------------

    /// @dev Rescue call: `EVC.setAccountOperator(dispatcher, ADMIN, true)`.
    function _route1OperatorGrant() internal view returns (address target, bytes memory callData) {
        target = EVC;
        callData = abi.encodeCall(IEVC.setAccountOperator, (address(dispatcher), ADMIN, true));
    }

    /// @dev Later use: the admin, now an operator, moves the dispatcher's shares through the EVC. No timelock.
    function _route1LaterUse() internal {
        vm.prank(ADMIN);
        IEVC(EVC).call(
            TRACKED_VAULT,
            address(dispatcher),
            0,
            abi.encodeCall(IERC20.transfer, (ADMIN, depositedShares))
        );
    }

    // ---------------------------------------------------------------------
    // Route 2: share approve relayed by the EVC on behalf of the dispatcher
    // ---------------------------------------------------------------------

    /// @dev Rescue call: `EVC.call(vault, dispatcher, 0, approve(ADMIN, max))`.
    function _route2RelayedApprove() internal view returns (address target, bytes memory callData) {
        target = EVC;
        callData = abi.encodeCall(
            IEVC.call,
            (TRACKED_VAULT, address(dispatcher), 0, abi.encodeCall(IERC20.approve, (ADMIN, type(uint256).max)))
        );
    }

    /// @dev Later use: the admin pulls the dispatcher's shares with the allowance. No timelock.
    function _route2LaterUse() internal {
        vm.prank(ADMIN);
        IERC20(TRACKED_VAULT).transferFrom(address(dispatcher), ADMIN, depositedShares);
    }

    // ---------------------------------------------------------------------
    // Route 3: controller borrow through a lending sibling vault
    // ---------------------------------------------------------------------

    /// @dev Rescue call 1: `EVC.enableCollateral(dispatcher, trackedVault)`.
    function _route3EnableCollateral() internal view returns (address target, bytes memory callData) {
        target = EVC;
        callData = abi.encodeCall(IEVC.enableCollateral, (address(dispatcher), TRACKED_VAULT));
    }

    /// @dev Rescue call 2: `EVC.enableController(dispatcher, borrowVault)`.
    function _route3EnableController() internal view returns (address target, bytes memory callData) {
        target = EVC;
        callData = abi.encodeCall(IEVC.enableController, (address(dispatcher), BORROW_VAULT));
    }

    /// @dev Rescue call 3: `borrow(amount, ADMIN)` on the controller vault; the debt lands on the dispatcher's account.
    function _route3Borrow(uint256 amount_) internal pure returns (address target, bytes memory callData) {
        target = BORROW_VAULT;
        callData = abi.encodeCall(IBorrowing.borrow, (amount_, ADMIN));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Time-travel artefact only: the rescue timelock moves the fork clock days ahead of the pinned block, so the
    ///      price oracle would reject the feed as stale. Re-reports the feed's real round with a fresh timestamp; call it
    ///      after `vm.warp` and before the route-3 borrow.
    function _refreshUsdcUsdFeed() internal {
        (uint80 roundId, int256 answer, uint256 startedAt, , uint80 answeredInRound) = IChainlinkFeedLike(USDC_USD_FEED)
            .latestRoundData();
        vm.mockCall(
            USDC_USD_FEED,
            abi.encodeCall(IChainlinkFeedLike.latestRoundData, ()),
            abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
        );
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    /// @dev Deploys a Stargate dispatcher from its compiled artifact (the test contract stays under the create limit).
    function _deployStargateDispatcher(
        address endpoint_,
        address asset_,
        address pool_,
        address admin_,
        uint32 executorEid_
    ) internal returns (StargateCrosschainDispatcher) {
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](2);
        enforced[0] = EnforcedOptionParam({
            eid: executorEid_,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforced[1] = EnforcedOptionParam({
            eid: executorEid_,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            endpoint_,
            asset_,
            pool_,
            keccak256("USDC"),
            address(0xF),
            admin_,
            address(0x6A6A6A),
            RESCUE_DELAY,
            uint256(1),
            executorEid_,
            abi.encode(enforced)
        );
        return
            StargateCrosschainDispatcher(
                payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
            );
    }
}
