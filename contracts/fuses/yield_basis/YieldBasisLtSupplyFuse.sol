// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IYieldBasisLT} from "./ext/IYieldBasisLT.sol";

/// @notice Data structure for entering - supply - the Yield Basis vault
struct YieldBasisLtSupplyFuseEnterData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount to supply, this is amount of underlying asset in the given Yield Basis vault
    uint256 ltAssets;
    /// @dev minimum amount of underlying asset to supply, if not enough underlying asset is supplied, the enter will revert
    uint256 minLtAssets;
    /// @dev amount of debt to take, this is amount of debt for AMM to take (approximately ltAssetAmount * ltPrice)
    uint256 debt;
    /// @dev minimum amount of shares to receive, if not enough shares are received, the enter will revert
    uint256 minShares;
}

/// @notice Data structure for exiting - withdrawing - the Yield Basis vault
struct YieldBasisLtSupplyFuseExitData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount to withdraw, this is amount of shares in the given Yield Basis vault
    uint256 ltShares;
    /// @dev minimum amount of shares to withdraw, if not enough shares are withdrawn, the exit will revert
    uint256 minLtShares;
    /// @dev minimum amount of LT assets to receive, if not enough LT assets are received, the exit will revert
    uint256 minLtAssets;
}

/// @title Generic fuse for Yield Basis vaults responsible for supplying and withdrawing assets from the Yield Basis vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Yield Basis vaults for a given MARKET_ID
contract YieldBasisLtSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event YieldBasisLtSupplyFuseEnter(address version, address ltAddress, address ltAssetToken, uint256 ltAssets, uint256 debt, uint256 minShares);
    event YieldBasisLtSupplyFuseExit(
        address version,
        address ltAddress,
        address ltAssetToken,
        uint256 ltAssets,
        uint256 ltShares
    );

    error YieldBasisLtSupplyFuseInsufficientUnderlyingAssetAmount(
        uint256 finalUnderlyingAssetAmount,
        uint256 minUnderlyingAssetAmount
    );
    error YieldBasisLtSupplyFuseInsufficientLtShares(
        uint256 finalLtShares,
        uint256 minLtShares
    );
    error YieldBasisLtSupplyFuseUnsupportedVault(string action, address asset);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(YieldBasisLtSupplyFuseEnterData memory data_) external {
        if (data_.ltAssets == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("enter", data_.ltAddress);
        }

        address ltAssetToken = IYieldBasisLT(data_.ltAddress).ASSET_TOKEN();

        uint256 finalLtAssets = IporMath.min(
            data_.ltAssets,
            IYieldBasisLT(ltAssetToken).balanceOf(address(this))
        );

        if (finalLtAssets < data_.minLtAssets) {
            revert YieldBasisLtSupplyFuseInsufficientUnderlyingAssetAmount(
                finalLtAssets,
                data_.minLtAssets
            );
        }

        ERC20(ltAssetToken).forceApprove(data_.ltAddress, finalLtAssets);

        IYieldBasisLT(data_.ltAddress).deposit(finalLtAssets, data_.debt, data_.minShares, address(this));

        emit YieldBasisLtSupplyFuseEnter(VERSION, data_.ltAddress, ltAssetToken, finalLtAssets, data_.debt, data_.minShares);
    }

    function exit(YieldBasisLtSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in LT shares, params[1] - LT address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 ltShares = uint256(params_[0]);

        address ltAddress = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(YieldBasisLtSupplyFuseExitData(ltAddress, ltShares, 0, 0));
    }

    function _exit(YieldBasisLtSupplyFuseExitData memory data_) internal {
        if (data_.ltShares == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("exit", data_.ltAddress);
        }

        uint256 finalLtShares = IporMath.min(
            data_.ltShares,
            IYieldBasisLT(data_.ltAddress).balanceOf(address(this))
        );

        if (finalLtShares < data_.minLtShares) {
            revert YieldBasisLtSupplyFuseInsufficientLtShares(
                finalLtShares,
                data_.minLtShares
            );
        }

        uint256 finalLtAssets = IYieldBasisLT(data_.ltAddress).withdraw(finalLtShares, data_.minLtAssets, address(this));

        emit YieldBasisLtSupplyFuseExit(
                VERSION,
                data_.ltAddress,
                IYieldBasisLT(data_.ltAddress).ASSET_TOKEN(),
                finalLtAssets,
                finalLtShares
            );
    }
}
