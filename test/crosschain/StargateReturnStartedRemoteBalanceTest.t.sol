// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {Observation} from "../../contracts/crosschain/interfaces/ICrosschainDispatcher.sol";
import {MsgType, BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer,
    ReturnAssetsRequest,
    ReturnStarted
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockFaultyVault} from "./mocks/MockFaultyVault.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateReturnStartedRemoteBalanceTest
/// @notice IL-8606 / TP-M-28: the Stargate dispatcher reports its post-debit balance (tracked idle plus every
///         priced tracked vault) in `ReturnStarted.remoteBalanceSD`, which the executor uses as the residual
///         anchor after a full recall.
contract StargateReturnStartedRemoteBalanceTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockRemoteVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vault = new MockRemoteVault(IERC20(address(usdc)), "Vault", "VLT");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID, msgType: 1, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0)
                .addExecutorLzComposeOption(0, 1_500_000, 0)
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    function _deliver(bytes memory envelope_) internal {
        bytes32 peer = bytes32(uint256(uint160(address(dispatcher))));
        endpoint.deliverLz(address(dispatcher), EXECUTOR_EID, peer, GUID, envelope_);
    }

    function _compose(bytes32 transferId_, uint256 amountLD_) internal {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, amountLD_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _returnRequest(bytes32 requestId_, uint256 amountSD_) internal {
        _deliver(
            CrosschainMessages.encodeReturnAssetsRequest(
                ReturnAssetsRequest({
                    requestId: requestId_, amountSD: amountSD_, maxAccountedSD: amountSD_, minReturnSD: 0
                })
            )
        );
    }

    function _lastReturnStarted() internal view returns (ReturnStarted memory) {
        (uint8 version, uint8 rawType, bytes memory data) = abi.decode(endpoint.lastMessage(), (uint8, uint8, bytes));
        version;
        assertEq(rawType, uint8(MsgType.RETURN_STARTED), "last message is RETURN_STARTED");
        return CrosschainMessages.decodeReturnStarted(data);
    }

    function testReturnStartedShouldReportThePostDebitIdle() public {
        _compose(keccak256("t1"), 100e6);
        _returnRequest(keccak256("r1"), 40e6);

        ReturnStarted memory rs = _lastReturnStarted();
        assertEq(dispatcher.trackedIdle(), 60e6);
        assertEq(rs.remoteBalanceSD, 60e6, "post-debit idle reported");
    }

    function testReturnStartedShouldReportPricedVaultPositionsAfterAFullRecall() public {
        _compose(keccak256("t1"), 100e6);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({commandId: keccak256("uv"), sequence: 0, newConfigEpoch: 1, minExecutionGas: DEFAULT_COMMAND_BUDGET, vaults: vaults})
            )
        );
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep"),
                    sequence: 1,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
                })
            )
        );
        usdc.mint(address(vault), 10e6); // the position earns yield after the deposit

        _returnRequest(keccak256("r1"), 50e6); // drains the whole tracked idle

        assertEq(dispatcher.trackedIdle(), 0, "full recall of the idle");
        Observation memory o = dispatcher.observation();
        assertTrue(o.vaultValued[0], "position is priced");
        assertGt(o.vaultAssetValues[0], 50e6, "yield is visible in the position value");
        ReturnStarted memory rs = _lastReturnStarted();
        assertEq(rs.remoteBalanceSD, o.vaultAssetValues[0], "the residual reported is the priced position");
    }

    /// @dev B1: a tracked vault whose `convertToAssets` returns type(uint256).max must not overflow the reported
    ///      balance and panic the recall; the absurd value counts as zero and the recall still delivers.
    function testReturnStartedShouldExcludeAVaultPricedAboveUint128Max() public {
        MockFaultyVault faulty = new MockFaultyVault(IERC20(address(usdc)), "Faulty", "FLT");
        _compose(keccak256("t1"), 100e6);
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault);
        vaults[1] = address(faulty);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({commandId: keccak256("uv"), sequence: 0, newConfigEpoch: 1, minExecutionGas: DEFAULT_COMMAND_BUDGET, vaults: vaults})
            )
        );
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep"),
                    sequence: 1,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
                })
            )
        );
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep2"),
                    sequence: 2,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(address(faulty), 20e6, 0)
                })
            )
        );
        faulty.setConvertReturnsMax(true);

        _returnRequest(keccak256("r1"), 30e6); // drains the whole tracked idle; must not panic

        ReturnStarted memory rs = _lastReturnStarted();
        Observation memory o = dispatcher.observation();
        assertTrue(o.vaultValued[0], "healthy vault priced");
        assertEq(rs.remoteBalanceSD, o.vaultAssetValues[0], "the absurd vault is excluded from the reported balance");
    }
}
