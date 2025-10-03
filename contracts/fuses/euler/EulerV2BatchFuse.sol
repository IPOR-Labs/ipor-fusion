// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IFuseCommon} from "../IFuseCommon.sol";

struct EulerV2BatchItem {
    address targetContract;
    address onBehalfOfAccount;
    bytes data;
}

struct EulerV2BatchFuseData {
    EulerV2BatchItem[] batchItems;
    address[] assetsForApprovals;
}

contract EulerV2BatchFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Supply Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Supply Fuse
    function enter(EulerV2BatchFuseData memory data_) external {
        IEVC.BatchItem[] memory batchItems = new IEVC.BatchItem[](data_.batchItems.length);

        for (uint256 i = 0; i < data_.assetsForApprovals.length; i++) {
            ERC20(data_.assetsForApprovals[i]).forceApprove(
                address(0xe0a80d35bB6618CBA260120b279d357978c42BCE),
                type(uint256).max
            );
        }

        for (uint256 i = 0; i < data_.batchItems.length; i++) {
            // todo add validation
            batchItems[i] = IEVC.BatchItem(
                data_.batchItems[i].targetContract,
                data_.batchItems[i].onBehalfOfAccount,
                0,
                data_.batchItems[i].data
            );
        }

        EVC.batch(batchItems);
    }

    function exit() external {
        // TODO: Implement exit functionality
        revert("Exit not implemented");
    }
}
