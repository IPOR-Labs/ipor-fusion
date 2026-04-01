// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "../../../../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {MidasSupplyFuse, MidasSupplyFuseEnterData, MidasSupplyFuseExitData} from "../../../../../../contracts/fuses/midas/MidasSupplyFuse.sol";

/// @title MidasSupplyFuseHarness
/// @notice Test harness that simulates PlasmaVault context for MidasSupplyFuse unit tests.
///         MidasSupplyFuse is designed to run via delegatecall from PlasmaVault — this harness
///         provides the correct `address(this)` context with:
///         1. PlasmaVault diamond storage (for substrate grants)
///         2. ERC20 token balances held by the harness itself
///         3. Delegatecall routing to the fuse's enter/exit/instantWithdraw functions
///
/// @dev All state changes from the fuse (substrate reads, token approvals) happen in
///      the harness's storage and balance context.
contract MidasSupplyFuseHarness {
    address public immutable fuse;

    constructor(address fuse_) {
        fuse = fuse_;
    }

    // ============ Substrate Grant Helpers ============

    /// @notice Grant an mToken substrate for a market
    function grantMToken(uint256 marketId_, address mToken_) external {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant a deposit vault substrate for a market
    function grantDepositVault(uint256 marketId_, address depositVault_) external {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: depositVault_})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant an instant redemption vault substrate for a market
    function grantInstantRedemptionVault(uint256 marketId_, address instantRedemptionVault_) external {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                substrateAddress: instantRedemptionVault_
            })
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant an asset substrate for a market
    function grantAsset(uint256 marketId_, address asset_) external {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: asset_})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant multiple substrates at once for a market (all 3 needed for enter)
    /// @dev grantMarketSubstrates replaces all substrates, so call this for multi-grant
    function grantEnterSubstrates(
        uint256 marketId_,
        address mToken_,
        address depositVault_,
        address tokenIn_
    ) external {
        bytes32[] memory subs = new bytes32[](3);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
        );
        subs[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: depositVault_})
        );
        subs[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: tokenIn_})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant exactly [mToken, depositVault] — no ASSET (for testing E4 branch)
    function grantMTokenAndDepositVaultOnly(
        uint256 marketId_,
        address mToken_,
        address depositVault_
    ) external {
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
        );
        subs[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: depositVault_})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant exactly [mToken, instantRedemptionVault] — no ASSET (for testing X4 branch)
    function grantMTokenAndRedemptionVaultOnly(
        uint256 marketId_,
        address mToken_,
        address instantRedemptionVault_
    ) external {
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
        );
        subs[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                substrateAddress: instantRedemptionVault_
            })
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    /// @notice Grant multiple substrates at once for exit
    function grantExitSubstrates(
        uint256 marketId_,
        address mToken_,
        address instantRedemptionVault_,
        address tokenOut_
    ) external {
        bytes32[] memory subs = new bytes32[](3);
        subs[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: mToken_})
        );
        subs[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                substrateAddress: instantRedemptionVault_
            })
        );
        subs[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: tokenOut_})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, subs);
    }

    // ============ Delegatecall Forwarders ============

    /// @notice Delegatecall to fuse.enter — harness holds balances and substrate storage
    function enter(MidasSupplyFuseEnterData memory data_) external {
        (bool success, bytes memory returnData) = fuse.delegatecall(
            abi.encodeWithSelector(MidasSupplyFuse.enter.selector, data_)
        );
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @notice Delegatecall to fuse.exit
    function exit(MidasSupplyFuseExitData memory data_) external {
        (bool success, bytes memory returnData) = fuse.delegatecall(
            abi.encodeWithSelector(MidasSupplyFuse.exit.selector, data_)
        );
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @notice Delegatecall to fuse.instantWithdraw
    function instantWithdraw(bytes32[] calldata params_) external {
        (bool success, bytes memory returnData) = fuse.delegatecall(
            abi.encodeWithSelector(MidasSupplyFuse.instantWithdraw.selector, params_)
        );
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
