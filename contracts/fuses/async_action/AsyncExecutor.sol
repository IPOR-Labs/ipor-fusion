// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "../../interfaces/ext/IWETH9.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

struct SwapExecutorEthData {
    address tokenIn;
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address priceOracle;
}

/// @title AsyncExecutor
/// @notice Executes asynchronous swap actions based on pre-encoded call data
/// @dev Inspired by SwapExecutorEth but tailored for async execution flows
/// @author IPOR Labs
contract AsyncExecutor {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;

    /// @notice Cached balance expressed in the vault underlying asset units
    uint256 public balance;

    /// @notice Authorized Plasma Vault allowed to trigger asynchronous execution
    address public immutable PLASMA_VAULT;

    /// @notice Thrown when the provided data arrays are of mismatched lengths
    error AsyncExecutorInvalidArrayLength();

    /// @notice Thrown when the provided WETH address is zero
    error AsyncExecutorInvalidWethAddress();
    /// @notice Thrown when cached balance is expected to be cleared before execution
    error AsyncExecutorBalanceNotZero();
    /// @notice Thrown when aggregated balance is below allowed threshold
    error AsyncExecutorBalanceNotEnough();
    /// @notice Thrown when provided asset address is zero
    error AsyncExecutorInvalidAssetAddress();
    /// @notice Thrown when provided price oracle address is zero
    error AsyncExecutorInvalidPriceOracleAddress();
    /// @notice Thrown when underlying asset address is invalid
    error AsyncExecutorInvalidUnderlyingAssetAddress();
    /// @notice Thrown when caller is not authorized Plasma Vault
    error AsyncExecutorUnauthorizedCaller();
    /// @notice Thrown when provided slippage threshold exceeds 100%
    error AsyncExecutorInvalidSlippage();

    /// @notice Emitted after a successful async execution
    /// @param sender Address that initiated the execution
    /// @param tokenIn Address of the input token handled by this executor
    event AsyncExecutorExecuted(address indexed sender, address indexed tokenIn);

    /// @notice Emitted after a successful assets fetch
    /// @param assets Array of asset addresses that were fetched
    event AsyncExecutorAssetsFetched(address[] assets);

    /// @notice Address of WETH used for wrapping ETH dust
    address public immutable W_ETH;

    /// @notice Contract constructor
    /// @param wEth_ Address of the WETH token contract
    /// @param plasmaVault_ Address of the controlling Plasma Vault
    constructor(address wEth_, address plasmaVault_) {
        if (wEth_ == address(0)) {
            revert AsyncExecutorInvalidWethAddress();
        }
        W_ETH = wEth_;
        PLASMA_VAULT = plasmaVault_;
    }

    /// @notice Executes a batch of asynchronous calls
    /// @param data_ Structure containing the execution payload
    /// @dev Leftover ERC20 tokens and ETH are returned to the caller
    function execute(SwapExecutorEthData calldata data_) external onlyPlasmaVault {
        uint256 len_ = data_.targets.length;

        if (len_ != data_.callDatas.length || len_ != data_.ethAmounts.length) {
            revert AsyncExecutorInvalidArrayLength();
        }

        if (balance > 0) {
            updateBalance(data_.tokenIn, data_.priceOracle);
        }

        

        address target;
        bytes memory callData;
        uint256 ethAmount;

        for (uint256 i_; i_ < len_; ++i_) {
            target = data_.targets[i_];
            callData = data_.callDatas[i_];
            ethAmount = data_.ethAmounts[i_];

            if (ethAmount > 0) {
                Address.functionCallWithValue(target, callData, ethAmount);
            } else {
                Address.functionCall(target, callData);
            }
        }

        emit AsyncExecutorExecuted(msg.sender, data_.tokenIn);
    }

    /// @notice Batch asset fetch and risk management by slippage threshold
    /// @dev Processes updates for each given asset and ensures contract balance meets slippage constraint.
    ///      The parameter slippage_ is an 18-decimal fixed-point percentage, where 1e18 = 100%.
    ///      Example: slippage_ = 5e16 means a 5% slippage threshold.
    /// @param assets_ List of ERC20 asset addresses to update
    /// @param priceOracle_ Address of price oracle contract to value assets
    /// @param slippage_ Minimum balance threshold as percentage (1e18 = 100%)

    function fetchAssets(address[] calldata assets_, address priceOracle_, uint256 slippage_)
        external
        onlyPlasmaVault
    {
        if (priceOracle_ == address(0)) {
            revert AsyncExecutorInvalidPriceOracleAddress();
        }

        if (slippage_ > WAD) {
            revert AsyncExecutorInvalidSlippage();
        }

        uint256 actualBalance = balance;
        uint256 assetsLength = assets_.length;
        uint256 totalBalanceUsd;

        for (uint256 i; i < assetsLength; ++i) {
            totalBalanceUsd += _calculateAssetUsdValue(assets_[i], priceOracle_);
        }

        uint256 assetsBalanceInUnderlying = _convertUsdPortfolioToUnderlying(totalBalanceUsd, priceOracle_);

        if (actualBalance > 0) {
            uint256 minimumAllowedBalance = actualBalance - ((actualBalance * slippage_) / WAD);
            if (assetsBalanceInUnderlying < minimumAllowedBalance) {
                revert AsyncExecutorBalanceNotEnough();
            }
        }

        uint256 assetBalance;
        for (uint256 i; i < assetsLength; ++i) {
            assetBalance = IERC20(assets_[i]).balanceOf(address(this));
            if (assetBalance > 0) {
                IERC20(assets_[i]).safeTransfer(PLASMA_VAULT, assetBalance);
            }
        }

        balance = 0;

        emit AsyncExecutorAssetsFetched(assets_);
    }


    /// @notice Updates cached balance expressed in the vault underlying asset
    /// @param asset_ ERC20 asset address representing the deposit token
    /// @param priceOracle_ Price oracle used to fetch asset valuations
    function updateBalance(address asset_, address priceOracle_) internal {
        if (priceOracle_ == address(0)) {
            revert AsyncExecutorInvalidPriceOracleAddress();
        }

        uint256 assetBalanceUsd_ = _calculateAssetUsdValue(asset_, priceOracle_);
      balance = _convertUsdPortfolioToUnderlying(assetBalanceUsd_, priceOracle_);


    }


    /// @notice Allows the executor to receive ETH required for subsequent calls
    receive() external payable {}

    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert AsyncExecutorUnauthorizedCaller();
        }
        _;
    }

    /// @notice Calculates USD value of a given asset held by this executor in 18-decimal precision
    /// @param asset_ ERC20 asset address to evaluate
    /// @param priceOracle_ Price oracle responsible for quoting the asset in USD
    /// @return assetValueUsd_ Asset value expressed in USD with 18-decimal WAD precision
    function _calculateAssetUsdValue(address asset_, address priceOracle_)
        private
        view
        returns (uint256 assetValueUsd_)
    {
        if (asset_ == address(0)) {
            revert AsyncExecutorInvalidAssetAddress();
        }

        uint256 assetBalance_ = IERC20(asset_).balanceOf(address(this));
        if (assetBalance_ == 0) {
            return 0;
        }

        (uint256 assetPrice_, uint256 assetPriceDecimals_) = IPriceOracleMiddleware(priceOracle_).getAssetPrice(asset_);
        uint256 assetBalanceWad_ = IporMath.convertToWad(assetBalance_, IERC20Metadata(asset_).decimals());
        uint256 assetPriceWad_ = IporMath.convertToWad(assetPrice_, assetPriceDecimals_);

        assetValueUsd_ = (assetBalanceWad_ * assetPriceWad_) / WAD;
    }

    /// @notice Converts aggregated USD value to the vault underlying asset amount
    /// @param balanceInUsd_ USD value expressed in 18-decimal WAD format
    /// @param priceOracle_ Price oracle providing underlying asset quotes
    /// @return underlyingAmount_ Portfolio value converted to underlying asset denomination
    function _convertUsdPortfolioToUnderlying(uint256 balanceInUsd_, address priceOracle_)
        private
        view
        returns (uint256 underlyingAmount_)
    {
        if (balanceInUsd_ == 0) {
            return 0;
        }

        address underlyingAsset_ = _resolveUnderlyingAsset();
        (uint256 underlyingPrice_, uint256 underlyingPriceDecimals_) =
            IPriceOracleMiddleware(priceOracle_).getAssetPrice(underlyingAsset_);
        uint256 underlyingAssetDecimals_ = IERC20Metadata(underlyingAsset_).decimals();

        underlyingAmount_ = _convertUsdToUnderlyingAmount(
            balanceInUsd_, underlyingPrice_, underlyingPriceDecimals_, underlyingAssetDecimals_
        );
    }

    /// @notice Resolves underlying ERC4626 asset controlled by the calling Plasma Vault
    /// @return underlyingAsset_ Address of the underlying asset
    function _resolveUnderlyingAsset() private view returns (address underlyingAsset_) {
        underlyingAsset_ = IERC4626(msg.sender).asset();
        if (underlyingAsset_ == address(0)) {
            revert AsyncExecutorInvalidUnderlyingAssetAddress();
        }
    }

    /// @notice Converts USD value to the amount of the underlying asset
    /// @param balanceInUSD_ USD value represented in 18-decimal WAD format
    /// @param underlyingPrice_ Price of the underlying asset returned by the oracle
    /// @param underlyingPriceDecimals_ Number of decimals returned by the oracle price
    /// @param underlyingAssetDecimals_ Decimals of the underlying ERC20 asset
    /// @return underlyingAmount_ Amount of the underlying asset corresponding to the provided USD value
    function _convertUsdToUnderlyingAmount(
        uint256 balanceInUSD_,
        uint256 underlyingPrice_,
        uint256 underlyingPriceDecimals_,
        uint256 underlyingAssetDecimals_
    ) private pure returns (uint256 underlyingAmount_) {
        uint256 underlyingPriceWad_;
        if (underlyingPriceDecimals_ < 18) {
            underlyingPriceWad_ = underlyingPrice_ * (10 ** (18 - underlyingPriceDecimals_));
        } else if (underlyingPriceDecimals_ > 18) {
            underlyingPriceWad_ = underlyingPrice_ / (10 ** (underlyingPriceDecimals_ - 18));
        } else {
            underlyingPriceWad_ = underlyingPrice_;
        }

        underlyingAmount_ = (balanceInUSD_ * (10 ** underlyingAssetDecimals_)) / underlyingPriceWad_;
    }
}