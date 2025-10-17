// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {FullMath} from "../ramses/ext/FullMath.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IYieldBasisLT} from "./ext/IYieldBasisLT.sol";
/// @notice Data structure for entering - supply - the Yield Basis vault
struct YieldBasisLtSupplyFuseEnterData {
    /// @dev Leveraged Liquidity Token address (lt)
    address ltAddress;
    /// @dev amount to supply, this is amount of underlying asset in the given Yield Basis vault
    uint256 ltAssetAmount;
    /// @dev amount of debt to take, this is amount of debt for AMM to take (approximately ltAssetAmount * ltPrice), this is in USD, represented in 18 decimals
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
    using SafeERC20 for IERC20;

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

        IERC20(ltAssetToken).forceApprove(data_.ltAddress, data_.ltAssetAmount);

        uint256 ltSharesAmountReceived = IYieldBasisLT(data_.ltAddress).deposit(
            data_.ltAssetAmount,
            data_.debt,
            data_.minSharesToReceive,
            address(this)
        );

        IERC20(ltAssetToken).forceApprove(data_.ltAddress, 0);

        emit YieldBasisLtSupplyFuseEnter(
            VERSION,
            data_.ltAddress,
            ltAssetToken,
            data_.ltAssetAmount,
            data_.debt,
            ltSharesAmountReceived
        );
    }

    function exit(YieldBasisLtSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying assets, params[1] - LT address
    function instantWithdraw(bytes32[] calldata params_) external override {
        /// @dev params[0] - amount in underlying assets, params[1] - LT address
        address plasmaVaultAddress = address(this);
        uint256 plasmaVaultUnderlyingAssetsAmount = uint256(params_[0]);
        uint256 plasmaVaultUnderlyingAssetsAmountDecimals = IERC20Metadata(IERC4626(plasmaVaultAddress).asset())
            .decimals();

        address ltAddress = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        if (plasmaVaultUnderlyingAssetsAmount == 0) {
            return;
        }

        IYieldBasisLT lt = IYieldBasisLT(ltAddress);

        uint256 underlyingAmountInWad = IporMath.convertToWad(
            plasmaVaultUnderlyingAssetsAmount,
            plasmaVaultUnderlyingAssetsAmountDecimals
        );

        uint256 ltSharesAmount = FullMath.mulDiv(underlyingAmountInWad, 1e18, lt.pricePerShare());

        uint256 ltSharesToWithdraw = IporMath.min(ltSharesAmount, lt.balanceOf(plasmaVaultAddress));

        if (ltSharesToWithdraw == 0) {
            return;
        }

        _exit(YieldBasisLtSupplyFuseExitData(ltAddress, ltSharesToWithdraw, 0));
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
