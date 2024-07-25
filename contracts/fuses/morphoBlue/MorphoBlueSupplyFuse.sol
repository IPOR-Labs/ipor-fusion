// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuse} from "../IFuse.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

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
    using SafeERC20 for ERC20;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    event MorphoBlueSupplyEnterFuse(address version, address asset, bytes32 market, uint256 amount);
    event MorphoBlueSupplyExitFuse(address version, address asset, bytes32 market, uint256 amount);

    error MorphoBlueSupplyFuseUnsupportedMarket(string action, bytes32 morphoBlueMarketId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (MorphoBlueSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(MorphoBlueSupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (MorphoBlueSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(MorphoBlueSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - Morpho market id
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        bytes32 morphoMarketId = params_[1];

        _exit(MorphoBlueSupplyFuseExitData(morphoMarketId, amount));
    }

    function _enter(MorphoBlueSupplyFuseEnterData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoBlueMarketId)) {
            revert MorphoBlueSupplyFuseUnsupportedMarket("enter", data_.morphoBlueMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoBlueMarketId));

        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), data_.amount);

        (uint256 assetsSupplied, ) = MORPHO.supply(marketParams, data_.amount, 0, address(this), bytes(""));

        emit MorphoBlueSupplyEnterFuse(VERSION, marketParams.loanToken, data_.morphoBlueMarketId, assetsSupplied);
    }

    function _exit(MorphoBlueSupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoBlueMarketId)) {
            revert MorphoBlueSupplyFuseUnsupportedMarket("enter", data_.morphoBlueMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoBlueMarketId));
        Id id = marketParams.id();

        MORPHO.accrueInterest(marketParams);

        uint256 totalSupplyAssets = MORPHO.totalSupplyAssets(id);
        uint256 totalSupplyShares = MORPHO.totalSupplyShares(id);

        uint256 shares = MORPHO.supplyShares(id, address(this));

        uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        uint256 assetsWithdrawn;
        uint256 sharesWithdrawn;

        if (data_.amount >= assetsMax) {
            (assetsWithdrawn, sharesWithdrawn) = MORPHO.withdraw(marketParams, 0, shares, address(this), address(this));
        } else {
            (assetsWithdrawn, sharesWithdrawn) = MORPHO.withdraw(
                marketParams,
                data_.amount,
                0,
                address(this),
                address(this)
            );
        }
        emit MorphoBlueSupplyExitFuse(VERSION, marketParams.loanToken, data_.morphoBlueMarketId, assetsWithdrawn);
    }
}
