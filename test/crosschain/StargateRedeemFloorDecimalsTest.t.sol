// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemoteVault, MockWithdrawManager, MockRemotePlasmaVault} from "./mocks/MockRemoteVault.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateRedeemFloorDecimalsTest
/// @notice IL-8609: on a route with more local than shared decimals (18 / 6) the REDEEM and REDEEM_FROM_REQUEST
///         `minAssets` floor travels in SHARED decimals and must be converted to local decimals before it is
///         compared with the measured receipt. Pre-fix the raw SD floor was compared with LD receipts, which
///         weakened it by 10^12.
contract StargateRedeemFloorDecimalsTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant GUID = keccak256("guid");

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal token;
    StargateCrosschainDispatcher internal dispatcher;
    address internal admin = address(0xADADAD);

    function setUp() public {
        vm.chainId(42161);
        vm.warp(365 days);
        token = new MockERC20("Token18", "T18", 18);
        pool = new MockStargatePool(address(token), 6);
        endpoint = new MockLzEndpoint();

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
            address(token),
            address(pool),
            keccak256("T18"),
            address(0xF),
            admin,
            address(0x6A6A6A),
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

    function testShouldNackRedeemBelowConvertedFloor() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault), 50e6);
        // The vault loses 1 wei: redeeming everything now pays 50e18 - 1, one wei below the 50e6 SD floor (= 50e18).
        vm.prank(address(vault));
        token.transfer(address(0xdead), 1);

        _command(
            keccak256("red"), 2, uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(vault), 50e18, 50e6)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("red"))), uint8(CommandStatus.FAILED), "below floor NACKed");
        assertEq(vault.balanceOf(address(dispatcher)), 50e18, "shares untouched");
    }

    function testShouldRedeemAtConvertedFloor() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "V", "V");
        _fundAndDeposit(address(vault), 50e6);
        _command(
            keccak256("red"), 2, uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(vault), 50e18, 50e6)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("red"))), uint8(CommandStatus.SUCCEEDED), "at floor");
        assertEq(dispatcher.trackedIdle(), 100e6, "idle back to 100 SD");
    }

    function testShouldNackRedeemFromRequestBelowConvertedFloor() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv), 50e6);
        _request(wm, rv, 50e18);
        vm.prank(address(rv));
        token.transfer(address(0xdead), 1);

        _command(
            keccak256("rfr"), 3, uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 50e18, 50e6, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("rfr"))), uint8(CommandStatus.FAILED), "below floor NACKed");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 50e18, "request untouched");
    }

    function testShouldRedeemFromRequestAtConvertedFloor() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _fundAndDeposit(address(rv), 50e6);
        _request(wm, rv, 50e18);

        _command(
            keccak256("rfr"), 3, uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 50e18, 50e6, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("rfr"))), uint8(CommandStatus.SUCCEEDED), "at floor");
        assertEq(dispatcher.trackedIdle(), 100e6, "idle back to 100 SD");
    }

    // ------------------------------------------------------------------ helpers

    function _mockWm() private returns (MockWithdrawManager wm, MockRemotePlasmaVault rv) {
        rv = new MockRemotePlasmaVault(IERC20(address(token)), "Mock WM Vault", "MWVLT");
        wm = new MockWithdrawManager(address(rv));
        rv.setWithdrawManager(address(wm));
    }

    function _request(MockWithdrawManager wm, MockRemotePlasmaVault rv, uint256 shares_) private {
        _command(
            keccak256("req"), 2, uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), shares_, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.SUCCEEDED), "request ok");
    }

    /// @dev Credits 100 SD (100e18 LD) of idle, allowlists `vault_` and deposits `depositSD_` of it (sequence 1).
    function _fundAndDeposit(address vault_, uint256 depositSD_) private {
        token.mint(address(dispatcher), 100e18);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: keccak256("t")}));
        endpoint.deliverCompose(
            address(dispatcher),
            address(pool),
            GUID,
            LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, 100e18, envelope)
        );
        assertEq(dispatcher.trackedIdle(), 100e6, "idle in shared decimals");

        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({commandId: keccak256("uv"), sequence: 0, newConfigEpoch: 1, minExecutionGas: DEFAULT_COMMAND_BUDGET, vaults: vaults})
            )
        );
        _command(
            keccak256("dep"), 1, uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(vault_, depositSD_, 0)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.SUCCEEDED), "deposit ok");
        assertEq(IERC20(vault_).balanceOf(address(dispatcher)), 50e18, "50e18 shares");
    }

    function _command(bytes32 id_, uint64 seq_, uint8 action_, bytes memory data_) private {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id_,
                    sequence: seq_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: action_,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: data_
                })
            )
        );
    }

    function _deliver(bytes memory envelope_) private {
        endpoint.deliverLz(
            address(dispatcher), EXECUTOR_EID, bytes32(uint256(uint160(address(dispatcher)))), GUID, envelope_
        );
    }
}
