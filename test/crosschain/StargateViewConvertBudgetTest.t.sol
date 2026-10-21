// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {Observation} from "../../contracts/crosschain/interfaces/ICrosschainDispatcher.sol";
import {BusinessAction, MsgType} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
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
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {HeavyHonestVault} from "./CcipViewConvertBudgetTest.t.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateViewConvertBudgetTest
/// @notice IL-8602 review G-1, Stargate side: `observation()` gives `convertToAssets` the view budget; the recall's
///         `remoteBalanceSD` keeps the 200k on-chain budget.
contract StargateViewConvertBudgetTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    uint256 internal constant RESCUE_DELAY = 3 days;
    bytes32 internal constant GUID = keccak256("guid");

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    HeavyHonestVault internal heavy;
    MockRemoteVault internal plain;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        heavy = new HeavyHonestVault(IERC20(address(usdc)), 200);
        plain = new MockRemoteVault(IERC20(address(usdc)), "P", "P");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
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
            address(usdc),
            address(pool),
            keccak256("USDC"),
            address(0xF),
            address(0xADADAD),
            address(0x6A6A6A),
            RESCUE_DELAY,
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);

        address[] memory vaults = new address[](2);
        vaults[0] = address(heavy);
        vaults[1] = address(plain);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("uv"),
                    sequence: 0,
                    newConfigEpoch: 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults
                })
            )
        );
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("depH"), 1, address(heavy), 50e6);
        _deposit(keccak256("depP"), 2, address(plain), 30e6);
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

    function _deposit(bytes32 id_, uint64 seq_, address vault_, uint256 amountSD_) internal {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id_,
                    sequence: seq_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(vault_, amountSD_, 0)
                })
            )
        );
    }

    function _compose(bytes32 transferId_, uint256 amountLD_) internal {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, amountLD_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    /// @notice The attestation view prices the heavy honest vault (about 0.43M cold).
    function testShouldPriceAHeavyHonestVaultInStargateObservation() public {
        vm.cool(address(heavy));
        Observation memory obs = dispatcher.observation();
        assertEq(obs.unpricedCount, 0, "nothing unpriced");
        assertTrue(obs.vaultValued[0], "heavy priced");
        assertEq(obs.vaultAssetValues[0], 50e6, "heavy value");
        assertEq(obs.vaultAssetValues[1], 30e6, "plain value");
    }

    /// @notice The recall keeps the on-chain budget: its `remoteBalanceSD` still omits the heavy vault (the
    ///         residual-anchor caveat in the README).
    function testShouldKeepTheOnChainBudgetForTheStargateRecall() public {
        vm.cool(address(heavy));
        _deliver(
            CrosschainMessages.encodeReturnAssetsRequest(
                ReturnAssetsRequest({requestId: keccak256("r1"), amountSD: 20e6, maxAccountedSD: 20e6, minReturnSD: 0})
            )
        );
        (, uint8 rawType, bytes memory data) = abi.decode(endpoint.lastMessage(), (uint8, uint8, bytes));
        assertEq(rawType, uint8(MsgType.RETURN_STARTED), "RETURN_STARTED");
        ReturnStarted memory rs = CrosschainMessages.decodeReturnStarted(data);
        assertEq(rs.remoteBalanceSD, 30e6, "the recall counts only the plain vault (heavy above 200k on-chain)");
    }
}
