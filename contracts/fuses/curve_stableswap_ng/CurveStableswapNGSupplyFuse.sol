// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {ICurveStableSwapNG} from "./ext/ICurveStableSwapNG.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct CurveStableswapNGSupplyFuseEnterData {
    /// @notice List of amounts of coins to deposit
    uint256[] amounts;
    /// @notice Minimum amount of LP tokens to mint from the deposit
    uint256 minMintAmount;
    /// @notice Address to receive the minted LP tokens (msg.sender)
    address receiver;
}

struct CurveStableswapNGSupplyFuseExitData {
    /// @notice Amount of LP tokens to burn
    uint256 burnAmount;
    /// @notice Minimum amounts of coins to receive from the burn
    uint256[] minAmounts;
    /// @notice Address to receive the withdrawn coins (msg.sender)
    address receiver;
    /// @notice Flag to claim admin fees (True)
    bool claimAdminFees;
}

struct CurveStableswapNGSupplyFuseExitOneCoinData {
    /// @notice Amount of LP tokens to burn
    uint256 burnAmount;
    /// @notice Index of the coin to receive
    int128 coinIndex;
    /// @notice Minimum amount of the coin to receive
    uint256 minReceived;
    /// @notice Address to receive the withdrawn coins (msg.sender)
    address receiver;
}

contract CurveStableswapNGSupplyFuse is IFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    ICurveStableSwapNG public immutable CURVE_STABLESWAP_NG;

    event CurveSupplyStableswapNGSupplyEnterFuse(
        address indexed version,
        uint256[] amounts,
        uint256 minMintAmount,
        address receiver
    );

    event CurveSupplyStableswapNGSupplyExitFuse(
        address indexed version,
        uint256 burnAmount,
        uint256[] minAmounts,
        address receiver,
        bool claimAdminFees
    );

    event CurveSupplyStableswapNGSupplyExitOneCoinFuse(
        address indexed version,
        uint256 burnAmount,
        int128 coinIndex,
        uint256 minReceived,
        address receiver
    );

    bytes4 private constant EXIT_SELECTOR = bytes4(keccak256("exit(CurveStableswapNGSupplyFuseExitData)"));
    bytes4 private constant EXIT_ONE_COIN_SELECTOR =
        bytes4(keccak256("exitOneCoin(CurveStableswapNGSupplyFuseExitOneCoinData)"));

    constructor(uint256 marketIdInput, address curveStableswapNGInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
        CURVE_STABLESWAP_NG = ICurveStableSwapNG(curveStableswapNGInput);
    }

    function enter(bytes calldata data) external override {
        _enter(abi.decode(data, (CurveStableswapNGSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CurveStableswapNGSupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function exit(bytes calldata data) external override {
        if (data.length == 0) {
            revert Errors.InvalidInput();
        }

        bytes4 selector;
        assembly {
            selector := calldataload(data.offset)
        }

        if (selector == EXIT_SELECTOR) {
            _exit(abi.decode(data[4:], (CurveStableswapNGSupplyFuseExitData)));
        } else if (selector == EXIT_ONE_COIN_SELECTOR) {
            _exitOneCoin(abi.decode(data[4:], (CurveStableswapNGSupplyFuseExitOneCoinData)));
        } else {
            revert Errors.InvalidInput();
        }
    }

    function _enter(CurveStableswapNGSupplyFuseEnterData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(CURVE_STABLESWAP_NG))) {
            revert Errors.CurveStableswapNGSupplyFuseUnsupportedAsset(
                address(CURVE_STABLESWAP_NG),
                Errors.UNSUPPORTED_ASSET
            );
        }
        for (uint256 i = 0; i < data.amounts.length; ++i) {
            ERC20 asset = ERC20(CURVE_STABLESWAP_NG.coins(i));
            asset.safeApprove(address(CURVE_STABLESWAP_NG), data.amounts[i]);
        }
        uint256 mintAmount = CURVE_STABLESWAP_NG.add_liquidity(data.amounts, data.minMintAmount, data.receiver);
        emit CurveSupplyStableswapNGSupplyEnterFuse(VERSION, data.amounts, data.minMintAmount, data.receiver);
    }

    function _exit(CurveStableswapNGSupplyFuseExitData memory data) internal {
        uint256[] memory amounts = CURVE_STABLESWAP_NG.remove_liquidity(
            data.burnAmount,
            data.minAmounts,
            data.receiver,
            data.claimAdminFees
        );
        emit CurveSupplyStableswapNGSupplyExitFuse(
            VERSION,
            data.burnAmount,
            data.minAmounts,
            data.receiver,
            data.claimAdminFees
        );
    }

    function _exitOneCoin(CurveStableswapNGSupplyFuseExitOneCoinData memory data) internal {
        uint256 amountReceived = CURVE_STABLESWAP_NG.remove_liquidity_one_coin(
            data.burnAmount,
            data.coinIndex,
            data.minReceived,
            data.receiver
        );
        emit CurveSupplyStableswapNGSupplyExitOneCoinFuse(
            VERSION,
            data.burnAmount,
            data.coinIndex,
            data.minReceived,
            data.receiver
        );
    }
}
