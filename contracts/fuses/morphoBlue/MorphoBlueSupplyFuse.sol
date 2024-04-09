// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";

import {MarketConfigurationLib} from "../../libraries/MarketConfigurationLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoLib.sol";

contract MorphoBlueSupplyFuse is IFuse {
    using SafeCast for uint256;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    struct MorphoBlueSupplyFuseData {
        // vault address
        bytes32 morphoBlueMarketId;
        // max amount to supply
        uint256 amount;
    }

    event MorphoBlueSupplyFuse(address version, string action, address asset, bytes32 market, uint256 amount);

    error MorphoBlueSupplyFuseUnsupportedMarket(string action, bytes32 morphoBlueMarketId, string errorCode);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external {
        MorphoBlueSupplyFuseData memory data = abi.decode(data, (MorphoBlueSupplyFuseData));
        _enter(data);
    }

    function enter(MorphoBlueSupplyFuseData memory data) external {
        _enter(data);
    }

    function _enter(MorphoBlueSupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateGranted(MARKET_ID, data.morphoBlueMarketId)) {
            revert MorphoBlueSupplyFuseUnsupportedMarket("enter", data.morphoBlueMarketId, Errors.UNSUPPORTED_MARKET);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data.morphoBlueMarketId));

        IApproveERC20(marketParams.loanToken).approve(address(MORPHO), data.amount);

        (uint256 assetsSupplied, ) = MORPHO.supply(marketParams, data.amount, 0, address(this), bytes(""));

        emit MorphoBlueSupplyFuse(VERSION, "enter", marketParams.loanToken, data.morphoBlueMarketId, assetsSupplied);
    }

    function exit(bytes calldata data) external {
        MorphoBlueSupplyFuseData memory data = abi.decode(data, (MorphoBlueSupplyFuseData));
        _exit(data);
    }

    function exit(MorphoBlueSupplyFuseData calldata data) external {
        _exit(data);
    }

    function _exit(MorphoBlueSupplyFuseData memory data) internal {
        if (!MarketConfigurationLib.isSubstrateGranted(MARKET_ID, data.morphoBlueMarketId)) {
            revert MorphoBlueSupplyFuseUnsupportedMarket("enter", data.morphoBlueMarketId, Errors.UNSUPPORTED_MARKET);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data.morphoBlueMarketId));
        Id id = marketParams.id();

        MORPHO.accrueInterest(marketParams);
        uint256 totalSupplyAssets = MORPHO.totalSupplyAssets(id);
        uint256 totalSupplyShares = MORPHO.totalSupplyShares(id);
        uint256 shares = MORPHO.supplyShares(id, address(this));

        uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        uint256 assetsWithdrawn;
        uint256 sharesWithdrawn;

        if (data.amount >= assetsMax) {
            (assetsWithdrawn, sharesWithdrawn) = MORPHO.withdraw(marketParams, 0, shares, address(this), address(this));
        } else {
            (assetsWithdrawn, sharesWithdrawn) = MORPHO.withdraw(
                marketParams,
                data.amount,
                0,
                address(this),
                address(this)
            );
        }
        emit MorphoBlueSupplyFuse(VERSION, "exit", marketParams.loanToken, data.morphoBlueMarketId, assetsWithdrawn);
    }
}
