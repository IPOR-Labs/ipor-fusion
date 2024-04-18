// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IFuse} from "../IFuse.sol";
import {IApproveERC20} from "../IApproveERC20.sol";

import {PlazmaVaultConfigLib} from "../../libraries/PlazmaVaultConfigLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";

struct MorphoBlueSupplyFuseEnterData {
    // vault address
    bytes32 morphoBlueMarketId;
    // max amount to supply
    uint256 amount;
}

struct MorphoBlueSupplyFuseExitData {
    // vault address
    bytes32 morphoBlueMarketId;
    // max amount to supply
    uint256 amount;
}

contract MorphoBlueSupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    event MorphoBlueSupplyEnterFuse(address version, address asset, bytes32 market, uint256 amount);
    event MorphoBlueSupplyExitFuse(address version, address asset, bytes32 market, uint256 amount);

    error MorphoBlueSupplyFuseUnsupportedMarket(string action, bytes32 morphoBlueMarketId, string errorCode);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketIdInput) {
        MARKET_ID = marketIdInput;
        VERSION = address(this);
    }

    function enter(bytes calldata data) external override {
        _enter(abi.decode(data, (MorphoBlueSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(MorphoBlueSupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external override {
        _exit(abi.decode(data, (MorphoBlueSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(MorphoBlueSupplyFuseExitData calldata data) external {
        _exit(data);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - Morpho market id
    function instantWithdraw(bytes32[] calldata params) external override {
        uint256 amount = uint256(params[0]);
        bytes32 morphoMarketId = params[1];

        _exit(MorphoBlueSupplyFuseExitData(morphoMarketId, amount));
    }

    function _enter(MorphoBlueSupplyFuseEnterData memory data) internal {
        if (!PlazmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data.morphoBlueMarketId)) {
            revert MorphoBlueSupplyFuseUnsupportedMarket("enter", data.morphoBlueMarketId, Errors.UNSUPPORTED_MARKET);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data.morphoBlueMarketId));

        IApproveERC20(marketParams.loanToken).approve(address(MORPHO), data.amount);

        (uint256 assetsSupplied, ) = MORPHO.supply(marketParams, data.amount, 0, address(this), bytes(""));

        emit MorphoBlueSupplyEnterFuse(VERSION, marketParams.loanToken, data.morphoBlueMarketId, assetsSupplied);
    }

    function _exit(MorphoBlueSupplyFuseExitData memory data) internal {
        if (!PlazmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data.morphoBlueMarketId)) {
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
        emit MorphoBlueSupplyExitFuse(VERSION, marketParams.loanToken, data.morphoBlueMarketId, assetsWithdrawn);
    }
}
