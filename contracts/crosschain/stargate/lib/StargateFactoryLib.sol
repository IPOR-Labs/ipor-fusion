// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";

/// @dev Runtime-only data container used to keep large creation code out of
/// expensive contract storage. The leading STOP byte makes it non-callable.
contract CrosschainCreationCodeStore {
    constructor(bytes memory data_) {
        bytes memory runtime = abi.encodePacked(hex"00", data_);
        assembly ("memory-safe") {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

/// @title StargateFactoryLib
/// @notice Cold owner-path helpers of `StargateCrosschainFactory`, linked for EIP-170 headroom.
/// @dev External linked library run through delegatecall on the factory's own storage, so `address(this)` is
///      the factory and every CREATE below comes from it. Its errors are mirrored in `IStargateFactoryLibraryAbi`.
/// @author IPOR Labs
library StargateFactoryLib {
    uint256 private constant _CODE_CHUNK_SIZE = 20_000;

    /// @dev Split `creationCode_` over at most two data stores (CREATE from the factory, so the store
    ///      addresses follow the factory nonce exactly as before).
    function writeCreationCode(bytes calldata creationCode_, address[2] storage stores_) public {
        if (creationCode_.length > _CODE_CHUNK_SIZE * 2) revert CrosschainErrors.CreationCodeTooLarge();
        uint256 firstLength = creationCode_.length > _CODE_CHUNK_SIZE ? _CODE_CHUNK_SIZE : creationCode_.length;
        stores_[0] = address(new CrosschainCreationCodeStore(creationCode_[:firstLength]));
        if (creationCode_.length > firstLength) {
            stores_[1] = address(new CrosschainCreationCodeStore(creationCode_[firstLength:]));
        }
    }

    /// @dev Token/pool relationship check of `scheduleAssetConfig` / `executeAssetConfig`.
    function validateAssetConfig(address token_, address pool_) public view {
        if (token_ == address(0) || pool_ == address(0)) revert CrosschainErrors.ZeroAddress();
        if (token_.code.length == 0) revert CrosschainErrors.NotAContract(token_);
        if (pool_.code.length == 0) revert CrosschainErrors.NotAContract(pool_);

        address poolToken = IStargate(pool_).token();
        if (poolToken != token_) revert CrosschainErrors.StargatePoolAssetMismatch(token_, poolToken);

        uint8 localDec = IERC20Metadata(token_).decimals();
        uint8 sharedDec = IStargate(pool_).sharedDecimals();
        if (localDec < sharedDec) revert CrosschainErrors.InvalidDecimals(localDec, sharedDec);
    }
}
