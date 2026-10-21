// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipCrosschainFactory} from "../../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction, CommandStatus} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @notice Router 1.2.0 surface used by the fork tests (the vendored `ICcipRouterClient` has only the sender half).
interface ICcipRouterFork {
    struct OffRampEntry {
        uint64 sourceChainSelector;
        address offRamp;
    }

    function typeAndVersion() external view returns (string memory);
    function isChainSupported(uint64 chainSelector_) external view returns (bool);
    function getOnRamp(uint64 destChainSelector_) external view returns (address);
    function getOffRamps() external view returns (OffRampEntry[] memory);
    function isOffRamp(uint64 sourceChainSelector_, address offRamp_) external view returns (bool);
    function routeMessage(
        CcipClient.Any2EVMMessage calldata message_,
        uint16 gasForCallExactCheck_,
        uint256 gasLimit_,
        address receiver_
    ) external returns (bool success, bytes memory retBytes, uint256 gasUsed);
}

/// @notice CCIP 2.0 OffRamp surface (`OffRamp 2.0.0`, verified source on Arbiscan / Etherscan).
interface ICcipOffRampV2 {
    struct StaticConfig {
        uint64 localChainSelector;
        uint16 gasForCallExactCheck;
        address rmnRemote;
        address tokenAdminRegistry;
        uint32 maxGasBufferToUpdateState;
    }

    function typeAndVersion() external view returns (string memory);
    function getStaticConfig() external view returns (StaticConfig memory);
    function getExecutionState(bytes32 messageId_) external view returns (uint8);
    function getCCVsForMessage(
        bytes calldata encodedMessage_
    ) external view returns (address[] memory requiredCCVs, address[] memory optionalCCVs, uint8 threshold);
    function execute(
        bytes calldata encodedMessage_,
        address[] calldata ccvs_,
        bytes[] calldata verifierResults_,
        uint32 gasLimitOverride_
    ) external;
}

/// @notice `ICrossChainVerifierResolver.getInboundImplementation` — the only CCV call the tests intercept.
interface ICcvResolverFork {
    function getInboundImplementation(bytes calldata verifierResults_) external view returns (address);
}

/// @notice Stand-in CCV implementation: accepts every `verifyMessage` call. Used ONLY to replace the committee
///         signature check, which cannot be reproduced on a fork; every other OffRamp check stays real.
contract CcipForkAcceptingVerifier {
    fallback() external {}
}

/// @notice One CCIP 2.0 message as the real source OnRamp emitted it, plus the fields the tests read from it.
struct CcipForkMessage {
    bytes32 messageId;
    bytes encoded;
    uint64 sourceChainSelector;
    uint64 destChainSelector;
    uint64 messageNumber;
    uint32 ccipReceiveGasLimit;
    address offRamp;
    bytes sender;
    address receiver;
    address destToken;
    uint256 tokenAmount;
    bytes data;
    uint256 appFee;
}

/// @notice Test-only reader of the CCIP 2.0 `MessageV1` wire format, written from the layout documented in
///         Chainlink `MessageV1Codec` (OffRamp 2.0.0 verified source). It only reads; the real OffRamp decodes
///         the same bytes on execution, so a parsing mistake here fails the round trip.
library CcipForkMessageV1Reader {
    error UnsupportedMessageVersion(uint8 version);

    function read(bytes memory m_) internal pure returns (CcipForkMessage memory out) {
        if (uint8(m_[0]) != 1) revert UnsupportedMessageVersion(uint8(m_[0]));
        out.sourceChainSelector = uint64(_uint(m_, 1, 8));
        out.destChainSelector = uint64(_uint(m_, 9, 8));
        out.messageNumber = uint64(_uint(m_, 17, 8));
        // 25: executionGasLimit (4)
        out.ccipReceiveGasLimit = uint32(_uint(m_, 29, 4));
        // 33: finality (4), 37: ccvAndExecutorHash (32)
        uint256 p = 69;
        bytes memory field;
        (field, p) = _var(m_, p, 1); // onRamp
        (field, p) = _var(m_, p, 1); // offRamp (20 raw bytes)
        // casting to 'bytes20' is safe because the wire format stores this EVM address as exactly 20 raw bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        out.offRamp = address(bytes20(field));
        (out.sender, p) = _var(m_, p, 1); // abi-encoded sender (32 bytes)
        (field, p) = _var(m_, p, 1); // receiver (20 raw bytes)
        // casting to 'bytes20' is safe because the wire format stores this EVM address as exactly 20 raw bytes
        // forge-lint: disable-next-line(unsafe-typecast)
        out.receiver = address(bytes20(field));
        (field, p) = _var(m_, p, 2); // destBlob
        bytes memory tokenTransfer;
        (tokenTransfer, p) = _var(m_, p, 2);
        if (tokenTransfer.length != 0) {
            // version(1) | amount(32) | sourcePool(1+n) | sourceToken(1+n) | destToken(1+20) | receiver(1+20) | extra
            out.tokenAmount = _uint(tokenTransfer, 1, 32);
            uint256 q = 33;
            (field, q) = _var(tokenTransfer, q, 1);
            (field, q) = _var(tokenTransfer, q, 1);
            (field, q) = _var(tokenTransfer, q, 1);
            // casting to 'bytes20' is safe because the wire format stores this EVM address as exactly 20 raw bytes
            // forge-lint: disable-next-line(unsafe-typecast)
            out.destToken = address(bytes20(field));
        }
        (out.data, p) = _var(m_, p, 2);
        out.encoded = m_;
        out.messageId = keccak256(m_);
    }

    function _uint(bytes memory b_, uint256 at_, uint256 len_) private pure returns (uint256 v) {
        for (uint256 i; i < len_; ++i) {
            v = (v << 8) | uint8(b_[at_ + i]);
        }
    }

    function _var(
        bytes memory b_,
        uint256 at_,
        uint256 lenBytes_
    ) private pure returns (bytes memory out, uint256 next) {
        uint256 len = _uint(b_, at_, lenBytes_);
        uint256 start = at_ + lenBytes_;
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = b_[start + i];
        }
        next = start + len;
    }
}

