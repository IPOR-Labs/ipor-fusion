// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
/// @dev Inspired by SwapExecutorEth but tailored for async execution flows.
///      Manages cached balance tracking and asset fetching with slippage protection.
///      Only callable by the authorized Plasma Vault.
/// @author IPOR Labs
contract AsyncExecutor {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;

    /// @notice Cached balance expressed in the vault underlying asset units
    uint256 public balance;

    /// @notice Authorized Plasma Vault allowed to trigger asynchronous execution
    address public immutable PLASMA_VAULT;

    /// @notice Thrown when the provided data arrays are of mismatched lengths
    /// @custom:error AsyncExecutorInvalidArrayLength
    error AsyncExecutorInvalidArrayLength();

    /// @notice Thrown when the provided WETH address is zero
    /// @custom:error AsyncExecutorInvalidWethAddress
    error AsyncExecutorInvalidWethAddress();

    /// @notice Thrown when the provided Plasma Vault address is zero
    /// @custom:error AsyncExecutorInvalidPlasmaVaultAddress
    error AsyncExecutorInvalidPlasmaVaultAddress();

    /// @notice Thrown when aggregated balance is below allowed threshold
    /// @custom:error AsyncExecutorBalanceNotEnough
    error AsyncExecutorBalanceNotEnough();

    /// @notice Thrown when provided asset address is zero
    /// @custom:error AsyncExecutorInvalidAssetAddress
    error AsyncExecutorInvalidAssetAddress();

    /// @notice Thrown when provided price oracle address is zero
    /// @custom:error AsyncExecutorInvalidPriceOracleAddress
    error AsyncExecutorInvalidPriceOracleAddress();

    /// @notice Thrown when underlying asset address is invalid
    /// @custom:error AsyncExecutorInvalidUnderlyingAssetAddress
    error AsyncExecutorInvalidUnderlyingAssetAddress();

    /// @notice Thrown when caller is not authorized Plasma Vault
    /// @custom:error AsyncExecutorUnauthorizedCaller
    error AsyncExecutorUnauthorizedCaller();

    /// @notice Thrown when provided slippage threshold exceeds 100%
    /// @custom:error AsyncExecutorInvalidSlippage
    error AsyncExecutorInvalidSlippage();

    /// @notice Emitted after a successful async execution
    /// @param sender Address that initiated the execution
    /// @param tokenIn Address of the input token handled by this executor
    event AsyncExecutorExecuted(address indexed sender, address indexed tokenIn);

    /// @notice Emitted after a successful assets fetch
    /// @param assets Array of asset addresses that were fetched
    event AsyncExecutorAssetsFetched(address[] assets);

    /// @notice Address of WETH used for wrapping ETH dust (currently reserved for future use)
    address public immutable W_ETH;

    /// @notice Initializes the AsyncExecutor contract
    /// @param wEth_ Address of the WETH token contract (must not be address(0))
    /// @param plasmaVault_ Address of the controlling Plasma Vault (must not be address(0))
    constructor(address wEth_, address plasmaVault_) {
        if (wEth_ == address(0)) {
            revert AsyncExecutorInvalidWethAddress();
        }
        if (plasmaVault_ == address(0)) {
            revert AsyncExecutorInvalidPlasmaVaultAddress();
        }
        W_ETH = wEth_;
        PLASMA_VAULT = plasmaVault_;
    }

    /// @notice Executes a batch of asynchronous calls
    /// @param data_ Structure containing the execution payload
    /// @dev Validates array lengths, updates cached balance if needed, then executes each call sequentially.
    ///      Calls can include ETH value (if ethAmount > 0) or be regular calls.
    ///      Leftover ERC20 tokens and ETH remain in the executor contract and should be fetched via fetchAssets().
    ///      Only callable by the authorized Plasma Vault.
    function execute(SwapExecutorEthData calldata data_) external onlyPlasmaVault {
        uint256 len = data_.targets.length;

        if (len != data_.callDatas.length || len != data_.ethAmounts.length) {
            revert AsyncExecutorInvalidArrayLength();
        }

        // Update cached balance if executor has no cached balance
        if (balance == 0) {
            updateBalance(data_.tokenIn, data_.priceOracle);
        }

        address target;
        bytes memory callData;
        uint256 ethAmount;

        for (uint256 i; i < len; ++i) {
            target = data_.targets[i];
            callData = data_.callDatas[i];
            ethAmount = data_.ethAmounts[i];

            if (ethAmount > 0) {
                Address.functionCallWithValue(target, callData, ethAmount);
            } else {
                Address.functionCall(target, callData);
            }
        }

        emit AsyncExecutorExecuted(msg.sender, data_.tokenIn);
    }

    /// @notice Batch asset fetch and risk management by slippage threshold
    /// @param assets_ List of ERC20 asset addresses to fetch and transfer
    /// @param priceOracle_ Address of price oracle contract to value assets (must not be address(0))
    /// @param slippage_ Maximum allowed slippage as percentage in WAD format (1e18 = 100%, 5e16 = 5%)
    /// @dev Calculates total USD value of all assets, converts to underlying asset units, and validates
    ///      against cached balance with slippage tolerance.
    ///      If validation passes, transfers all assets to Plasma Vault and resets cached balance to zero.
    ///      Reverts if actual balance is below minimum allowed threshold (cached balance - slippage).
    ///      Only callable by the authorized Plasma Vault.
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
    /// @param asset_ ERC20 asset address representing the deposit token (must not be address(0))
    /// @param priceOracle_ Price oracle used to fetch asset valuations (must not be address(0))
    /// @dev Calculates USD value of the asset held by executor and converts it to underlying asset units.
    ///      Updates the public balance state variable.
    ///      Reverts if priceOracle_ is zero or if asset_ is zero.
    function updateBalance(address asset_, address priceOracle_) internal {
        if (priceOracle_ == address(0)) {
            revert AsyncExecutorInvalidPriceOracleAddress();
        }

        uint256 assetBalanceUsd = _calculateAssetUsdValue(asset_, priceOracle_);
        balance = _convertUsdPortfolioToUnderlying(assetBalanceUsd, priceOracle_);
    }

    /// @notice Allows the executor to receive ETH required for subsequent calls
    /// @dev Enables the contract to receive ETH payments for use in function calls with ETH value
    receive() external payable {}

    /// @notice Modifier that restricts function access to the authorized Plasma Vault
    /// @dev Reverts if the caller is not the authorized Plasma Vault
    modifier onlyPlasmaVault() {
        if (msg.sender != PLASMA_VAULT) {
            revert AsyncExecutorUnauthorizedCaller();
        }
        _;
    }

    /// @notice Calculates USD value of a given asset held by this executor in 18-decimal precision
    /// @param asset_ ERC20 asset address to evaluate (must not be address(0))
    /// @param priceOracle_ Price oracle responsible for quoting the asset in USD
    /// @return assetValueUsd Asset value expressed in USD with 18-decimal WAD precision
    /// @dev Fetches asset balance, converts to WAD, fetches price from oracle, converts price to WAD,
    ///      then multiplies balance * price and divides by WAD to get USD value.
    ///      Returns 0 if balance is zero. Reverts if asset_ is zero.
    function _calculateAssetUsdValue(address asset_, address priceOracle_)
        private
        view
        returns (uint256 assetValueUsd)
    {
        if (asset_ == address(0)) {
            revert AsyncExecutorInvalidAssetAddress();
        }

        uint256 assetBalance = IERC20(asset_).balanceOf(address(this));
        if (assetBalance == 0) {
            return 0;
        }

        (uint256 assetPrice, uint256 assetPriceDecimals) = IPriceOracleMiddleware(priceOracle_).getAssetPrice(asset_);
        uint256 assetBalanceWad = IporMath.convertToWad(assetBalance, IERC20Metadata(asset_).decimals());
        uint256 assetPriceWad = IporMath.convertToWad(assetPrice, assetPriceDecimals);

        // Calculate USD value: (balance in WAD) * (price in WAD) / WAD
        assetValueUsd = (assetBalanceWad * assetPriceWad) / WAD;
    }

    /// @notice Converts aggregated USD value to the vault underlying asset amount
    /// @param balanceInUsd USD value expressed in 18-decimal WAD format
    /// @param priceOracle Price oracle providing underlying asset quotes
    /// @return underlyingAmount Portfolio value converted to underlying asset denomination
    /// @dev Resolves underlying asset from calling Plasma Vault, fetches price, and converts USD to underlying units.
    ///      Returns 0 if balanceInUsd is zero.
    ///      Reverts if underlying asset address is zero.
    function _convertUsdPortfolioToUnderlying(uint256 balanceInUsd, address priceOracle)
        private
        view
        returns (uint256 underlyingAmount)
    {
        if (balanceInUsd == 0) {
            return 0;
        }

        address underlyingAsset = _resolveUnderlyingAsset();
        (uint256 underlyingPrice, uint256 underlyingPriceDecimals) =
            IPriceOracleMiddleware(priceOracle).getAssetPrice(underlyingAsset);
        uint256 underlyingAssetDecimals = IERC20Metadata(underlyingAsset).decimals();

        underlyingAmount = _convertUsdToUnderlyingAmount(
            balanceInUsd, underlyingPrice, underlyingPriceDecimals, underlyingAssetDecimals
        );
    }

    /// @notice Resolves underlying ERC4626 asset controlled by the calling Plasma Vault
    /// @return underlyingAsset Address of the underlying asset
    /// @dev Calls IERC4626.asset() on msg.sender (Plasma Vault) to get the underlying asset address.
    ///      Reverts if the returned address is zero or if msg.sender does not implement IERC4626.
    function _resolveUnderlyingAsset() private view returns (address underlyingAsset) {
        underlyingAsset = IERC4626(msg.sender).asset();
        if (underlyingAsset == address(0)) {
            revert AsyncExecutorInvalidUnderlyingAssetAddress();
        }
    }

    /// @notice Converts USD value to the amount of the underlying asset
    /// @param balanceInUSD USD value represented in 18-decimal WAD format
    /// @param underlyingPrice Price of the underlying asset returned by the oracle
    /// @param underlyingPriceDecimals Number of decimals returned by the oracle price
    /// @param underlyingAssetDecimals Decimals of the underlying ERC20 asset
    /// @return underlyingAmount Amount of the underlying asset corresponding to the provided USD value
    /// @dev Normalizes price to WAD (18 decimals), then calculates: (USD * 10^assetDecimals) / priceWad.
    ///      Handles cases where price decimals are less than, equal to, or greater than 18.
    function _convertUsdToUnderlyingAmount(
        uint256 balanceInUSD,
        uint256 underlyingPrice,
        uint256 underlyingPriceDecimals,
        uint256 underlyingAssetDecimals
    ) private pure returns (uint256 underlyingAmount) {
        uint256 underlyingPriceWad;
        // Normalize price to WAD (18 decimals)
        if (underlyingPriceDecimals < 18) {
            underlyingPriceWad = underlyingPrice * (10 ** (18 - underlyingPriceDecimals));
        } else if (underlyingPriceDecimals > 18) {
            underlyingPriceWad = underlyingPrice / (10 ** (underlyingPriceDecimals - 18));
        } else {
            underlyingPriceWad = underlyingPrice;
        }

        // Convert: (USD in WAD) * (10^assetDecimals) / (price in WAD) = underlying amount
        underlyingAmount = (balanceInUSD * (10 ** underlyingAssetDecimals)) / underlyingPriceWad;
    }
}