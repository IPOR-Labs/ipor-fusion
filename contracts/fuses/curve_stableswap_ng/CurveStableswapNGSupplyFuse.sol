// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
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

    ICurveStableswapNG public immutable CURVE_STABLESWAP_NG;

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
        bytes4(keccak256("exitOneCoin(CurveStableswapNGSupplyFuseExitData)"));

    error CurveStableswapNGSupplyFuseUnsupportedAsset(address asset, string errorCode);
    error CurveStableswapNGSupplyFuseUnexpectedNumberOfTokens();

    constructor(uint256 marketIdInput, address curveStableswapNGInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
        CURVE_STABLESWAP_NG = ICurveStableswapNG(curveStableswapNGInput);
    }

    function enter(bytes calldata data) external override {
        _enter(abi.decode(data, (CurveStableswapNGSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CurveStableswapNGSupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function _enter(CurveStableswapNGSupplyFuseEnterData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(CURVE_STABLESWAP_NG))) {
            revert CurveStableswapNGSupplyFuseUnsupportedAsset(address(CURVE_STABLESWAP_NG), Errors.UNSUPPORTED_ASSET);
        }
        ERC20[] memory underlyingTokens = _getUnderlyingTokens(data.amounts.length);
        for (uint256 i; i < data.amounts.length; ++i) {
            underlyingTokens[i].forceApprove(address(CURVE_STABLESWAP_NG), data.amounts[i]);
        }
        CURVE_STABLESWAP_NG.add_liquidity(data.amounts, data.minMintAmount, data.receiver);
        emit CurveSupplyStableswapNGSupplyEnterFuse(VERSION, data.amounts, data.minMintAmount, data.receiver);
    }

    function exit(bytes calldata data) external override {
        _exit(abi.decode(data, (CurveStableswapNGSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CurveStableswapNGSupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _exit(CurveStableswapNGSupplyFuseExitData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(CURVE_STABLESWAP_NG))) {
            revert CurveStableswapNGSupplyFuseUnsupportedAsset(address(CURVE_STABLESWAP_NG), Errors.UNSUPPORTED_ASSET);
        }
        CURVE_STABLESWAP_NG.remove_liquidity_one_coin(data.burnAmount, data.coinIndex, data.minReceived, data.receiver);
        emit CurveSupplyStableswapNGSupplyExitOneCoinFuse(
            VERSION,
            data.burnAmount,
            data.coinIndex,
            data.minReceived,
            data.receiver
        );
    }

    function _getUnderlyingTokens(uint256 expectedNumberTokens) internal view returns (ERC20[] memory) {
        ERC20[] memory underlyingTokens = new ERC20[](expectedNumberTokens);
        /// @dev we expect this to revert if expectedNumberTokens is greater than N_COINS
        for (uint256 i; i < expectedNumberTokens; ++i) {
            underlyingTokens[i] = ERC20(CURVE_STABLESWAP_NG.coins(i));
        }
        try CURVE_STABLESWAP_NG.coins(expectedNumberTokens) {
            revert CurveStableswapNGSupplyFuseUnexpectedNumberOfTokens();
        } catch {
            /// @dev we expect this to revert, so do nothing
        }
        return underlyingTokens;
    }
}
