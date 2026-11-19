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
///      The refreshed markets are also recorded with PlasmaVaultMarketsLib.recordCallbackMarkets, so that the vault
///      re-reads and limit-checks them once more at the end of the same execute (IL-9708). On a vault without the
///      IL-9404 record (no takeCallbackMarkets at the end of execute) the record has no effect.
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
    /// @dev Called via delegatecall from PlasmaVault.execute(). After the refresh the markets are recorded for the
    ///      final re-read of execute, which refreshes them again and checks their market limits against the NAV at the
    ///      end of execute (also when this fuse runs inside a flash loan callback). Zero ids are skipped by the record
    ///      and duplicates are merged by the vault. Side effect: a market above its limit that is refreshed here
    ///      makes the whole execute revert with MarketLimitExceeded; keepers refresh through
    ///      PlasmaVault.updateMarketsBalances instead.
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

        PlasmaVaultMarketsLib.recordCallbackMarkets(data_.marketIds);

        emit UpdateMarketsBalancesEnter(VERSION, data_.marketIds);
    }

    /// @notice Exit is not supported for this fuse
    /// @dev Always reverts with UpdateMarketsBalancesFuseExitNotSupported
    function exit(bytes calldata) external pure {
        revert UpdateMarketsBalancesFuseExitNotSupported();
    }
}
