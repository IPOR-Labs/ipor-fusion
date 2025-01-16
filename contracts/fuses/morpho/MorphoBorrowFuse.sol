// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Data structure for entering a Morpho borrow fuse.
struct MorphoBorrowFuseEnterData {
    /// @dev The ID of the Morpho market.
    bytes32 morphoMarketId;
    /// @dev The amount to borrow.
    uint256 amountToBorrow;
    /// @dev The shares to borrow.
    uint256 sharesToBorrow;
}

/// @dev Data structure for exiting a Morpho borrow fuse, repay on Morpho.
struct MorphoBorrowFuseExitData {
    /// @dev The ID of the Morpho market.
    bytes32 morphoMarketId;
    /// @dev The amount to repay in borrow asset decimals .
    uint256 amountToRepay;
    /// @dev The shares to repay in morpho decimals.
    uint256 sharesToRepay;
}

contract MorphoBorrowFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @dev The version of the contract.
    address public immutable VERSION;
    /// @dev The unique identifier for IporFusionMarkets.
    uint256 public immutable MARKET_ID;
    /// @dev The address of the Morpho contract.
    IMorpho public immutable MORPHO;

    error MorphoBorrowFuseUnsupportedMarket(string action, bytes32 morphoMarketId);

    event MorphoBorrowFuseEvent(
        address version,
        uint256 marketId,
        bytes32 morphoMarket,
        uint256 assetsBorrowed,
        uint256 sharesBorrowed
    );

    event MorphoBorrowFuseRepay(
        address version,
        uint256 marketId,
        bytes32 morphoMarket,
        uint256 assetsRepaid,
        uint256 sharesRepaid
    );

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    function enter(MorphoBorrowFuseEnterData calldata data_) public {
        if (data_.amountToBorrow == 0 && data_.sharesToBorrow == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoBorrowFuseUnsupportedMarket("enter", data_.morphoMarketId);
        }

        (uint256 assetsBorrowed, uint256 sharesBorrowed) = MORPHO.borrow(
            MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId)),
            data_.amountToBorrow,
            data_.sharesToBorrow,
            address(this),
            address(this)
        );

        emit MorphoBorrowFuseEvent(VERSION, MARKET_ID, data_.morphoMarketId, assetsBorrowed, sharesBorrowed);
    }

    function exit(MorphoBorrowFuseExitData calldata data_) public {
        if (data_.amountToRepay == 0 && data_.sharesToRepay == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoBorrowFuseUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        /// @dev Approve the loan token to be spent by MORPHO, to max value because cost of calculation in case when want to send shears to repay
        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), type(uint256).max);

        (uint256 assetsRepaid, uint256 sharesRepaid) = MORPHO.repay(
            marketParams,
            data_.amountToRepay,
            data_.sharesToRepay,
            address(this),
            bytes("")
        );

        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), 0);

        emit MorphoBorrowFuseRepay(VERSION, MARKET_ID, data_.morphoMarketId, assetsRepaid, sharesRepaid);
    }
}
