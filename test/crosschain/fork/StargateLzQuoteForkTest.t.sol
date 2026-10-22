// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// The fork suites print gas-budget and fee-quote reports for operators, so console output is intended here.
/* solhint-disable no-console */

import {console2} from "forge-std/console2.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {
    MessagingParams,
    MessagingFee
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ExecutorOptions} from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/ExecutorOptions.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {CrosschainErrors} from "../../../contracts/crosschain/lib/CrosschainErrors.sol";
import {
    StargateExecutorDeploymentLib
} from "../../../contracts/crosschain/stargate/lib/StargateExecutorDeploymentLib.sol";
import {StargateForkBase} from "./StargateForkBase.sol";

/// @title StargateLzQuoteForkTest
/// @notice The command-lane option shapes of IL-8296 / IL-8442 against the REAL EndpointV2 send library and
///         executor fee library, plus real Stargate pool quotes (IL-8452). Justifies, on the deployed transport,
///         why `registerChain` accepts only the exact lzReceive-only blob: the malformed native drop, a native
///         value above the executor's cap and unpayable gas all make the real quote revert, and since paths are
///         append-only every later send on that path would revert the same way.
contract StargateLzQuoteForkTest is StargateForkBase {
    using OptionsBuilder for bytes;

    uint128 internal constant COMMAND_LANE_MAX_RECEIVE_GAS = 10_000_000;
    /// @dev Raised by the deployed LayerZero executor when a native value or drop exceeds its per-path cap.
    bytes4 internal constant EXECUTOR_NATIVE_AMOUNT_EXCEEDS_CAP =
        bytes4(keccak256("Executor_NativeAmountExceedsCap(uint256,uint256)"));

    uint256 internal baseFork;

    function setUp() public {
        _createForks();
        baseFork = vm.createFork(vm.envString("BASE_PROVIDER_URL"), BASE_FORK_BLOCK);
        vm.selectFork(baseFork);
        vm.warp(COMMON_TIMESTAMP);
        _deployApps();
        vm.selectFork(ethereumFork);
    }

    function testForkRealQuoteAcceptsTheRegisteredBlobAcrossTheGasBounds() public {
        uint128[3] memory gases = [StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS, COMMAND_LANE_GAS, COMMAND_LANE_MAX_RECEIVE_GAS];
        uint32[2] memory dstEids = [ARBITRUM_EID, BASE_EID];
        for (uint256 d; d < dstEids.length; ++d) {
            for (uint256 g; g < gases.length; ++g) {
                MessagingFee memory fee =
                    _quote(dstEids[d], OptionsBuilder.newOptions().addExecutorLzReceiveOption(gases[g], 0));
                assertGt(fee.nativeFee, 0, "real quote succeeds");
                console2.log("QUOTE | Ethereum -> eid, lzReceive gas, native fee:", dstEids[d], gases[g], fee.nativeFee);
            }
        }
    }

    /// @notice The IL-8442 PoC blob: a valid lzReceive followed by a native drop with a 16-byte payload.
    function testForkRealQuoteRevertsOnMalformedNativeDropAndRegistrationRefusesIt() public {
        bytes memory blob = abi.encodePacked(
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(COMMAND_LANE_GAS, 0),
            abi.encodePacked(hex"01", uint16(17), hex"02", bytes16(0))
        );

        vm.expectRevert(ExecutorOptions.Executor_InvalidNativeDropOption.selector);
        this.quote(ARBITRUM_EID, blob);

        _expectRegistrationRefused(blob);
    }

    /// @notice An lzReceive value above the destination executor's native cap: the real quote reverts.
    function testForkRealQuoteRevertsOnNativeValueAboveExecutorCapAndRegistrationRefusesIt() public {
        bytes memory blob = OptionsBuilder.newOptions().addExecutorLzReceiveOption(COMMAND_LANE_GAS, 1e30);

        _assertQuoteReverts(blob, "value above cap");

        _expectRegistrationRefused(blob);
    }

    /// @notice A well-formed native drop above the destination executor's native cap: the real quote reverts.
    function testForkRealQuoteRevertsOnNativeDropAboveExecutorCapAndRegistrationRefusesIt() public {
        bytes memory blob = OptionsBuilder.newOptions().addExecutorLzReceiveOption(COMMAND_LANE_GAS, 0)
            .addExecutorNativeDropOption(1e30, bytes32(uint256(uint160(APP))));

        _assertQuoteReverts(blob, "native drop above cap");

        _expectRegistrationRefused(blob);
    }

    /// @notice Unpayable gas (2^100): the real quote prices the message beyond any native budget.
    function testForkRealQuoteRejectsUnpayableGasAndRegistrationRefusesIt() public {
        bytes memory blob = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(1) << 100, 0);

        // The deployed executor fee library prices it instead of reverting: the fee is far beyond any native
        // budget the app holds, so every send on the path would revert `InsufficientNativeBudget`.
        MessagingFee memory fee = _quote(ARBITRUM_EID, blob);
        console2.log("QUOTE | unpayable gas 2^100 | native fee:", fee.nativeFee);
        assertGt(fee.nativeFee, 1e24, "priced beyond any native budget");

        _expectRegistrationRefused(blob);
    }

    /// @notice The real pools take a fee on the amount on every route used here, which is why a recall floor
    ///         at the requested amount must be rejected cleanly before `sendToken` (IL-8452).
    function testForkRealStargatePoolsChargeAFeeOnTheAmount() public {
        _assertFeeOnAmount(ethereumFork, ETHEREUM_STARGATE_USDC, ARBITRUM_EID, "Ethereum -> Arbitrum");
        _assertFeeOnAmount(ethereumFork, ETHEREUM_STARGATE_USDC, BASE_EID, "Ethereum -> Base");
        _assertFeeOnAmount(arbitrumFork, ARBITRUM_STARGATE_USDC, ETHEREUM_EID, "Arbitrum -> Ethereum");
        _assertFeeOnAmount(baseFork, BASE_STARGATE_USDC, ETHEREUM_EID, "Base -> Ethereum");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev External so `vm.expectRevert` / `try` can target the endpoint call.
    function quote(uint32 dstEid_, bytes memory options_) external view returns (MessagingFee memory) {
        return _quote(dstEid_, options_);
    }

    /// @dev The real endpoint quote, as `APP` (the executor) would send a 160-byte command envelope.
    function _quote(uint32 dstEid_, bytes memory options_) internal view returns (MessagingFee memory) {
        return ENDPOINT.quote(
            MessagingParams({
                dstEid: dstEid_,
                receiver: bytes32(uint256(uint160(APP))),
                message: new bytes(160),
                options: options_,
                payInLzToken: false
            }),
            APP
        );
    }

    /// @dev Asserts the real quote reverts with the deployed executor's `Executor_NativeAmountExceedsCap`.
    function _assertQuoteReverts(bytes memory blob_, string memory label_) internal view {
        try this.quote(ARBITRUM_EID, blob_) returns (MessagingFee memory fee) {
            console2.log("QUOTE | unexpected fee:", fee.nativeFee);
            revert(string.concat("real quote accepted: ", label_));
        } catch (bytes memory reason) {
            // casting to 'bytes4' is safe because only the error selector is compared
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(bytes4(reason), EXECUTOR_NATIVE_AMOUNT_EXCEEDS_CAP, string.concat("real revert: ", label_));
        }
    }

    function _expectRegistrationRefused(bytes memory blob_) internal {
        vm.selectFork(ethereumFork);
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
        params[0] = EnforcedOptionParam({eid: ARBITRUM_EID, msgType: 1, options: blob_});
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, ARBITRUM_EID));
        executor.registerChain(ARBITRUM_CHAIN_ID, ARBITRUM_EID, abi.encode(params));
    }

    function _assertFeeOnAmount(uint256 fork_, address pool_, uint32 dstEid_, string memory label_) internal {
        vm.selectFork(fork_);
        uint256 amount = 10_000e6;
        SendParam memory sendParam = SendParam({
            dstEid: dstEid_,
            to: bytes32(uint256(uint160(APP))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: _assetSendOptions(),
            composeMsg: new bytes(64),
            oftCmd: ""
        });
        (,, OFTReceipt memory receipt) = IStargate(pool_).quoteOFT(sendParam);
        MessagingFee memory fee = IStargate(pool_).quoteSend(sendParam, false);
        console2.log(
            string.concat("POOL | ", label_, " | 10,000 USDC credited, native fee:"),
            receipt.amountReceivedLD,
            fee.nativeFee
        );
        assertLt(receipt.amountReceivedLD, amount, string.concat("fee on amount: ", label_));
        assertGt(fee.nativeFee, 0);
    }
}
