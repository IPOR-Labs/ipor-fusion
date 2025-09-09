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

import {console2} from "forge-std/console2.sol";

/// @notice Data structure for entering - supply - the Yield Basis vault
struct YieldBasisLtSupplyFuseEnterData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount to supply, this is amount of underlying asset in the given Yield Basis vault
    uint256 ltAssetAmount;
    /// @dev minimum amount of underlying asset to supply, if not enough underlying asset is supplied, the enter will revert
    uint256 minLtAssetAmount;
    /// @dev amount of debt to take, this is amount of debt for AMM to take (approximately ltAssetAmount * ltPrice)
    uint256 debt;
    /// @dev minimum amount of shares to receive, if not enough shares are received, the enter will revert
    uint256 minSharesToReceive;
}

/// @notice Data structure for exiting - withdrawing - the Yield Basis vault
struct YieldBasisLtSupplyFuseExitData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount of shares to withdraw, this is amount of shares in the given Yield Basis vault
    uint256 ltSharesAmount;
    /// @dev minimum amount of underlying asset to receive, if not enough underlying asset is received, the exit will revert
    uint256 minLtAssetAmountToReceive;
}

/// @title Generic fuse for Yield Basis vaults responsible for supplying and withdrawing assets from the Yield Basis vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the Yield Basis vaults for a given MARKET_ID
contract YieldBasisLtSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    event YieldBasisLtSupplyFuseEnter(
        address version,
        address ltAddress,
        address ltAssetToken,
        uint256 ltAssetAmount,
        uint256 debt,
        uint256 ltSharesAmountReceived
    );
    event YieldBasisLtSupplyFuseInstantWithdrawExit(
        address version,
        address ltAddress,
        uint256 ltSharesAmount,
        uint256 ltAssetAmountReceived,
        int256 debtChange
    );

    event YieldBasisLtSupplyFuseExit(
        address version,
        address ltAddress,
        uint256 ltSharesAmount,
        uint256 ltAssetAmountReceived
    );

    error YieldBasisLtSupplyFuseInsufficientUnderlyingAssetAmount(
        uint256 finalUnderlyingAssetAmount,
        uint256 minUnderlyingAssetAmount
    );
    error YieldBasisLtSupplyFuseInsufficientLtAssetAmount(uint256 finalLtAssetAmount, uint256 minLtAssetAmount);
    error YieldBasisLtSupplyFuseInsufficientLtAssetAmountToReceive(
        uint256 finalLtAssetAmountToReceive,
        uint256 minLtAssetAmountToReceive
    );
    error YieldBasisLtSupplyFuseUnsupportedVault(string action, address asset);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(YieldBasisLtSupplyFuseEnterData memory data_) external {
        if (data_.ltAssetAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("enter", data_.ltAddress);
        }

        address ltAssetToken = IYieldBasisLT(data_.ltAddress).ASSET_TOKEN();

        uint256 finalLtAssetAmount = IporMath.min(
            data_.ltAssetAmount,
            IYieldBasisLT(ltAssetToken).balanceOf(address(this))
        );

        if (finalLtAssetAmount < data_.minLtAssetAmount) {
            revert YieldBasisLtSupplyFuseInsufficientUnderlyingAssetAmount(finalLtAssetAmount, data_.minLtAssetAmount);
        }

        ERC20(ltAssetToken).forceApprove(data_.ltAddress, finalLtAssetAmount);

        uint256 ltSharesAmountReceived = IYieldBasisLT(data_.ltAddress).deposit(
            finalLtAssetAmount,
            data_.debt,
            data_.minSharesToReceive,
            address(this)
        );

        emit YieldBasisLtSupplyFuseEnter(
            VERSION,
            data_.ltAddress,
            ltAssetToken,
            finalLtAssetAmount,
            data_.debt,
            ltSharesAmountReceived
        );
    }

    function exit(YieldBasisLtSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying assets, params[1] - LT address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 ltAssetAmount = uint256(params_[0]);
        address ltAddress = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        if (ltAssetAmount == 0) {
            return;
        }

        IYieldBasisLT lt = IYieldBasisLT(ltAddress);

        uint256 ltSharesAmount = (ltAssetAmount * 10 ** lt.decimals()) / lt.pricePerShare();

        uint256 actualShares = IYieldBasisLT(ltAddress).balanceOf(address(this));

        uint256 sharesToWithdraw = IporMath.min(ltSharesAmount, actualShares);

        console2.log("[instantWithdraw] actual shares", actualShares);
        console2.log("[instantWithdraw] shares to withdraw", sharesToWithdraw);

        console2.log("[instantWithdraw] ltAssetAmount", ltAssetAmount);
        console2.log("[instantWithdraw] pricePerShare", lt.pricePerShare()); // how many assets for 1 share
        console2.log("[instantWithdraw] ltSharesAmount", ltSharesAmount);

        if (sharesToWithdraw == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("instantWithdraw", ltAddress);
        }

        (uint256 ltAssetAmountReceived, int256 debtChange) = IYieldBasisLT(ltAddress).emergency_withdraw(
            sharesToWithdraw
        );

        emit YieldBasisLtSupplyFuseInstantWithdrawExit(
            VERSION,
            ltAddress,
            sharesToWithdraw,
            ltAssetAmountReceived,
            debtChange
        );
    }

    function _exit(YieldBasisLtSupplyFuseExitData memory data_) internal {
        if (data_.ltSharesAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.ltAddress)) {
            revert YieldBasisLtSupplyFuseUnsupportedVault("exit", data_.ltAddress);
        }

        uint256 ltAssetAmountReceived = IYieldBasisLT(data_.ltAddress).withdraw(
            data_.ltSharesAmount,
            data_.minLtAssetAmountToReceive,
            address(this)
        );

        emit YieldBasisLtSupplyFuseExit(VERSION, data_.ltAddress, data_.ltSharesAmount, ltAssetAmountReceived);
    }
}
