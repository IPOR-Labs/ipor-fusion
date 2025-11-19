// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IPrincipalToken} from "./ext/IPrincipalToken.sol";

import {NapierUniversalRouterFuse} from "./NapierUniversalRouterFuse.sol";

/// @notice Data for entering (collect interest) to the Napier V2 protocol
/// @param principalToken Principal Token address to collect from
struct NapierCollectFuseEnterData {
    IPrincipalToken principalToken;
}

/// @title NapierCollectFuse
/// @notice Fuse for collecting interest and external rewards from Napier V2 Yield Tokens
/// @dev Substrates in this fuse are the Napier V2 Principal Tokens
contract NapierCollectFuse is NapierUniversalRouterFuse {
    /// @notice Emitted when collecting interest and external rewards from Napier V2 Yield Tokens
    /// @param version Address of this contract version
    /// @param principalToken Address of the Napier V2 Principal Token
    /// @param collectedAmount Amount of interest and external rewards collected from the vault
    /// @param rewards Amount of external rewards collected from the vault
    event NapierCollectFuseEnter(
        address version,
        address principalToken,
        uint256 collectedAmount,
        IPrincipalToken.TokenReward[] rewards
    );

    constructor(uint256 marketId_) {
        VERSION = address(this);
        if (marketId_ == 0) revert NapierFuseIInvalidMarketId();

        MARKET_ID = marketId_;
    }

    /// @notice Collects interest and external rewards if any
    function enter(NapierCollectFuseEnterData calldata data_) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(data_.principalToken))) {
            revert NapierFuseIInvalidMarketId();
        }

        // Collect interest (in units of the underlying token) and external rewards if any
        // If the market haven't had any YTs since the last collect, the interest is 0
        (uint256 collected, IPrincipalToken.TokenReward[] memory rewards) = data_.principalToken.collect(
            address(this),
            address(this)
        );

        emit NapierCollectFuseEnter(VERSION, address(data_.principalToken), collected, rewards);
    }
}
