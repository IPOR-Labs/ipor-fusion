// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPriceFeed} from "./IPriceFeed.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ERC4626PriceFeed
/// @notice Price of one share of an ERC-4626 vault in USD: the live convertToAssets(10 ** decimals) times the asset
///         price from the calling middleware
/// @dev For a PlasmaVault the conversion has no execution gate inside that vault's execute batch or instant
///      withdrawal, so do not use this feed where a consumer can be called from within such an operation; see
///      "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)" in
///      contracts/vaults/README.md
contract ERC4626PriceFeed is IPriceFeed {
    using SafeCast for uint256;

    address public immutable vault;

    constructor(address _vault) {
        vault = _vault;
    }

    /// @inheritdoc IPriceFeed
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        uint256 vaultDecimals = IERC4626(vault).decimals();
        uint256 sharesPrice = IERC4626(vault).convertToAssets(10 ** vaultDecimals);
        address asset = IERC4626(vault).asset();

        /// @dev get price of asset in USD
        /// @dev msg.sender is PriceOracleMiddleware or PriceOracleMiddlewareManager
        (uint256 assetPrice, uint256 decimals) = IPriceOracleMiddleware(msg.sender).getAssetPrice(asset);

        uint256 uintPrice = IporMath.convertToWad(
            sharesPrice * assetPrice,
            IERC20Metadata(asset).decimals() + decimals
        );

        return (0, uintPrice.toInt256(), 0, 0, 0);
    }
}
