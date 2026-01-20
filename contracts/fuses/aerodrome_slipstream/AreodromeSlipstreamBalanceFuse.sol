// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {ICLPool} from "./ext/ICLPool.sol";
import {ISlipstreamSugar} from "./ext/ISlipstreamSugar.sol";
import {ICLGauge} from "./ext/ICLGauge.sol";

/// @title AreodromeSlipstreamBalanceFuse
/// @notice Contract responsible for managing Aerodrome Slipstream balance calculations
/// @dev This contract handles balance tracking for Plasma Vault positions in Aerodrome Slipstream pools and gauges.
///      Uses a curated storage-based list of position IDs to prevent DoS attacks via unbounded NFT enumeration.
///      Only positions that were legitimately created by the vault (tracked in FuseStorageLib) are included
///      in the balance calculation, preventing malicious actors from inflating gas costs by transferring
///      arbitrary NFTs to the vault.
contract AreodromeSlipstreamBalanceFuse is IMarketBalanceFuse {
    using Address for address;

    error InvalidAddress();
    error InvalidReturnData();

    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable SLIPSTREAM_SUPERCHAIN_SUGAR;
    address public immutable FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_, address slipstreamSuperchainSugar_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        if (slipstreamSuperchainSugar_ == address(0)) {
            revert InvalidAddress();
        }

        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        SLIPSTREAM_SUPERCHAIN_SUGAR = slipstreamSuperchainSugar_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();

        if (FACTORY == address(0)) {
            revert InvalidAddress();
        }
    }

    /// @notice Calculates the total balance of the Plasma Vault in Aerodrome Slipstream protocol
    /// @dev This function:
    ///      1. Retrieves all substrates (pool and gauge addresses) configured for the market
    ///      2. For Pool substrates: uses curated storage list and filters by pool to prevent DoS attacks
    ///      3. For Gauge substrates: uses stakedValues which is already filtered by gauge
    ///      4. Converts token amounts to USD using price oracle middleware
    /// @return The total balance of the Plasma Vault in USD, normalized to WAD (18 decimals)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory grantedSubstrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = grantedSubstrates.length;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        uint256 balance;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256[] memory tokenIds;
        uint256 tokenIdsLen;
        uint160 sqrtPriceX96;

        if (len == 0) {
            return 0;
        }

        AreodromeSlipstreamSubstrate memory substrate;

        for (uint256 i; i < len; i++) {
            substrate = AreodromeSlipstreamSubstrateLib.bytes32ToSubstrate(grantedSubstrates[i]);
            amount0 = 0;
            amount1 = 0;

            if (substrate.substrateType == AreodromeSlipstreamSubstrateType.Pool) {
                // Use curated storage list instead of unbounded ERC721 enumeration
                // This prevents DoS attacks where malicious actors transfer arbitrary NFTs to the vault
                uint256[] memory storedTokenIds = FuseStorageLib.getAerodromeSlipstreamTokenIds().tokenIds;
                tokenIdsLen = storedTokenIds.length;

                token0 = ICLPool(substrate.substrateAddress).token0();
                token1 = ICLPool(substrate.substrateAddress).token1();
                sqrtPriceX96 = ICLPool(substrate.substrateAddress).slot0().sqrtPriceX96;

                for (uint256 j; j < tokenIdsLen; j++) {
                    // Filter: only include positions that belong to the current substrate pool
                    if (_isPositionForPool(storedTokenIds[j], substrate.substrateAddress)) {
                        (amount0, amount1) = _addPrincipal(amount0, amount1, storedTokenIds[j], sqrtPriceX96);
                        (amount0, amount1) = _addFees(amount0, amount1, storedTokenIds[j]);
                    }
                }

                balance += _convertToUsd(amount0, token0, priceOracleMiddleware);
                balance += _convertToUsd(amount1, token1, priceOracleMiddleware);
            } else if (substrate.substrateType == AreodromeSlipstreamSubstrateType.Gauge) {
                // Gauge's stakedValues is already filtered - returns only positions staked in this gauge
                tokenIds = ICLGauge(substrate.substrateAddress).stakedValues(address(this));
                tokenIdsLen = tokenIds.length;
                token0 = ICLGauge(substrate.substrateAddress).token0();
                token1 = ICLGauge(substrate.substrateAddress).token1();
                sqrtPriceX96 = ICLGauge(substrate.substrateAddress).pool().slot0().sqrtPriceX96;

                for (uint256 j; j < tokenIdsLen; j++) {
                    (amount0, amount1) = _addPrincipal(amount0, amount1, tokenIds[j], sqrtPriceX96);
                }

                balance += _convertToUsd(amount0, token0, priceOracleMiddleware);
                balance += _convertToUsd(amount1, token1, priceOracleMiddleware);
            }
        }
        return balance;
    }

    /// @notice Checks if a position NFT belongs to a specific pool
    /// @param tokenId_ The NFT token ID to check
    /// @param poolAddress_ The pool address to match against
    /// @return True if the position belongs to the pool, false otherwise
    function _isPositionForPool(uint256 tokenId_, address poolAddress_) internal view returns (bool) {
        // Get position data to extract token0, token1, tickSpacing
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        if (returnData.length < 160) revert InvalidReturnData();

        address posToken0;
        address posToken1;
        int24 tickSpacing;

        assembly {
            posToken0 := mload(add(returnData, 96))
            posToken1 := mload(add(returnData, 128))
            tickSpacing := mload(add(returnData, 160))
        }

        // Compute the pool address for this position
        address computedPool = AreodromeSlipstreamSubstrateLib.getPoolAddress(
            FACTORY,
            posToken0,
            posToken1,
            tickSpacing
        );

        return computedPool == poolAddress_;
    }

    function _addPrincipal(
        uint256 amount0_,
        uint256 amount1_,
        uint256 tokenId_,
        uint160 sqrtPriceX96_
    ) internal view returns (uint256 newAmount0, uint256 newAmount1) {
        (uint256 principal0, uint256 principal1) = ISlipstreamSugar(SLIPSTREAM_SUPERCHAIN_SUGAR).principal(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            tokenId_,
            sqrtPriceX96_
        );

        newAmount0 = principal0 + amount0_;
        newAmount1 = principal1 + amount1_;

        return (newAmount0, newAmount1);
    }

    function _addFees(
        uint256 amount0_,
        uint256 amount1_,
        uint256 tokenId_
    ) internal view returns (uint256 newAmount0, uint256 newAmount1) {
        (uint256 fees0, uint256 fees1) = ISlipstreamSugar(SLIPSTREAM_SUPERCHAIN_SUGAR).fees(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            tokenId_
        );

        newAmount0 = fees0 + amount0_;
        newAmount1 = fees1 + amount1_;

        return (newAmount0, newAmount1);
    }

    function _convertToUsd(
        uint256 amount_,
        address token_,
        address priceOracleMiddleware_
    ) internal view returns (uint256) {
        (uint256 priceToken, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            token_
        );

        return IporMath.convertToWad((amount_) * priceToken, IERC20Metadata(token_).decimals() + priceDecimals);
    }
}
