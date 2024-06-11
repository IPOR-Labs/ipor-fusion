// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Math} from "@fusion/@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@fusion/@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20Permit} from "@fusion/@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@fusion/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@fusion/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@fusion/@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC4626Permit} from "../tokens/ERC4626/ERC4626Permit.sol";
import {Address} from "@fusion/@openzeppelin/contracts/utils/Address.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {IIporPriceOracle} from "../priceOracle/IIporPriceOracle.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultGovernance} from "./PlasmaVaultGovernance.sol";
import {IRewardsManager} from "../managers/IRewardsManager.sol";
import {PlasmaVaultAccessManager} from "../managers/PlasmaVaultAccessManager.sol";
import {IAccessManager} from "@fusion/@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@fusion/@openzeppelin/contracts/access/manager/AuthorityUtils.sol";

struct PlasmaVaultInitData {
    string assetName;
    string assetSymbol;
    address underlyingToken;
    address iporPriceOracle;
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
contract PlasmaVault is ERC4626Permit, ReentrancyGuard, PlasmaVaultGovernance {
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

    uint256 public immutable BASE_CURRENCY_DECIMALS;
    bool private _customConsumingSchedule;

    constructor(
        PlasmaVaultInitData memory initData
    )
        ERC4626Permit(IERC20(initData.underlyingToken))
        ERC20Permit(initData.assetName)
        ERC20(initData.assetName, initData.assetSymbol)
        PlasmaVaultGovernance(initData.accessManager)
    {
        IIporPriceOracle priceOracle = IIporPriceOracle(initData.iporPriceOracle);

        if (priceOracle.BASE_CURRENCY() != USD) {
            revert Errors.UnsupportedBaseCurrencyFromOracle(Errors.UNSUPPORTED_BASE_CURRENCY);
        }

        BASE_CURRENCY_DECIMALS = priceOracle.BASE_CURRENCY_DECIMALS();

        PlasmaVaultLib.setPriceOracle(initData.iporPriceOracle);

        for (uint256 i; i < initData.fuses.length; ++i) {
            _addFuse(initData.fuses[i]);
        }

        for (uint256 i; i < initData.balanceFuses.length; ++i) {
            _addBalanceFuse(initData.balanceFuses[i].marketId, initData.balanceFuses[i].fuse);
        }

        for (uint256 i; i < initData.marketSubstratesConfigs.length; ++i) {
            PlasmaVaultConfigLib.grandMarketSubstrates(
                initData.marketSubstratesConfigs[i].marketId,
                initData.marketSubstratesConfigs[i].substrates
            );
        }

        PlasmaVaultLib.configurePerformanceFee(
            initData.feeConfig.performanceFeeManager,
            initData.feeConfig.performanceFeeInPercentage
        );
        PlasmaVaultLib.configureManagementFee(
            initData.feeConfig.managementFeeManager,
            initData.feeConfig.managementFeeInPercentage
        );

        PlasmaVaultLib.updateManagementFeeData();
    }

    fallback() external {}

    function isConsumingScheduledOp() public view override returns (bytes4) {
        return _customConsumingSchedule ? this.isConsumingScheduledOp.selector : bytes4(0);
    }

    /// @notice Execute multiple FuseActions by a granted Alphas. Any FuseAction is moving funds between markets and vault. Fuse Action not consider deposit and withdraw from Vault.
    function execute(FuseAction[] calldata calls) external nonReentrant restricted {
        uint256 callsCount = calls.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

        uint256 totalAssetsBefore = totalAssets();

        for (uint256 i; i < callsCount; ++i) {
            if (!FusesLib.isFuseSupported(calls[i].fuse)) {
                revert UnsupportedFuse();
            }

            fuseMarketId = IFuseCommon(calls[i].fuse).MARKET_ID();

            if (_checkIfExistsMarket(markets, fuseMarketId) == false) {
                markets[marketIndex] = fuseMarketId;
                marketIndex++;
            }

            calls[i].fuse.functionDelegateCall(calls[i].data);
        }

        _updateMarketsBalances(markets);

        _addPerformanceFee(totalAssetsBefore);
    }

    function claimRewards(FuseAction[] calldata calls) external nonReentrant restricted {
        uint256 callsCount = calls.length;
        for (uint256 i; i < callsCount; ++i) {
            calls[i].fuse.functionDelegateCall(calls[i].data);
        }
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant restricted returns (uint256) {
        if (assets == 0) {
            revert NoAssetsToDeposit();
        }
        if (receiver == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant restricted returns (uint256) {
        if (shares == 0) {
            revert NoSharesToMint();
        }
        if (receiver == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.mint(shares, receiver);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant restricted returns (uint256) {
        if (assets == 0) {
            revert NoAssetsToWithdraw();
        }

        if (receiver == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        uint256 totalAssetsBefore = totalAssets();

        _withdrawFromMarkets(assets, IERC20(asset()).balanceOf(address(this)));

        _addPerformanceFee(totalAssetsBefore);

        return super.withdraw(assets, receiver, owner);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant restricted returns (uint256) {
        if (shares == 0) {
            revert NoSharesToRedeem();
        }

        if (receiver == address(0) || owner == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        uint256 assets;
        uint256 vaultCurrentBalanceUnderlying;

        uint256 totalAssetsBefore = totalAssets();

        for (uint256 i; i < 10; ++i) {
            assets = convertToAssets(shares);
            vaultCurrentBalanceUnderlying = IERC20(asset()).balanceOf(address(this));
            if (vaultCurrentBalanceUnderlying >= assets) {
                break;
            }
            _withdrawFromMarkets(_includeSlippage(assets), vaultCurrentBalanceUnderlying);
        }

        _addPerformanceFee(totalAssetsBefore);

        return super.redeem(shares, receiver, owner);
    }

    /// @notice Returns the total assets in the vault
    /// @dev value not take into account runtime accrued interest in the markets, and NOT take into account runtime accrued management fee
    /// @return total assets in the vault, represented in underlying token decimals
    function totalAssets() public view virtual override returns (uint256) {
        uint256 grossTotalAssets = _getGrossTotalAssets();
        return grossTotalAssets - _getUnrealizedManagementFee(grossTotalAssets);
    }

    /// @notice Returns the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @return total assets in the vault for the market, represented in underlying token decimals
    function totalAssetsInMarket(uint256 marketId) public view virtual returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(marketId);
    }

    /// @notice Returns the unrealized management fee in underlying token decimals
    /// @dev Unrealized management fee is calculated based on the management fee in percentage and the time since the last update
    /// @return unrealized management fee, represented in underlying token decimals
    function getUnrealizedManagementFee() public view returns (uint256) {
        return _getUnrealizedManagementFee(_getGrossTotalAssets());
    }

    function _addPerformanceFee(uint256 totalAssetsBefore) internal {
        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter < totalAssetsBefore) {
            return;
        }

        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();

        uint256 fee = Math.mulDiv(totalAssetsAfter - totalAssetsBefore, feeData.feeInPercentage, 1e4);

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

    function _includeSlippage(uint256 value) internal pure returns (uint256) {
        /// @dev increase value by DEFAULT_SLIPPAGE_IN_PERCENTAGE to cover potential slippage
        return value + IporMath.division(value * DEFAULT_SLIPPAGE_IN_PERCENTAGE, 100);
    }

    /// @notice Withdraw assets from the markets
    /// @param assets Amount of assets to withdraw
    /// @param vaultCurrentBalanceUnderlying Current balance of the vault in underlying token
    function _withdrawFromMarkets(uint256 assets, uint256 vaultCurrentBalanceUnderlying) internal {
        if (assets == 0) {
            return;
        }

        uint256 left;

        if (assets >= vaultCurrentBalanceUnderlying) {
            uint256 marketIndex;
            uint256 fuseMarketId;

            bytes32[] memory params;

            /// @dev assume that the same fuse can be used multiple times
            /// @dev assume that more than one fuse can be from the same market
            address[] memory fuses = PlasmaVaultLib.getInstantWithdrawalFuses();

            uint256[] memory markets = new uint256[](fuses.length);

            left = assets - vaultCurrentBalanceUnderlying;

            uint256 i;
            uint256 fusesLength = fuses.length;

            for (i; left != 0 && i < fusesLength; ++i) {
                params = PlasmaVaultLib.getInstantWithdrawalFusesParams(fuses[i], i);

                /// @dev always first param is amount, by default is 0 in storage, set to left
                params[0] = bytes32(left);

                fuses[i].functionDelegateCall(abi.encodeWithSignature("instantWithdraw(bytes32[])", params));

                left = assets - IERC20(asset()).balanceOf(address(this));

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
    /// @param markets Array of market ids touched by the fuses in the FuseActions
    function _updateMarketsBalances(uint256[] memory markets) internal {
        uint256 wadBalanceAmountInUSD;
        address balanceFuse;
        int256 deltasInUnderlying;

        /// @dev USD price is represented in 8 decimals
        uint256 underlyingAssetPrice = IIporPriceOracle(PlasmaVaultLib.getPriceOracle()).getAssetPrice(asset());

        for (uint256 i; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }

            balanceFuse = FusesLib.getBalanceFuse(markets[i]);

            wadBalanceAmountInUSD = abi.decode(
                balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf(address)", address(this))),
                (uint256)
            );

            deltasInUnderlying =
                deltasInUnderlying +
                PlasmaVaultLib.updateTotalAssetsInMarket(
                    markets[i],
                    IporMath.convertWadToAssetDecimals(
                        IporMath.division(wadBalanceAmountInUSD * 10 ** BASE_CURRENCY_DECIMALS, underlyingAssetPrice),
                        decimals()
                    )
                );
        }

        if (deltasInUnderlying != 0) {
            PlasmaVaultLib.addToTotalAssetsInAllMarkets(deltasInUnderlying);
        }
    }

    function _checkIfExistsMarket(uint256[] memory markets, uint256 marketId) internal pure returns (bool exists) {
        for (uint256 i; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }
            if (markets[i] == marketId) {
                exists = true;
                break;
            }
        }
    }

    function _getGrossTotalAssets() internal view returns (uint256) {
        address rewardsManagerAddress = getRewardsManagerAddress();
        if (rewardsManagerAddress != address(0)) {
            return
                IERC20(asset()).balanceOf(address(this)) +
                PlasmaVaultLib.getTotalAssetsInAllMarkets() +
                IRewardsManager(rewardsManagerAddress).balanceOf();
        }
        return IERC20(asset()).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();
    }

    function _getUnrealizedManagementFee(uint256 totalAssets) internal view returns (uint256) {
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
            (totalAssets * (blockTimestamp - feeData.lastUpdateTimestamp) * feeData.feeInPercentage) / 1e4 / 365 days;
    }

    /**
     * @dev Reverts if the caller is not allowed to call the function identified by a selector. Panics if the calldata
     * is less than 4 bytes long.
     */
    function _checkCanCall(address caller, bytes calldata data) internal virtual override {
        bytes4 sig = bytes4(data[0:4]);
        bool immediate;
        uint32 delay;
        if (
            this.deposit.selector == sig ||
            this.mint.selector == sig ||
            this.withdraw.selector == sig ||
            this.redeem.selector == sig
        ) {
            (immediate, delay) = PlasmaVaultAccessManager(authority()).canCallAndUpdate(caller, address(this), sig);
        } else {
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller, address(this), sig);
        }
        if (!immediate) {
            if (delay > 0) {
                _customConsumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller, data);
                _customConsumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller);
            }
        }
    }
}
