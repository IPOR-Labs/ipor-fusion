// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {
    EbisuZapperSubstrateLib,
    EbisuZapperSubstrate,
    EbisuZapperSubstrateType
} from "./lib/EbisuZapperSubstrateLib.sol";

/// @notice Data to claim the collateral surplus of a branch
/// @param registry the Ebisu AddressesRegistry of the branch (must be granted as REGISTRY substrate)
struct EbisuClaimCollateralFuseEnterData {
    address registry;
}

/**
 * @title Fuse claiming the collateral surplus that a Liquity v2 liquidation credits to the Plasma Vault
 * @dev When a Trove owned by the Plasma Vault is liquidated, the surplus collateral is held in the branch's
 *      CollSurplusPool and is claimable only by the Trove owner through BorrowerOperations.claimCollateral().
 *      The BorrowerOperations address is read from the granted AddressesRegistry. Executed via delegatecall,
 *      so the Plasma Vault is msg.sender of the claim and receives the collateral token.
 */
contract EbisuClaimCollateralFuse is IFuseCommon {
    /// @notice Market ID of the Ebisu market
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when market ID is zero
    error EbisuClaimCollateralFuseInvalidMarketId();
    /// @notice Thrown when the registry is not granted as REGISTRY substrate of the market
    error EbisuClaimCollateralFuseUnsupportedSubstrate(address registry);

    /// @notice Emitted when the collateral surplus of a branch is claimed
    /// @param registry the AddressesRegistry of the branch
    /// @param collToken the collateral token received by the Plasma Vault
    /// @param amount the amount of collateral received (balance delta of the Plasma Vault)
    event EbisuClaimCollateralFuseEnter(address registry, address collToken, uint256 amount);

    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert EbisuClaimCollateralFuseInvalidMarketId();
        }
        MARKET_ID = marketId_;
    }

    /// @notice Claims the collateral surplus left by liquidated Troves of this Plasma Vault in the given branch
    /// @dev Reverts (in Liquity) when there is no surplus to claim
    /// @custom:revert EbisuClaimCollateralFuseUnsupportedSubstrate When the registry is not granted
    function enter(EbisuClaimCollateralFuseEnterData calldata data_) external {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                EbisuZapperSubstrateLib.substrateToBytes32(
                    EbisuZapperSubstrate({
                        substrateType: EbisuZapperSubstrateType.REGISTRY,
                        substrateAddress: data_.registry
                    })
                )
            )
        ) {
            revert EbisuClaimCollateralFuseUnsupportedSubstrate(data_.registry);
        }

        IAddressesRegistry registry = IAddressesRegistry(data_.registry);
        address collToken = address(registry.collToken());

        uint256 balanceBefore = IERC20(collToken).balanceOf(address(this));
        registry.borrowerOperations().claimCollateral();
        uint256 claimed = IERC20(collToken).balanceOf(address(this)) - balanceBefore;

        emit EbisuClaimCollateralFuseEnter(data_.registry, collToken, claimed);
    }
}
