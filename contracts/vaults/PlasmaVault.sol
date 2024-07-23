// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {IPriceOracleMiddleware} from "../priceOracle/IPriceOracleMiddleware.sol";
import {IRewardsClaimManager} from "../interfaces/IRewardsClaimManager.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {AssetDistributionProtectionLib, DataToCheck, MarketToCheck} from "../libraries/AssetDistributionProtectionLib.sol";
import {PlasmaVaultGovernance} from "./PlasmaVaultGovernance.sol";

struct PlasmaVaultInitData {
    string assetName;
    string assetSymbol;
    address underlyingToken;
    address priceOracle;
    address[] alphas;
    MarketSubstratesConfig[] marketSubstratesConfigs;
    address[] fuses;
    MarketBalanceFuseConfig[] balanceFuses;
    FeeConfig feeConfig;
    address accessManager;
}

/// @notice FuseAction is a struct that represents a single action that can be executed by a Alpha
struct FuseAction {
    /// @notice fuse is a address of the Fuse contract
    address fuse;
    /// @notice data is a bytes data that is passed to the Fuse contract
    bytes data;
}

/// @notice MarketBalanceFuseConfig is a struct that represents a configuration of a balance fuse for a specific market
struct MarketBalanceFuseConfig {
    /// @notice When marketId is 0, then fuse is independent to a market - example flashloan fuse
    uint256 marketId;
    /// @notice address of the balance fuse
    address fuse;
}

/// @notice MarketSubstratesConfig is a struct that represents a configuration of substrates for a specific market
/// @notice substrates are assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
struct MarketSubstratesConfig {
    /// @notice marketId is a id of the market
    uint256 marketId;
    /// @notice substrates is a list of substrates for the market
    /// @dev it could be list of assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
    bytes32[] substrates;
}

/// @notice FeeConfig is a struct that represents a configuration of performance and management fees used during Plasma Vault construction
struct FeeConfig {
    /// @notice performanceFeeManager is a address of the performance fee manager
    address performanceFeeManager;
    /// @notice performanceFeeInPercentageInput is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 performanceFeeInPercentage;
    /// @notice managementFeeManager is a address of the management fee manager
    address managementFeeManager;
    /// @notice managementFeeInPercentageInput is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 managementFeeInPercentage;
}

