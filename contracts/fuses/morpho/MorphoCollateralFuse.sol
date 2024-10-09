// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @notice Structure for entering (supplyCollateral) to the Morpho protocol
struct MorphoCollateralFuseEnterData {
    // vault address
    bytes32 morphoMarketId;
    // max amount to supply
    uint256 amount;
}

/// @notice Structure for exiting (withdrawCollateral) from the Morpho protocol
struct MorphoCollateralFuseExitData {
    // vault address
    bytes32 morphoMarketId;
    // max amount to supply
    uint256 maxAmount;
}

contract MorphoCollateralFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IMorpho public immutable MORPHO;

    event MorphoCollateralFuseEnter(address version, address asset, bytes32 market, uint256 amount);
    event MorphoCollateralFuseExit(address version, address asset, bytes32 market, uint256 amount);

    error MorphoCollateralUnsupportedMarket(string action, bytes32 morphoMarketId);

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    function enter(MorphoCollateralFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoCollateralUnsupportedMarket("enter", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        uint256 collateralTokenBalance = ERC20(marketParams.collateralToken).balanceOf(address(this));

        uint256 transferAmount = data_.amount <= collateralTokenBalance ? data_.amount : collateralTokenBalance;

        ERC20(marketParams.collateralToken).forceApprove(address(MORPHO), transferAmount);

        MORPHO.supplyCollateral(marketParams, transferAmount, address(this), bytes(""));

        emit MorphoCollateralFuseEnter(VERSION, marketParams.collateralToken, data_.morphoMarketId, transferAmount);
    }

    function exit(MorphoCollateralFuseExitData calldata data_) external {
        if (data_.maxAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoCollateralUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        MORPHO.withdrawCollateral(marketParams, data_.maxAmount, address(this), address(this));

        emit MorphoCollateralFuseExit(VERSION, marketParams.collateralToken, data_.morphoMarketId, data_.maxAmount);
    }
}
