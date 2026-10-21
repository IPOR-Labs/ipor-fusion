// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Minimal ABI-compatible subset of Chainlink CCIP Client v1.6.1.
library CcipClient {
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    struct Any2EVMMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        bytes sender;
        bytes data;
        EVMTokenAmount[] destTokenAmounts;
    }

    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    bytes4 internal constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

    struct GenericExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
    }

    function argsToBytes(GenericExtraArgsV2 memory extraArgs_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(GENERIC_EXTRA_ARGS_V2_TAG, extraArgs_);
    }
}

interface ICcipRouterClient {
    function isChainSupported(uint64 destinationChainSelector_) external view returns (bool);
    function getFee(uint64 destinationChainSelector_, CcipClient.EVM2AnyMessage memory message_)
        external
        view
        returns (uint256);
    function ccipSend(uint64 destinationChainSelector_, CcipClient.EVM2AnyMessage calldata message_)
        external
        payable
        returns (bytes32);
}

interface ICcipMessageReceiver {
    function ccipReceive(CcipClient.Any2EVMMessage calldata message_) external;
}