/// @title PlasmaVault contract, ERC4626 contract, decimals in underlying token decimals
abstract contract PlasmaVault is ERC20, ERC4626, ReentrancyGuard, PlasmaVaultGovernance {
    using Address for address;
    using SafeCast for int256;

    address private constant USD = address(0x0000000000000000000000000000000000000348);
    uint256 public constant DEFAULT_SLIPPAGE_IN_PERCENTAGE = 2;

    error NoSharesToRedeem();
    error NoSharesToMint();
    error NoAssetsToWithdraw();
    error NoAssetsToDeposit();
    error UnsupportedFuse();

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    uint256 public immutable BASE_CURRENCY_DECIMALS;
    bool private _customConsumingSchedule;

    constructor(
        PlasmaVaultInitData memory initData_
    )
        ERC20(initData_.assetName, initData_.assetSymbol)
        ERC4626(IERC20Metadata(initData_.underlyingToken))
        PlasmaVaultGovernance(initData_.accessManager)
    {
        IPriceOracleMiddleware priceOracle = IPriceOracleMiddleware(initData_.priceOracle);

        if (priceOracle.BASE_CURRENCY() != USD) {
            revert Errors.UnsupportedBaseCurrencyFromOracle();
        }

        BASE_CURRENCY_DECIMALS = priceOracle.BASE_CURRENCY_DECIMALS();

        PlasmaVaultLib.setPriceOracle(initData_.priceOracle);

        for (uint256 i; i < initData_.fuses.length; ++i) {
            _addFuse(initData_.fuses[i]);
        }

        for (uint256 i; i < initData_.balanceFuses.length; ++i) {
            _addBalanceFuse(initData_.balanceFuses[i].marketId, initData_.balanceFuses[i].fuse);
        }

        for (uint256 i; i < initData_.marketSubstratesConfigs.length; ++i) {
            PlasmaVaultConfigLib.grandMarketSubstrates(
                initData_.marketSubstratesConfigs[i].marketId,
                initData_.marketSubstratesConfigs[i].substrates
            );
        }

        PlasmaVaultLib.configurePerformanceFee(
            initData_.feeConfig.performanceFeeManager,
            initData_.feeConfig.performanceFeeInPercentage
        );
        PlasmaVaultLib.configureManagementFee(
            initData_.feeConfig.managementFeeManager,
            initData_.feeConfig.managementFeeInPercentage
        );

        PlasmaVaultLib.updateManagementFeeData();
    }

    fallback() external {}

    /// @notice Execute multiple FuseActions by a granted Alphas. Any FuseAction is moving funds between markets and vault. Fuse Action not consider deposit and withdraw from Vault.
    function execute(FuseAction[] calldata calls_) external nonReentrant restricted {
        uint256 callsCount = calls_.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

        uint256 totalAssetsBefore = totalAssets();

        for (uint256 i; i < callsCount; ++i) {
            if (!FusesLib.isFuseSupported(calls_[i].fuse)) {
                revert UnsupportedFuse();
            }

            fuseMarketId = IFuseCommon(calls_[i].fuse).MARKET_ID();

            if (_checkIfExistsMarket(markets, fuseMarketId) == false) {
                markets[marketIndex] = fuseMarketId;
                marketIndex++;
            }

            calls_[i].fuse.functionDelegateCall(calls_[i].data);
        }

        _updateMarketsBalances(markets);

        _addPerformanceFee(totalAssetsBefore);
    }

    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    function transfer(address to_, uint256 value_) public virtual override(IERC20, ERC20) restricted returns (bool) {
        return super.transfer(to_, value_);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual override(IERC20, ERC20) restricted returns (bool) {
        return super.transferFrom(from_, to_, value_);
    }

    function deposit(uint256 assets_, address receiver_) public override nonReentrant restricted returns (uint256) {
        if (assets_ == 0) {
            revert NoAssetsToDeposit();
        }
        if (receiver_ == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.deposit(assets_, receiver_);
    }

    function mint(uint256 shares_, address receiver_) public override nonReentrant restricted returns (uint256) {
        if (shares_ == 0) {
            revert NoSharesToMint();
        }
        if (receiver_ == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.mint(shares_, receiver_);
    }

    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_
    ) public override nonReentrant restricted returns (uint256) {
        if (assets_ == 0) {
            revert NoAssetsToWithdraw();
        }

        if (receiver_ == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        uint256 totalAssetsBefore = totalAssets();

        _withdrawFromMarkets(assets_, IERC20(asset()).balanceOf(address(this)));

        _addPerformanceFee(totalAssetsBefore);

        return super.withdraw(assets_, receiver_, owner_);
    }

    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override nonReentrant restricted returns (uint256) {
        if (shares_ == 0) {
            revert NoSharesToRedeem();
        }

        if (receiver_ == address(0) || owner_ == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        uint256 assets;
        uint256 vaultCurrentBalanceUnderlying;

        uint256 totalAssetsBefore = totalAssets();

        for (uint256 i; i < 10; ++i) {
            assets = convertToAssets(shares_);
            vaultCurrentBalanceUnderlying = IERC20(asset()).balanceOf(address(this));
            if (vaultCurrentBalanceUnderlying >= assets) {
                break;
            }
            _withdrawFromMarkets(_includeSlippage(assets), vaultCurrentBalanceUnderlying);
        }

        _addPerformanceFee(totalAssetsBefore);

        return super.redeem(shares_, receiver_, owner_);
    }

    function claimRewards(FuseAction[] calldata calls_) external nonReentrant restricted {
        uint256 callsCount = calls_.length;
        for (uint256 i; i < callsCount; ++i) {
            calls_[i].fuse.functionDelegateCall(calls_[i].data);
        }
    }

    /// @notice Returns the total assets in the vault
    /// @dev value not take into account runtime accrued interest in the markets, and NOT take into account runtime accrued management fee
    /// @return total assets in the vault, represented in underlying token decimals
    function totalAssets() public view virtual override returns (uint256) {
        uint256 grossTotalAssets = _getGrossTotalAssets();
        uint256 unrealizedManagementFee = _getUnrealizedManagementFee(grossTotalAssets);
        if (unrealizedManagementFee >= grossTotalAssets) {
            return 0;
        } else {
            return grossTotalAssets - _getUnrealizedManagementFee(grossTotalAssets);
        }
    }

    /// @notice Returns the total assets in the vault for a specific market
    /// @param marketId_ The market id
    /// @return total assets in the vault for the market, represented in underlying token decimals
    function totalAssetsInMarket(uint256 marketId_) public view virtual returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(marketId_);
    }

    function isConsumingScheduledOp() public view override returns (bytes4) {
        return _customConsumingSchedule ? this.isConsumingScheduledOp.selector : bytes4(0);
    }

    /// @notice Returns the unrealized management fee in underlying token decimals
    /// @dev Unrealized management fee is calculated based on the management fee in percentage and the time since the last update
    /// @return unrealized management fee, represented in underlying token decimals
    function getUnrealizedManagementFee() public view returns (uint256) {
        return _getUnrealizedManagementFee(_getGrossTotalAssets());
    }

    function _addPerformanceFee(uint256 totalAssetsBefore_) internal {
        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter < totalAssetsBefore_) {
            return;
        }

        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();

        uint256 fee = Math.mulDiv(totalAssetsAfter - totalAssetsBefore_, feeData.feeInPercentage, 1e4);

        _mint(feeData.feeManager, convertToShares(fee));
    }

    function _realizeManagementFee() internal {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();

        uint256 unrealizedFeeInUnderlying = getUnrealizedManagementFee();

        if (unrealizedFeeInUnderlying == 0) {
            return;
        }

        PlasmaVaultLib.updateManagementFeeData();

        uint256 unrealizedFeeInShares = convertToShares(unrealizedFeeInUnderlying);

        /// @dev minting is an act of management fee realization
        _mint(feeData.feeManager, unrealizedFeeInShares);

        emit ManagementFeeRealized(unrealizedFeeInUnderlying, unrealizedFeeInShares);
    }

    function _includeSlippage(uint256 value_) internal pure returns (uint256) {
        /// @dev increase value by DEFAULT_SLIPPAGE_IN_PERCENTAGE to cover potential slippage
        return value_ + IporMath.division(value_ * DEFAULT_SLIPPAGE_IN_PERCENTAGE, 100);
    }

    /// @notice Withdraw assets from the markets
    /// @param assets_ Amount of assets to withdraw
    /// @param vaultCurrentBalanceUnderlying_ Current balance of the vault in underlying token
    function _withdrawFromMarkets(uint256 assets_, uint256 vaultCurrentBalanceUnderlying_) internal {
        if (assets_ == 0) {
            return;
        }

        uint256 left;

        if (assets_ >= vaultCurrentBalanceUnderlying_) {
            uint256 marketIndex;
            uint256 fuseMarketId;

            bytes32[] memory params;

            /// @dev assume that the same fuse can be used multiple times
            /// @dev assume that more than one fuse can be from the same market
            address[] memory fuses = PlasmaVaultLib.getInstantWithdrawalFuses();

            uint256[] memory markets = new uint256[](fuses.length);

            left = assets_ - vaultCurrentBalanceUnderlying_;

            uint256 i;
            uint256 fusesLength = fuses.length;

            for (i; left != 0 && i < fusesLength; ++i) {
                params = PlasmaVaultLib.getInstantWithdrawalFusesParams(fuses[i], i);

                /// @dev always first param is amount, by default is 0 in storage, set to left
                params[0] = bytes32(left);

                fuses[i].functionDelegateCall(abi.encodeWithSignature("instantWithdraw(bytes32[])", params));

                left = assets_ - IERC20(asset()).balanceOf(address(this));

                fuseMarketId = IFuseCommon(fuses[i]).MARKET_ID();

                if (_checkIfExistsMarket(markets, fuseMarketId) == false) {
                    markets[marketIndex] = fuseMarketId;
                    marketIndex++;
                }
            }

            _updateMarketsBalances(markets);
        }
    }

    /// @notice Update balances in the vault for markets touched by the fuses during the execution of all FuseActions
    /// @param markets_ Array of market ids touched by the fuses in the FuseActions
    function _updateMarketsBalances(uint256[] memory markets_) internal {
        uint256 wadBalanceAmountInUSD;
        DataToCheck memory dataToCheck;
        address balanceFuse;
        int256 deltasInUnderlying;
        uint256[] memory markets = _checkBalanceFusesDependencies(new uint256[](0), markets_, markets_.length);
        uint256 marketsLength = markets.length;
        /// @dev USD price is represented in 8 decimals
        uint256 underlyingAssetPrice = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracle()).getAssetPrice(asset());

        dataToCheck.marketsToCheck = new MarketToCheck[](marketsLength);
        for (uint256 i; i < marketsLength; ++i) {
            if (markets[i] == 0) {
                break;
            }

            balanceFuse = FusesLib.getBalanceFuse(markets[i]);

            wadBalanceAmountInUSD = abi.decode(
                balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf(address)", address(this))),
                (uint256)
            );
            dataToCheck.marketsToCheck[i].marketId = markets[i];
            dataToCheck.marketsToCheck[i].balanceInMarket = IporMath.convertWadToAssetDecimals(
                IporMath.division(wadBalanceAmountInUSD * 10 ** BASE_CURRENCY_DECIMALS, underlyingAssetPrice),
                decimals()
            );
            deltasInUnderlying =
                deltasInUnderlying +
                PlasmaVaultLib.updateTotalAssetsInMarket(markets[i], dataToCheck.marketsToCheck[i].balanceInMarket);
        }

        if (deltasInUnderlying != 0) {
            PlasmaVaultLib.addToTotalAssetsInAllMarkets(deltasInUnderlying);
        }

        dataToCheck.totalBalanceInVault = _getGrossTotalAssets();
        AssetDistributionProtectionLib.checkLimits(dataToCheck);

        emit MarketBalancesUpdated(markets, deltasInUnderlying);
    }

    function _checkBalanceFusesDependencies(
        uint256[] memory markets_,
        uint256[] memory marketsToCheck_,
        uint256 marketsToCheckLength_
    ) internal view returns (uint256[] memory updatedMarkets) {
        if (marketsToCheckLength_ == 0) {
            return markets_;
        }
        uint256[] memory tempMarkets = new uint256[](marketsToCheckLength_ * 2);
        uint256 tempMarketsIndex;

        for (uint256 i; i < marketsToCheckLength_; ++i) {
            if (
                marketsToCheck_[i] == 0 ||
                _checkIfExistsMarket(markets_, marketsToCheck_[i]) ||
                _checkIfExistsMarket(tempMarkets, marketsToCheck_[i])
            ) {
                continue;
            }

            if (tempMarkets.length == tempMarketsIndex + 1) {
                tempMarkets = _increaseArray(tempMarkets, tempMarkets.length + 10);
            }
            tempMarkets[tempMarketsIndex] = marketsToCheck_[i];
            ++tempMarketsIndex;

            uint256 dependentMarketsLength = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck_[i]).length;

            if (dependentMarketsLength == 0) {
                continue;
            }

            uint256[] memory dependentMarkets = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck_[i]);
            for (uint256 j; j < dependentMarketsLength; ++j) {
                if (tempMarkets.length == tempMarketsIndex + 1) {
                    tempMarkets = _increaseArray(tempMarkets, tempMarkets.length + 10);
                }
                tempMarkets[tempMarketsIndex] = dependentMarkets[j];
                ++tempMarketsIndex;
            }
        }
        updatedMarkets = _concatArrays(markets_, marketsToCheck_, markets_.length + marketsToCheckLength_);

        if (tempMarketsIndex > 0) {
            return _checkBalanceFusesDependencies(updatedMarkets, tempMarkets, tempMarketsIndex);
        }
        return updatedMarkets;
    }

    function _increaseArray(uint256[] memory arr_, uint256 newSize_) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](newSize_);
        for (uint256 i; i < arr_.length; ++i) {
            result[i] = arr_[i];
        }
        return result;
    }

    function _concatArrays(
        uint256[] memory arr1_,
        uint256[] memory arr2_,
        uint256 lengthOfNewArray_
    ) internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](lengthOfNewArray_);
        uint256 i;
        uint256 lengthOfArr1 = arr1_.length;
        for (i; i < lengthOfArr1; ++i) {
            result[i] = arr1_[i];
        }
        for (uint256 j; i < lengthOfNewArray_; ++j) {
            result[i] = arr2_[j];
            ++i;
        }
        return result;
    }

    function _checkIfExistsMarket(uint256[] memory markets_, uint256 marketId_) internal pure returns (bool exists) {
        for (uint256 i; i < markets_.length; ++i) {
            if (markets_[i] == 0) {
                break;
            }
            if (markets_[i] == marketId_) {
                exists = true;
                break;
            }
        }
    }

    function _getGrossTotalAssets() internal view returns (uint256) {
        address rewardsClaimManagerAddress = getRewardsClaimManagerAddress();
        if (rewardsClaimManagerAddress != address(0)) {
            return
                IERC20(asset()).balanceOf(address(this)) +
                PlasmaVaultLib.getTotalAssetsInAllMarkets() +
                IRewardsClaimManager(rewardsClaimManagerAddress).balanceOf();
        }
        return IERC20(asset()).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();
    }

    function _getUnrealizedManagementFee(uint256 totalAssets_) internal view returns (uint256) {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();

        uint256 blockTimestamp = block.timestamp;

        if (
            feeData.feeInPercentage == 0 ||
            feeData.lastUpdateTimestamp == 0 ||
            blockTimestamp <= feeData.lastUpdateTimestamp
        ) {
            return 0;
        }

        return
            Math.mulDiv(
                Math.mulDiv(totalAssets_, blockTimestamp - feeData.lastUpdateTimestamp, 365 days),
                feeData.feeInPercentage,
                1e4 /// @dev feeInPercentage is in percentage with 2 decimals, example 10000 is 100%
            );
    }

    /**
     * @dev Reverts if the caller is not allowed to call the function identified by a selector. Panics if the calldata
     * is less than 4 bytes long.
     */
    function _checkCanCall(address caller_, bytes calldata data_) internal virtual override {
        bytes4 sig = bytes4(data_[0:4]);
        bool immediate;
        uint32 delay;
        if (
            this.deposit.selector == sig ||
            this.mint.selector == sig ||
            this.withdraw.selector == sig ||
            this.redeem.selector == sig
        ) {
            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
        } else {
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        }
        if (!immediate) {
            if (delay > 0) {
                _customConsumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller_, data_);
                _customConsumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }
}
