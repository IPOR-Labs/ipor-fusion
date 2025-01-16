// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";

/// @notice Structure for entering (supply) to the Morpho protocol
struct MorphoSupplyFuseEnterData {
    // vault address
    bytes32 morphoMarketId;
    // max amount to supply
    uint256 amount;
}

/// @notice Structure for exiting (withdraw) from the Morpho protocol
struct MorphoSupplyFuseExitData {
    // vault address
    bytes32 morphoMarketId;
    // max amount to supply
    uint256 amount;
}

/// @title Fuse Morpho Supply protocol responsible for supplying and withdrawing assets from the Morpho protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the Morpho Market IDs that are used in the Morpho protocol for a given MARKET_ID
contract MorphoSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    IMorpho public immutable MORPHO;

    event MorphoSupplyFuseEnter(address version, address asset, bytes32 market, uint256 amount);
    event MorphoSupplyFuseExit(address version, address asset, bytes32 market, uint256 amount);
    event MorphoSupplyFuseExitFailed(address version, address asset, bytes32 market);

    error MorphoSupplyFuseUnsupportedMarket(string action, bytes32 morphoMarketId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    function enter(MorphoSupplyFuseEnterData memory data_) external {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoSupplyFuseUnsupportedMarket("enter", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), data_.amount);

        (uint256 assetsSupplied, ) = MORPHO.supply(marketParams, data_.amount, 0, address(this), bytes(""));

        emit MorphoSupplyFuseEnter(VERSION, marketParams.loanToken, data_.morphoMarketId, assetsSupplied);
    }

    function exit(MorphoSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - Morpho market id
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        bytes32 morphoMarketId = params_[1];

        _exit(MorphoSupplyFuseExitData(morphoMarketId, amount));
    }

    function _exit(MorphoSupplyFuseExitData memory data_) internal {
        if (data_.amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoSupplyFuseUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));
        Id id = marketParams.id();

        MORPHO.accrueInterest(marketParams);

        uint256 totalSupplyAssets = MORPHO.totalSupplyAssets(id);
        uint256 totalSupplyShares = MORPHO.totalSupplyShares(id);

        uint256 shares = MORPHO.supplyShares(id, address(this));

        if (shares == 0) {
            return;
        }

        uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        if (assetsMax == 0) {
            return;
        }

        if (data_.amount >= assetsMax) {
            try MORPHO.withdraw(marketParams, 0, shares, address(this), address(this)) returns (
                uint256 assetsWithdrawn,
                uint256 sharesWithdrawn
            ) {
                emit MorphoSupplyFuseExit(VERSION, marketParams.loanToken, data_.morphoMarketId, assetsWithdrawn);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit MorphoSupplyFuseExitFailed(VERSION, marketParams.loanToken, data_.morphoMarketId);
            }
        } else {
            try MORPHO.withdraw(marketParams, data_.amount, 0, address(this), address(this)) returns (
                uint256 assetsWithdrawn,
                uint256 sharesWithdrawn
            ) {
                emit MorphoSupplyFuseExit(VERSION, marketParams.loanToken, data_.morphoMarketId, assetsWithdrawn);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit MorphoSupplyFuseExitFailed(VERSION, marketParams.loanToken, data_.morphoMarketId);
            }
        }
    }
}