/// @title CcipForkBase
/// @notice Real-transport fixtures for the CCIP stack (IL-8458 / Codex O-14). Two pinned mainnet forks — Ethereum
///         (executor side) and Arbitrum (dispatcher side) — each with the real CCIP Router 1.2.0 and the live CCIP 2.0
///         OnRamp / OffRamp / FeeQuoter behind it. The factory is deployed at the same address on both forks (same
///         deployer, same nonce), exactly as production uses one CREATE3 address per chain.
/// @dev What is real: routers, OnRamps (fee quote, extra-args handling, token lock/burn), the message bytes the
///      OnRamp emits, the destination OffRamp's `execute` state machine (curse check, source/onRamp/offRamp checks,
///      execution states, gas-limit override rules, exact-gas router call) and `Router.routeMessage`. What is not:
///      the CCV (committee) signature check — `getInboundImplementation` is mocked to an accepting verifier — and,
///      for token messages, the destination pool's release (the tokens are dealt to the receiver and the message is
///      routed through the real Router as the OffRamp would after a release).
abstract contract CcipForkBase is Test {
    using CcipForkMessageV1Reader for bytes;

    // ---- pinned forks -------------------------------------------------------------------------------------------
    uint256 internal constant ETHEREUM_FORK_BLOCK = 26_082_000;
    uint256 internal constant ARBITRUM_FORK_BLOCK = 510_000_000;
    uint256 internal constant BASE_FORK_BLOCK = 51_945_000;

    // ---- chains, CCIP (Router 1.2.0, verified isChainSupported at the pinned blocks) ------------------------------
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint64 internal constant ETHEREUM_SELECTOR = 5009297550715157269;
    uint64 internal constant ARBITRUM_SELECTOR = 4949039107694359620;
    uint64 internal constant BASE_SELECTOR = 15971525489660198786;
    address internal constant ETHEREUM_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address internal constant ARBITRUM_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address internal constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;

    // ---- assets ------------------------------------------------------------------------------------------------
    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev Fluid USD Coin (fUSDC), a live ERC-4626 over native Arbitrum USDC, used as the remote vault.
    address internal constant ARBITRUM_FLUID_USDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    uint8 internal constant SHARED_DECIMALS = 6;

    // ---- route policy -------------------------------------------------------------------------------------------
    uint96 internal constant MESSAGE_GAS_LIMIT = 6_000_000;
    /// @dev Destination gas for the CREATE_DISPATCHER ticket (CREATE3 deploy of the dispatcher). Timelocked
    ///      factory policy, separate from the route's `messageGasLimit` (IL-8593); sized with headroom over the
    ///      measured deploy (~6.1M at IL-8583) — the final size round of the IL-8551 series revisits it.
    uint96 internal constant DISPATCHER_DEPLOY_GAS_LIMIT = 7_000_000;
    uint96 internal constant TOKEN_GAS_LIMIT = 1_000_000;
    uint256 internal constant MAX_FEE = 0.01 ether;
    address internal constant FEE_TOKEN = address(0); // native

    string internal constant OFFRAMP_V2 = "OffRamp 2.0.0";
    bytes32 internal constant USER_SALT = keccak256("IL-8458-ccip-fork-executor");
    bytes32 internal constant APP_SENT_TOPIC = keccak256("CcipMessageSent(bytes32,uint256,bool,uint256)");

    uint256 internal ethFork;
    uint256 internal arbFork;
    address internal factoryDeployer;
    CcipCrosschainFactory internal factory; // same address on both forks
    CcipCrosschainExecutor internal executor; // Ethereum
    CcipCrosschainDispatcher internal dispatcher; // Arbitrum, same address as the executor
    /// @dev Executor storage slots written while the stack was set up; see `_warmExecutorStorage`.
    bytes32[] internal executorSetUpSlots;
    /// @dev Stand-in CCV implementation, etched at the same address on each fork.
    address internal constant ACCEPTING_VERIFIER = address(uint160(uint256(keccak256("IL-8458-accepting-ccv"))));

    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant RESCUE_GUARDIAN = address(0xB22);
    address internal constant BALANCE_APPROVER = address(0xA33);

    // =============================================================================================================
    // Stack
    // =============================================================================================================

    /// @dev Fork blocks of this suite. forge shares one fork backend between test suites that fork the same URL at the
    ///      same block, and in parallel runs a `vm.warp` of one suite could then reach another: the Arbitrum
    ///      dispatcher saw a timestamp past the command deadline and NACKed (`response type: 7 != 6`, only with
    ///      `-j > 1`). Suites that run the full CCIP lifecycle override this with blocks of their own.
    function _forkBlocks() internal pure virtual returns (uint256 ethereumBlock, uint256 arbitrumBlock) {
        return (ETHEREUM_FORK_BLOCK, ARBITRUM_FORK_BLOCK);
    }

    function _setUpForks() internal {
        (uint256 ethereumBlock, uint256 arbitrumBlock) = _forkBlocks();
        ethFork = vm.createFork(vm.envString("ETHEREUM_PROVIDER_URL"), ethereumBlock);
        arbFork = vm.createFork(vm.envString("ARBITRUM_PROVIDER_URL"), arbitrumBlock);
        factoryDeployer = makeAddr("IL-8458-ccip-factory-deployer");
    }

    /// @dev Factory + asset + creation codes + route to `remoteChainId_` on the selected fork. Returns the factory.
    function _deployFactory(
        address router_,
        uint256 remoteChainId_,
        uint64 remoteSelector_
    ) internal returns (CcipCrosschainFactory deployed) {
        assertEq(ICcipRouterFork(router_).typeAndVersion(), "Router 1.2.0", "router version");
        assertTrue(ICcipRouterFork(router_).isChainSupported(remoteSelector_), "lane supported");
        vm.prank(factoryDeployer);
        deployed = new CcipCrosschainFactory(router_, address(this));
        address token = block.chainid == ETHEREUM_CHAIN_ID
            ? ETHEREUM_USDC
            : block.chainid == ARBITRUM_CHAIN_ID
                ? ARBITRUM_USDC
                : BASE_USDC;
        deployed.scheduleAsset(ASSET_ID, token, SHARED_DECIMALS);
        vm.warp(block.timestamp + deployed.CONFIG_DELAY());
        deployed.executeAsset(ASSET_ID, token, SHARED_DECIMALS);
        deployed.configureCreationCodes(
            type(CcipCrosschainExecutor).creationCode,
            type(CcipCrosschainDispatcher).creationCode
        );
        CcipRouteConfig memory route = _route(remoteSelector_, address(deployed));
        deployed.scheduleFactoryRoute(remoteChainId_, route);
        deployed.scheduleDispatcherDeploymentGasLimit(remoteChainId_, DISPATCHER_DEPLOY_GAS_LIMIT);
        vm.warp(block.timestamp + deployed.CONFIG_DELAY());
        deployed.executeFactoryRoute(remoteChainId_, route);
        deployed.executeDispatcherDeploymentGasLimit(remoteChainId_, DISPATCHER_DEPLOY_GAS_LIMIT);
        vm.deal(address(deployed), 1 ether);
        vm.etch(ACCEPTING_VERIFIER, type(CcipForkAcceptingVerifier).runtimeCode);
    }

    /// @dev Both factories, the Ethereum executor and its Arbitrum route. Leaves the Ethereum fork selected.
    function _deployStack() internal {
        _setUpForks();
        vm.selectFork(arbFork);
        CcipCrosschainFactory arbFactory = _deployFactory(ARBITRUM_ROUTER, ETHEREUM_CHAIN_ID, ETHEREUM_SELECTOR);
        vm.selectFork(ethFork);
        factory = _deployFactory(ETHEREUM_ROUTER, ARBITRUM_CHAIN_ID, ARBITRUM_SELECTOR);
        assertEq(address(factory), address(arbFactory), "factory at the same address on both forks");
        _createExecutor(ARBITRUM_CHAIN_ID, ARBITRUM_SELECTOR);
    }

    /// @dev The Ethereum executor with its route to `remoteChainId_`, on the selected (Ethereum) fork. Records the
    ///      executor slots this writes for `_warmExecutorStorage`.
    function _createExecutor(uint256 remoteChainId_, uint64 remoteSelector_) internal {
        vm.record();
        executor = CcipCrosschainExecutor(
            payable(factory.createExecutor(USER_SALT, ASSET_ID, address(this), _safety()))
        );
        factory.registerExecutorRoute(address(executor), remoteChainId_, _route(remoteSelector_, address(executor)));
        (, bytes32[] memory writes) = vm.accesses(address(executor));
        executorSetUpSlots = writes;
        vm.deal(address(executor), 1 ether);
        dispatcher = CcipCrosschainDispatcher(payable(address(executor)));
    }

    /// @dev Workaround for foundry-rs/foundry#16983 (forge 1.8.0-1.8.3, fixed by #16987, not yet in a stable release).
    ///      Once the dispatcher is created at the executor's address on the remote fork, forge marks that address
    ///      "created locally" on every fork for the rest of the test, so on Ethereum any executor slot not yet
    ///      loaded in the test's journal reads as zero. That drops everything `setUp` wrote, first of all the route
    ///      (`CcipUnknownChain` on the first executor send). Loading those slots on Ethereum before the dispatcher
    ///      exists keeps them in the journal. It is a no-op on forge versions without the bug. Remove it once CI runs
    ///      a forge release that contains the fix.
    function _warmExecutorStorage() internal {
        vm.selectFork(ethFork);
        uint256 length = executorSetUpSlots.length;
        for (uint256 i; i < length; ++i) {
            vm.load(address(executor), executorSetUpSlots[i]);
        }
    }

    /// @dev The route's `messageGasLimit`; suites that pin a smaller lane (e.g. the 3M removal suite) override it.
    function _routeGasLimit() internal view virtual returns (uint96) {
        return MESSAGE_GAS_LIMIT;
    }

    function _route(uint64 selector_, address peer_) internal view returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: FEE_TOKEN,
                messageGasLimit: _routeGasLimit(),
                tokenGasLimit: TOKEN_GAS_LIMIT,
                maxFee: MAX_FEE,
                enabled: true
            });
    }

    function _safety() internal view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: RESCUE_GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: BALANCE_APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    // =============================================================================================================
    // Capture: what the real OnRamp emitted
    // =============================================================================================================

    /// @dev Every `CCIPMessageSent` the selected fork's OnRamp for `destSelector_` emitted in `logs_`, decoded, with
    ///      the fee our application reported for the same message id (our `CcipMessageSent` event).
    function _captured(
        Vm.Log[] memory logs_,
        address router_,
        uint64 destSelector_
    ) internal view returns (CcipForkMessage[] memory out) {
        address onRamp = ICcipRouterFork(router_).getOnRamp(destSelector_);
        uint256 count;
        for (uint256 i; i < logs_.length; ++i) {
            if (_isOnRampSend(logs_[i], onRamp, destSelector_)) ++count;
        }
        out = new CcipForkMessage[](count);
        uint256 k;
        for (uint256 i; i < logs_.length; ++i) {
            if (!_isOnRampSend(logs_[i], onRamp, destSelector_)) continue;
            bytes memory encoded = _encodedMessageOf(logs_[i].data);
            CcipForkMessage memory m = encoded.read();
            assertEq(m.messageId, logs_[i].topics[3], "messageId == keccak256(encodedMessage)");
            m.appFee = _appFee(logs_, m.messageId);
            out[k++] = m;
        }
    }

    function _isOnRampSend(Vm.Log memory log_, address onRamp_, uint64 destSelector_) private pure returns (bool) {
        return log_.emitter == onRamp_ && log_.topics.length == 4 && log_.topics[1] == bytes32(uint256(destSelector_));
    }

    /// @dev `CCIPMessageSent` data = abi.encode(address feeToken, uint256 amount, bytes encodedMessage, Receipt[],
    ///      bytes[]); only the third field is read.
    function _encodedMessageOf(bytes memory data_) private pure returns (bytes memory encoded) {
        uint256 offset;
        assembly {
            offset := mload(add(data_, 96))
        }
        uint256 len;
        assembly {
            len := mload(add(add(data_, 32), offset))
        }
        encoded = new bytes(len);
        for (uint256 i; i < len; ++i) {
            encoded[i] = data_[offset + 32 + i];
        }
    }

    function _appFee(Vm.Log[] memory logs_, bytes32 messageId_) private pure returns (uint256) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics.length == 1 && logs_[i].topics[0] == APP_SENT_TOPIC) {
                (bytes32 id, , , uint256 fee) = abi.decode(logs_[i].data, (bytes32, uint256, bool, uint256));
                if (id == messageId_) return fee;
            }
        }
        return 0;
    }

    /// @dev Records logs, runs nothing: pair with `_sent` after the call that sends.
    function _startCapture() internal {
        vm.recordLogs();
    }

    function _sent(address router_, uint64 destSelector_) internal returns (CcipForkMessage[] memory) {
        return _captured(vm.getRecordedLogs(), router_, destSelector_);
    }

    function _single(CcipForkMessage[] memory ms_) internal pure returns (CcipForkMessage memory) {
        assertEq(ms_.length, 1, "exactly one CCIP message sent");
        return ms_[0];
    }

    function _type(CcipForkMessage memory m_) internal pure returns (CcipMsgType t) {
        (t, ) = CcipMessages.decode(m_.data);
    }

    // =============================================================================================================
    // Delivery on the destination fork (caller selects it)
    // =============================================================================================================

    /// @dev The real OffRamp 2.0 named in the message, checked against the destination router.
    function _offRampOf(CcipForkMessage memory m_, address destRouter_) internal view returns (ICcipOffRampV2) {
        assertTrue(ICcipRouterFork(destRouter_).isOffRamp(m_.sourceChainSelector, m_.offRamp), "offRamp registered");
        assertEq(ICcipOffRampV2(m_.offRamp).typeAndVersion(), OFFRAMP_V2, "OffRamp 2.0.0");
        return ICcipOffRampV2(m_.offRamp);
    }

    /// @dev Execute a data-only message on the REAL OffRamp 2.0 (`execute`), with only the CCV signature check
    ///      mocked. Returns the execution state the OffRamp recorded (2 = SUCCESS, 3 = FAILURE).
    function _executeOnOffRamp(
        CcipForkMessage memory m_,
        address destRouter_,
        uint32 gasLimitOverride_
    ) internal returns (uint8 state) {
        require(m_.tokenAmount == 0, "token messages use _routeViaRouter");
        ICcipOffRampV2 offRamp = _offRampOf(m_, destRouter_);
        (address[] memory ccvs, bytes[] memory results) = _mockCcvs(offRamp, m_.encoded);
        offRamp.execute(m_.encoded, ccvs, results, gasLimitOverride_);
        return offRamp.getExecutionState(m_.messageId);
    }

    function _mockCcvs(
        ICcipOffRampV2 offRamp_,
        bytes memory encoded_
    ) internal returns (address[] memory ccvs, bytes[] memory results) {
        (address[] memory required, address[] memory optional, uint8 threshold) = offRamp_.getCCVsForMessage(encoded_);
        ccvs = new address[](required.length + threshold);
        for (uint256 i; i < required.length; ++i) {
            ccvs[i] = required[i];
        }
        for (uint256 i; i < threshold; ++i) {
            ccvs[required.length + i] = optional[i];
        }
        results = new bytes[](ccvs.length);
        for (uint256 i; i < ccvs.length; ++i) {
            vm.mockCall(
                ccvs[i],
                abi.encodeWithSelector(ICcvResolverFork.getInboundImplementation.selector),
                abi.encode(ACCEPTING_VERIFIER)
            );
        }
    }

    /// @dev Route a message through the REAL destination Router exactly as the OffRamp does after verification
    ///      (`routeMessage` from a registered OffRamp, with the OffRamp's `gasForCallExactCheck`). For a token
    ///      message the released tokens are first dealt to the receiver, standing in for the pool's release.
    function _routeViaRouter(
        CcipForkMessage memory m_,
        address destRouter_,
        uint256 gasLimit_
    ) internal returns (bool success, bytes memory ret, uint256 gasUsed) {
        ICcipOffRampV2 offRamp = _offRampOf(m_, destRouter_);
        CcipClient.EVMTokenAmount[] memory amounts = new CcipClient.EVMTokenAmount[](m_.tokenAmount == 0 ? 0 : 1);
        if (m_.tokenAmount != 0) {
            deal(m_.destToken, m_.receiver, IERC20(m_.destToken).balanceOf(m_.receiver) + m_.tokenAmount);
            amounts[0] = CcipClient.EVMTokenAmount({token: m_.destToken, amount: m_.tokenAmount});
        }
        CcipClient.Any2EVMMessage memory message = CcipClient.Any2EVMMessage({
            messageId: m_.messageId,
            sourceChainSelector: m_.sourceChainSelector,
            sender: m_.sender,
            data: m_.data,
            destTokenAmounts: amounts
        });
        uint16 gasForCallExactCheck = offRamp.getStaticConfig().gasForCallExactCheck;
        vm.prank(address(offRamp));
        return ICcipRouterFork(destRouter_).routeMessage(message, gasForCallExactCheck, gasLimit_, m_.receiver);
    }

    // =============================================================================================================
    // Two-fork lifecycle, shared by the round-trip (real OffRamp) and gas (router gasUsed) suites
    // =============================================================================================================

    uint256 internal constant SEND_AMOUNT = 100e6; // 100 USDC
    uint256 internal constant DEPOSIT_AMOUNT = 60e6;
    uint256 internal constant RECALL_AMOUNT = 50e6;

    /// @dev Deliver one message on the (already selected) destination fork. Implemented per suite.
    function _deliver(CcipForkMessage memory m_, address destRouter_, string memory label_) internal virtual;

    /// @dev Deliver `m_` to the other fork and return what the receiver sent back through the real OnRamp there.
    function _deliverAndCollect(
        CcipForkMessage memory m_,
        string memory label_
    ) internal returns (CcipForkMessage[] memory responses) {
        bool toArbitrum = m_.destChainSelector == ARBITRUM_SELECTOR;
        vm.selectFork(toArbitrum ? arbFork : ethFork);
        address router = toArbitrum ? ARBITRUM_ROUTER : ETHEREUM_ROUTER;
        _startCapture();
        _deliver(m_, router, label_);
        responses = _sent(router, toArbitrum ? ETHEREUM_SELECTOR : ARBITRUM_SELECTOR);
    }

    /// @dev Deliver a message that must produce exactly one response of `expected_`, deliver that response back
    ///      and return it.
    function _roundTrip(
        CcipForkMessage memory m_,
        string memory label_,
        CcipMsgType expected_,
        string memory backLabel_
    ) internal returns (CcipForkMessage memory response) {
        response = _single(_deliverAndCollect(m_, label_));
        assertEq(uint8(_type(response)), uint8(expected_), "response type");
        _deliverAndCollect(response, backLabel_);
    }

    function _sendFromExecutor() internal returns (CcipForkMessage memory) {
        return _single(_sent(ETHEREUM_ROUTER, ARBITRUM_SELECTOR));
    }

    /// @dev Ethereum executor -> real OnRamp -> Arbitrum factory deploys the dispatcher -> DEPLOYMENT_ACK -> ready.
    function _lifecycleCreateDispatcher() internal {
        _warmExecutorStorage();
        address[] memory vaults = new address[](1);
        vaults[0] = ARBITRUM_FLUID_USDC;
        _startCapture();
        factory.requestDispatcher(address(executor), ARBITRUM_CHAIN_ID, vaults, MAX_FEE);
        CcipForkMessage memory create = _sendFromExecutor();
        assertEq(uint8(_type(create)), uint8(CcipMsgType.CREATE_DISPATCHER));
        assertEq(create.receiver, address(factory), "factory-to-factory");
        assertEq(create.ccipReceiveGasLimit, DISPATCHER_DEPLOY_GAS_LIMIT, "deployment gas limit carried");

        _roundTrip(
            create,
            "factory CREATE_DISPATCHER (CREATE3 deploy)",
            CcipMsgType.DEPLOYMENT_ACK,
            "factory DEPLOYMENT_ACK"
        );
        assertTrue(executor.isDispatcherReady(ARBITRUM_CHAIN_ID), "dispatcher ready on Ethereum");
        vm.selectFork(arbFork);
        assertTrue(address(dispatcher).code.length != 0, "dispatcher deployed at the executor address");
        assertTrue(dispatcher.isAllowedVault(ARBITRUM_FLUID_USDC), "initial allowlist applied");
        vm.deal(address(dispatcher), 1 ether); // native budget for its responses
    }

    /// @dev USDC through the real Ethereum OnRamp/pool -> dispatcher idle -> TRANSFER_SETTLED -> settled.
    function _lifecycleSendAsset() internal returns (uint256 delivered) {
        vm.selectFork(ethFork);
        deal(ETHEREUM_USDC, address(executor), SEND_AMOUNT);
        _startCapture();
        executor.sendAssetToDispatcher(ARBITRUM_CHAIN_ID, SEND_AMOUNT, MAX_FEE, FEE_TOKEN, TOKEN_GAS_LIMIT);
        CcipForkMessage memory out = _sendFromExecutor();
        assertEq(uint8(_type(out)), uint8(CcipMsgType.OUTBOUND_TRANSFER));
        assertEq(out.destToken, ARBITRUM_USDC, "real token pool maps to Arbitrum USDC");
        assertGt(out.tokenAmount, 0);
        assertLe(out.tokenAmount, SEND_AMOUNT);
        delivered = out.tokenAmount;

        _roundTrip(
            out,
            "dispatcher OUTBOUND_TRANSFER (token)",
            CcipMsgType.TRANSFER_SETTLED,
            "executor TRANSFER_SETTLED"
        );
        vm.selectFork(arbFork);
        assertEq(dispatcher.trackedIdle(), delivered, "dispatcher idle credited");
        vm.selectFork(ethFork);
        assertEq(executor.outboundInFlight(ARBITRUM_CHAIN_ID), 0, "outbound settled");
        assertEq(executor.settledRemoteBalance(ARBITRUM_CHAIN_ID), delivered, "settled credited");
    }

    function _command(uint8 action_, bytes memory actionData_) internal pure returns (Command memory) {
        return
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: action_,
                minExecutionGas: 0,
                actionData: actionData_
            });
    }

    /// @dev Send one business command and deliver it plus its receipt. Returns the command id.
    function _lifecycleCommand(
        uint8 action_,
        bytes memory actionData_,
        string memory label_,
        CcipMsgType expected_
    ) internal returns (bytes32 commandId) {
        vm.selectFork(ethFork);
        _startCapture();
        executor.sendCommandToDispatcher(
            ARBITRUM_CHAIN_ID,
            _command(action_, actionData_),
            MAX_FEE,
            FEE_TOKEN,
            MESSAGE_GAS_LIMIT
        );
        CcipForkMessage memory command = _sendFromExecutor();
        commandId = executor.activeCommand(ARBITRUM_CHAIN_ID);
        assertTrue(commandId != bytes32(0), "command active");
        _roundTrip(
            command,
            label_,
            expected_,
            expected_ == CcipMsgType.COMMAND_ACK ? "executor COMMAND_ACK" : "executor COMMAND_NACK"
        );
    }

    /// @dev The whole executor <-> dispatcher lifecycle over the real transports.
    function _runLifecycle() internal {
        _lifecycleCreateDispatcher();
        uint256 delivered = _lifecycleSendAsset();

        // UPDATE_VAULTS (sequenced config command) -> COMMAND_ACK.
        vm.selectFork(ethFork);
        address[] memory vaults = new address[](1);
        vaults[0] = ARBITRUM_FLUID_USDC;
        _startCapture();
        executor.updateVaults(ARBITRUM_CHAIN_ID, vaults, true, false, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        CcipForkMessage memory update = _sendFromExecutor();
        assertEq(uint8(_type(update)), uint8(CcipMsgType.UPDATE_VAULTS));
        _roundTrip(update, "dispatcher UPDATE_VAULTS", CcipMsgType.COMMAND_ACK, "executor COMMAND_ACK (config)");
        assertEq(executor.activeCommand(ARBITRUM_CHAIN_ID), bytes32(0), "config command resolved");

        // DEPOSIT into the real Fluid ERC-4626 -> COMMAND_ACK.
        bytes32 depositId = _lifecycleCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(ARBITRUM_FLUID_USDC, DEPOSIT_AMOUNT, 0),
            "dispatcher COMMAND (DEPOSIT into Fluid)",
            CcipMsgType.COMMAND_ACK
        );
        vm.selectFork(ethFork);
        assertEq(uint8(executor.commandStatus(depositId)), uint8(CommandStatus.SUCCEEDED), "deposit acknowledged");
        vm.selectFork(arbFork);
        assertGt(IERC20(ARBITRUM_FLUID_USDC).balanceOf(address(dispatcher)), 0, "fUSDC shares held");
        assertEq(dispatcher.trackedIdle(), delivered - DEPOSIT_AMOUNT, "idle debited by the deposit");

        // Failing command (vault not allowlisted) -> COMMAND_NACK, then CANCEL_COMMAND -> COMMAND_ACK (cancel).
        bytes32 badId = _lifecycleCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(ARBITRUM_USDC, 1e6, 0),
            "dispatcher COMMAND (failing -> NACK)",
            CcipMsgType.COMMAND_NACK
        );
        vm.selectFork(ethFork);
        assertEq(uint8(executor.commandStatus(badId)), uint8(CommandStatus.FAILED), "NACK applied");
        _startCapture();
        executor.cancelCommand(ARBITRUM_CHAIN_ID, badId, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        _roundTrip(
            _sendFromExecutor(),
            "dispatcher CANCEL_COMMAND",
            CcipMsgType.COMMAND_ACK,
            "executor COMMAND_ACK (cancel)"
        );
        assertEq(uint8(executor.commandStatus(badId)), uint8(CommandStatus.CANCELLED), "cancel acknowledged");

        // BALANCE_REQUEST -> BALANCE_REPORT: value-neutral (IL-8257). The dispatcher does not bump its state
        // version for it and the executor frontier does not move; the two stay equal because every earlier
        // version came from a value-moving response the executor applied.
        vm.selectFork(arbFork);
        uint64 versionBeforeRequest = dispatcher.stateVersion();
        vm.selectFork(ethFork);
        assertEq(executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID), versionBeforeRequest, "in sync before the report");
        _startCapture();
        executor.requestRemoteBalance(ARBITRUM_CHAIN_ID, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        _roundTrip(
            _sendFromExecutor(),
            "dispatcher BALANCE_REQUEST",
            CcipMsgType.BALANCE_REPORT,
            "executor BALANCE_REPORT"
        );
        vm.selectFork(arbFork);
        uint64 remoteVersion = dispatcher.stateVersion();
        vm.selectFork(ethFork);
        assertEq(remoteVersion, versionBeforeRequest, "the balance request bumped no state version");
        assertEq(
            executor.lastRemoteStateVersion(ARBITRUM_CHAIN_ID),
            remoteVersion,
            "frontier untouched, still in sync"
        );

        // Recall below the floor -> RETURN_REJECTED (BELOW_MINIMUM), slot reopened.
        _startCapture();
        executor.requestAssetsFromDispatcher(ARBITRUM_CHAIN_ID, 60e6, 50e6, MAX_FEE, FEE_TOKEN, MESSAGE_GAS_LIMIT);
        _roundTrip(
            _sendFromExecutor(),
            "dispatcher RETURN_REQUEST (rejected)",
            CcipMsgType.RETURN_REJECTED,
            "executor RETURN_REJECTED"
        );
        assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "rejection reopens the recall slot");

        // REDEEM the Fluid position -> COMMAND_ACK.
        vm.selectFork(arbFork);
        uint256 shares = IERC20(ARBITRUM_FLUID_USDC).balanceOf(address(dispatcher));
        _lifecycleCommand(
            uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(ARBITRUM_FLUID_USDC, shares, 0),
            "dispatcher COMMAND (REDEEM from Fluid)",
            CcipMsgType.COMMAND_ACK
        );
        vm.selectFork(arbFork);
        assertEq(IERC20(ARBITRUM_FLUID_USDC).balanceOf(address(dispatcher)), 0, "position redeemed");

        // Recall -> RETURN_TRANSFER with USDC through the real Arbitrum OnRamp/pool -> claim on Ethereum.
        vm.selectFork(ethFork);
        _startCapture();
        executor.requestAssetsFromDispatcher(
            ARBITRUM_CHAIN_ID,
            RECALL_AMOUNT,
            0,
            MAX_FEE,
            FEE_TOKEN,
            MESSAGE_GAS_LIMIT
        );
        CcipForkMessage memory back = _single(_deliverAndCollect(_sendFromExecutor(), "dispatcher RETURN_REQUEST"));
        assertEq(uint8(_type(back)), uint8(CcipMsgType.RETURN_TRANSFER));
        assertEq(back.destToken, ETHEREUM_USDC, "real token pool maps back to Ethereum USDC");
        assertEq(back.ccipReceiveGasLimit, TOKEN_GAS_LIMIT, "token responses carry tokenGasLimit");
        _deliverAndCollect(back, "executor RETURN_TRANSFER (token)");
        vm.selectFork(ethFork);
        assertEq(executor.activeReturn(ARBITRUM_CHAIN_ID), bytes32(0), "recall finalized");
        assertEq(executor.idleLedger(), back.tokenAmount, "returned tokens credited to idle");
        uint256 before = IERC20(ETHEREUM_USDC).balanceOf(address(this));
        executor.claimAsset(type(uint256).max);
        assertEq(IERC20(ETHEREUM_USDC).balanceOf(address(this)) - before, back.tokenAmount, "claimed home");
    }
}
