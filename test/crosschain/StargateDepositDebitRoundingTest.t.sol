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
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockOverReportingVault} from "./mocks/MockOverReportingVault.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @notice Non-conforming ERC-4626 that pulls `SHORTFALL` wei less than the `assets` it is asked to deposit.
contract ShortPullingVault is MockRemoteVault {
    uint256 internal constant SHORTFALL = 1;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "Short", "SHORT") {}

    function deposit(uint256 assets_, address receiver_) public override returns (uint256 shares) {
        uint256 pulled = assets_ - SHORTFALL;
        shares = previewDeposit(pulled);
        _deposit(_msgSender(), receiver_, pulled, shares);
    }
}

/// @title StargateDepositDebitRoundingTest
/// @notice IL-8446: the Stargate dispatcher DEPOSIT debit against `trackedIdle` rounds the measured spend UP,
///         like the CCIP dispatcher. The difference only shows when LOCAL decimals exceed SHARED decimals and the
///         vault pulls an amount that is not a whole shared-decimal unit, so this suite runs an 18-decimal asset
///         (6 shared decimals, conversion rate 1e12) against a vault that pulls 1 wei less than requested.
/// @dev Dispatcher is deployed from its artifact (`deployCode`), as in `DispatcherTest`.
contract StargateDepositDebitRoundingTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("WETH");
    bytes32 internal constant GUID = keccak256("guid");
    uint256 internal constant CONVERSION_RATE = 1e12;

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal token;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        token = new MockERC20("Wrapped Ether", "WETH", 18);
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
            ASSET_ID,
            address(0xF),
            address(0xADADAD),
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

    function testShouldRoundDepositDebitUpWhenVaultPullsPartialSharedUnit() public {
        ShortPullingVault vault = new ShortPullingVault(IERC20(address(token)));
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e18); // trackedIdle = 100e6 SD

        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // asks for 50e18, vault pulls 50e18 - 1

        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(token.balanceOf(address(dispatcher)), 50e18 + 1, "vault pulled 1 wei less than requested");
        // Floor would debit 49_999_999 SD and leave 50_000_001 SD (50.000001e18 LD) against 50e18 + 1 held.
        assertEq(dispatcher.trackedIdle(), 50e6, "debit rounded up to a whole shared unit");
        assertEq(
            token.allowance(address(dispatcher), address(vault)),
            0,
            "unused vault allowance reset after partial pull"
        );
        assertLe(
            dispatcher.trackedIdle() * CONVERSION_RATE,
            token.balanceOf(address(dispatcher)),
            "trackedIdle never claims more than the dispatcher holds"
        );
    }

    function testShouldDebitExactSpendWhenVaultPullsWholeSharedUnits() public {
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "Vault", "VLT");
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e18);

        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0);

        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(dispatcher.trackedIdle(), 50e6, "a conforming vault is debited exactly");
        assertEq(token.balanceOf(address(dispatcher)), 50e18);
    }

    /// @notice IL-8601: the shared helper returns the measured share delta; minShares is enforced against it
    ///         and a vault that over-reports its return value cannot satisfy it.
    function testShouldEnforceMinSharesAgainstMeasuredDelta() public {
        MockOverReportingVault liar = new MockOverReportingVault(IERC20(address(token)), 50, 2);
        _allowVault(address(liar));
        _compose(keccak256("t1"), 100e18);

        // Mints 25e18 shares, reports 100e18. minShares 30e18 > measured 25e18 -> FAILED.
        _deposit(keccak256("dep1"), 1, address(liar), 50e6, 30e18);
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep1"))), uint8(CommandStatus.FAILED));
        assertEq(dispatcher.trackedIdle(), 100e6, "failed deposit leaves the ledger untouched");

        // minShares equal to the measured delta passes.
        _deposit(keccak256("dep2"), 1, address(liar), 50e6, 25e18);
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep2"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(IERC20(address(liar)).balanceOf(address(dispatcher)), 25e18);
        assertEq(dispatcher.trackedIdle(), 50e6);
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher), EXECUTOR_EID, bytes32(uint256(uint160(address(dispatcher)))), GUID, envelope_
        );
    }

    function _allowVault(address vault_) internal {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({commandId: keccak256("uv"), sequence: 0, newConfigEpoch: 1, minExecutionGas: DEFAULT_COMMAND_BUDGET, vaults: vaults})
            )
        );
    }

    function _deposit(bytes32 commandId_, uint64 sequence_, address vault_, uint256 amountSD_, uint256 minShares_)
        internal
    {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: commandId_,
                    sequence: sequence_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(vault_, amountSD_, minShares_)
                })
            )
        );
    }

    /// @notice Simulate an inbound Stargate credit: mint the physical tokens then deliver the compose.
    function _compose(bytes32 transferId_, uint256 amountLD_) internal {
        token.mint(address(dispatcher), amountLD_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, amountLD_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }
}
