// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IUpdateMarketsBalancesFuse, UpdateMarketsBalancesEnterData} from "./IUpdateMarketsBalancesFuse.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {PlasmaVaultMarketsLib} from "../../vaults/lib/PlasmaVaultMarketsLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title UpdateMarketsBalancesFuse
/// @author IPOR Labs
/// @notice Fuse that triggers market balance updates via PlasmaVault
/// @dev This fuse runs via delegatecall from PlasmaVault.execute(), so address(this) is the PlasmaVault.
contract UpdateMarketsBalancesFuse is IFuseCommon, IUpdateMarketsBalancesFuse {
    /// @notice Fuse version identifier (set to deployment address)
    address public immutable VERSION;

    /// @notice MARKET_ID is ZERO_BALANCE_MARKET as this fuse is not tied to a specific market
    uint256 public constant MARKET_ID = IporFusionMarkets.ZERO_BALANCE_MARKET;

    /// @notice Creates a new UpdateMarketsBalancesFuse instance
    constructor() {
        VERSION = address(this);
    }

    /// @notice Triggers balance updates for specified markets
    /// @param data_ Contains array of market IDs to update
    /// @dev Called via delegatecall from PlasmaVault.execute()
    function enter(UpdateMarketsBalancesEnterData memory data_) external {
        uint256 length = data_.marketIds.length;
        if (length == 0) {
            revert UpdateMarketsBalancesFuseEmptyMarkets();
        }

        // In delegatecall context, address(this) is PlasmaVault
        // Use IERC4626 interface to access PlasmaVault's asset() function
        address assetAddress = IERC4626(address(this)).asset();
        uint8 vaultDecimals = IERC20Metadata(address(this)).decimals();

        PlasmaVaultMarketsLib.updateMarketsBalances(
            data_.marketIds,
            assetAddress,
            vaultDecimals,
            PlasmaVaultLib.DECIMALS_OFFSET
        );

        emit UpdateMarketsBalancesEnter(VERSION, data_.marketIds);
    }

    /// @notice Exit is not supported for this fuse
    /// @dev Always reverts with UpdateMarketsBalancesFuseExitNotSupported
    function exit(bytes calldata) external pure {
        revert UpdateMarketsBalancesFuseExitNotSupported();
    }
}
