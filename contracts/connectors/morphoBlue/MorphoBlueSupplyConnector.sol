// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AssetsToMarketLib} from "../../libraries/AssetsToMarketLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IConnector} from "../IConnector.sol";
import {IApproveERC20} from "../IApproveERC20.sol";

import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";

contract MorphoBlueSupplyConnector is IConnector {
    using SafeCast for uint256;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    struct Erc4626SupplyConnectorData {
        // vault address
        bytes32 morphoBlueMarketId;
        // max amount to supply
        uint256 amount;
    }

    event MorphoBlueSupplyConnector(string action, uint256 version, address tokenIn, bytes32 marketId, uint256 amount);

    error MorphoBlueSupplyConnectorUnsupportedMarket(string action, bytes32 morphoBlueMarketId, string errorCode);

    uint256 public immutable MARKET_ID;
    uint256 public constant VERSION = 1;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
    }

    function enter(bytes calldata data) external returns (bytes memory executionStatus) {
        Erc4626SupplyConnectorData memory data = abi.decode(data, (Erc4626SupplyConnectorData));
        return _enter(data);
    }

    function enter(Erc4626SupplyConnectorData memory data) external returns (bytes memory executionStatus) {
        return _enter(data);
    }

    function _enter(Erc4626SupplyConnectorData memory data) internal returns (bytes memory executionStatus) {
        //        if (!AssetsToMarketLib.isAssetGrantedToMarket(MARKET_ID, data.morphoBlueMarketId)) {
        //            revert MorphoBlueSupplyConnectorUnsupportedMarket("enter", data.morphoBlueMarketId, Errors.NOT_SUPPORTED_MARKET);
        //        }

        IMorpho.MarketParams memory marketParams = MORPHO.idToMarketParams(data.morphoBlueMarketId);

        IApproveERC20(underlineAsset).approve(marketParams.loanToken, data.amount);

        (uint256 assetsSupplied, uint256 sharesSupplied) = MORPHO.supply(
            marketParams,
            data.amount,
            0,
            address(this),
            bytes("")
        );

        emit MorphoBlueSupplyConnector(
            "enter",
            VERSION,
            marketParams.loanToken,
            data.morphoBlueMarketId,
            assetsSupplied
        );
        return abi.encodePacked(uint256(1));
    }

    function exit(bytes calldata data) external returns (bytes memory executionStatus) {
        Erc4626SupplyConnectorData memory data = abi.decode(data, (Erc4626SupplyConnectorData));
        return _exit(data);
    }

    function exit(Erc4626SupplyConnectorData calldata data) external returns (bytes memory executionStatus) {
        return _exit(data);
    }

    function _exit(Erc4626SupplyConnectorData memory data) internal returns (bytes memory executionStatus) {
        //        if (!AssetsToMarketLib.isAssetGrantedToMarket(MARKET_ID, data.morphoBlueMarketId)) {
        //            revert Erc4626SupplyConnectorUnsupportedVault("exit", data.morphoBlueMarketId, Errors.NOT_SUPPORTED_MARKET);
        //        }

        IMorpho.MarketParams memory marketParams = MORPHO.idToMarketParams(data.morphoBlueMarketId);
        morpho.accrueInterest(marketParams);
        uint256 totalSupplyAssets = morpho.totalSupplyAssets(data.morphoBlueMarketId);
        uint256 totalSupplyShares = morpho.totalSupplyShares(data.morphoBlueMarketId);
        uint256 shares = morpho.supplyShares(data.morphoBlueMarketId, msg.sender);

        uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        if (amount >= assetsMax) {
            (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, 0, shares, address(this), address(this));
        } else {
            (assetsWithdrawn, sharesWithdrawn) = morpho.withdraw(marketParams, amount, 0, address(this), address(this));
        }
        emit MorphoBlueSupplyConnector(
            "exit",
            VERSION,
            marketParams.loanToken,
            data.morphoBlueMarketId,
            assetsWithdrawn
        );
        return abi.encodePacked(data.amount);
    }
}
