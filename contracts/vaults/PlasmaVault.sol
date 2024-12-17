// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {IPlasmaVault, FuseAction} from "../interfaces/IPlasmaVault.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {IPlasmaVaultBase} from "../interfaces/IPlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {IPriceOracleMiddleware} from "../price_oracle/IPriceOracleMiddleware.sol";
import {IRewardsClaimManager} from "../interfaces/IRewardsClaimManager.sol";
import {AccessManagedUpgradeable} from "../managers/access/AccessManagedUpgradeable.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultGovernance} from "./PlasmaVaultGovernance.sol";
import {AssetDistributionProtectionLib, DataToCheck, MarketToCheck} from "../libraries/AssetDistributionProtectionLib.sol";
import {CallbackHandlerLib} from "../libraries/CallbackHandlerLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {FeeManagerData, FeeManagerFactory, FeeConfig, FeeConfig} from "../managers/fee/FeeManagerFactory.sol";
import {FeeManagerInitData} from "../managers/fee/FeeManager.sol";
import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {UniversalReader} from "../universal_reader/UniversalReader.sol";
import {ContextClientStorageLib} from "../managers/context/ContextClientStorageLib.sol";

/// @notice PlasmaVaultInitData is a struct that represents a configuration of a Plasma Vault during construction
struct PlasmaVaultInitData {
    /// @notice assetName is a name of the asset shares in Plasma Vault
    string assetName;
    /// @notice assetSymbol is a symbol of the asset shares in Plasma Vault
    string assetSymbol;
    /// @notice underlyingToken is a address of the underlying token in Plasma Vault
    address underlyingToken;
    /// @notice priceOracleMiddleware is an address of the Price Oracle Middleware from Ipor Fusion
    address priceOracleMiddleware;
    /// @notice marketSubstratesConfigs is a list of MarketSubstratesConfig structs, which define substrates for specific markets
    MarketSubstratesConfig[] marketSubstratesConfigs;
    /// @notice fuses is a list of addresses of the Fuses
    address[] fuses;
    /// @notice balanceFuses is a list of MarketBalanceFuseConfig structs, which define balance fuses for specific markets
    MarketBalanceFuseConfig[] balanceFuses;
    /// @notice feeConfig is a FeeConfig struct, which defines performance, management fees and their managers
    FeeConfig feeConfig;
    /// @notice accessManager is a address of the Ipor Fusion Access Manager
    address accessManager;
    /// @notice plasmaVaultBase is a address of the Plasma Vault Base - contract that is responsible for the common logic of the Plasma Vault
    address plasmaVaultBase;
    /// @notice totalSupplyCap is a initial total supply cap of the Plasma Vault, represented in underlying token decimals
    uint256 totalSupplyCap;
    // @notice Address of the Withdraw Manager contract
    address withdrawManager;
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

/// @title Main contract of the Plasma Vault in ERC4626 standard - responsible for managing assets and shares by the Alphas via Fuses.
contract PlasmaVault is
    ERC20Upgradeable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    AccessManagedUpgradeable,
    UniversalReader,
    IPlasmaVault
{
    using Address for address;
    using SafeCast for int256;

    /// @notice ISO-4217 currency code for USD represented as address
    /// @dev 0x348 (840 in decimal) is the ISO-4217 numeric code for USD
    address private constant USD = address(0x0000000000000000000000000000000000000348);
    /// @dev Additional offset to withdraw from markets in case of rounding issues
    uint256 private constant WITHDRAW_FROM_MARKETS_OFFSET = 10;
    /// @dev 10 attempts to withdraw from markets in case of rounding issues
    uint256 private constant REDEEM_ATTEMPTS = 10;
    uint256 public constant DEFAULT_SLIPPAGE_IN_PERCENTAGE = 2;
    uint256 private constant FEE_PERCENTAGE_DECIMALS_MULTIPLIER = 1e4; /// @dev 10000 = 100% (2 decimal places for fee percentage)

    error NoSharesToRedeem();
    error NoSharesToMint();
    error NoAssetsToWithdraw();
    error NoAssetsToDeposit();
    error UnsupportedFuse();
    error UnsupportedMethod();
    error WithdrawIsNotAllowed(address caller, uint256 requested);

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address public immutable PLASMA_VAULT_BASE;

    constructor(PlasmaVaultInitData memory initData_) ERC20Upgradeable() ERC4626Upgradeable() initializer {
        super.__ERC20_init(initData_.assetName, initData_.assetSymbol);
        super.__ERC4626_init(IERC20(initData_.underlyingToken));

        PLASMA_VAULT_BASE = initData_.plasmaVaultBase;
        PLASMA_VAULT_BASE.functionDelegateCall(
            abi.encodeWithSelector(
                IPlasmaVaultBase.init.selector,
                initData_.assetName,
                initData_.accessManager,
                initData_.totalSupplyCap
            )
        );

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(initData_.priceOracleMiddleware);

        if (priceOracleMiddleware.QUOTE_CURRENCY() != USD) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        PlasmaVaultLib.setPriceOracleMiddleware(initData_.priceOracleMiddleware);

        PLASMA_VAULT_BASE.functionDelegateCall(
            abi.encodeWithSelector(PlasmaVaultGovernance.addFuses.selector, initData_.fuses)
        );

        for (uint256 i; i < initData_.balanceFuses.length; ++i) {
            // @dev in the moment of construction deployer has rights to add balance fuses
            PLASMA_VAULT_BASE.functionDelegateCall(
                abi.encodeWithSelector(
                    IPlasmaVaultGovernance.addBalanceFuse.selector,
                    initData_.balanceFuses[i].marketId,
                    initData_.balanceFuses[i].fuse
                )
            );
        }

        for (uint256 i; i < initData_.marketSubstratesConfigs.length; ++i) {
            PlasmaVaultConfigLib.grantMarketSubstrates(
                initData_.marketSubstratesConfigs[i].marketId,
                initData_.marketSubstratesConfigs[i].substrates
            );
        }

        FeeManagerData memory feeManagerData = FeeManagerFactory(initData_.feeConfig.feeFactory).deployFeeManager(
            FeeManagerInitData({
                initialAuthority: initData_.accessManager,
                plasmaVault: address(this),
                iporDaoManagementFee: initData_.feeConfig.iporDaoManagementFee,
                iporDaoPerformanceFee: initData_.feeConfig.iporDaoPerformanceFee,
                iporDaoFeeRecipientAddress: initData_.feeConfig.iporDaoFeeRecipientAddress,
                recipientManagementFees: initData_.feeConfig.recipientManagementFees,
                recipientPerformanceFees: initData_.feeConfig.recipientPerformanceFees
            })
        );

        PlasmaVaultLib.configurePerformanceFee(feeManagerData.performanceFeeAccount, feeManagerData.performanceFee);
        PlasmaVaultLib.configureManagementFee(feeManagerData.managementFeeAccount, feeManagerData.managementFee);

        PlasmaVaultLib.updateManagementFeeData();
        /// @dev If the address is zero, it means that scheduled withdrawals are turned off.
        PlasmaVaultLib.updateWithdrawManager(initData_.withdrawManager);
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (PlasmaVaultLib.isExecutionStarted()) {
            /// @dev Handle callback can be done only during the execution of the FuseActions by Alpha
            CallbackHandlerLib.handleCallback();
            return "";
        } else {
            return PLASMA_VAULT_BASE.functionDelegateCall(msg.data);
        }
    }

    /// @notice Execute multiple FuseActions by a granted Alphas. Any FuseAction is moving funds between markets and vault. Fuse Action not consider deposit and withdraw from Vault.
    function execute(FuseAction[] calldata calls_) external override nonReentrant restricted {
        uint256 callsCount = calls_.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

        uint256 totalAssetsBefore = totalAssets();

        PlasmaVaultLib.executeStarted();

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

        PlasmaVaultLib.executeFinished();

        _updateMarketsBalances(markets);

        _addPerformanceFee(totalAssetsBefore);
    }

    function updateMarketsBalances(uint256[] calldata marketIds_) external returns (uint256) {
        if (marketIds_.length == 0) {
            return totalAssets();
        }
        uint256 totalAssetsBefore = totalAssets();
        _updateMarketsBalances(marketIds_);
        _addPerformanceFee(totalAssetsBefore);

        return totalAssets();
    }

    function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    function transfer(
        address to_,
        uint256 value_
    ) public virtual override(IERC20, ERC20Upgradeable) restricted returns (bool) {
        return super.transfer(to_, value_);
    }

    function transferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual override(IERC20, ERC20Upgradeable) restricted returns (bool) {
        return super.transferFrom(from_, to_, value_);
    }

    function deposit(uint256 assets_, address receiver_) public override nonReentrant restricted returns (uint256) {
        return _deposit(assets_, receiver_);
    }

    function depositWithPermit(
        uint256 assets_,
        address owner_,
        address receiver_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external override nonReentrant restricted returns (uint256) {
        IERC20Permit(asset()).permit(owner_, address(this), assets_, deadline_, v_, r_, s_);
        return _deposit(assets_, receiver_);
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

        if (receiver_ == address(0) || owner_ == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        uint256 totalAssetsBefore = totalAssets();

        _withdrawFromMarkets(assets_ + WITHDRAW_FROM_MARKETS_OFFSET, IERC20(asset()).balanceOf(address(this)));

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

        for (uint256 i; i < REDEEM_ATTEMPTS; ++i) {
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

    function maxDeposit(address) public view virtual override returns (uint256) {
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        uint256 totalSupply = totalSupply();

        if (totalSupply >= totalSupplyCap) {
            return 0;
        }

        return convertToAssets(totalSupplyCap - totalSupply);
    }

    function maxMint(address) public view virtual override returns (uint256) {
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        uint256 totalSupply = totalSupply();

        if (totalSupply >= totalSupplyCap) {
            return 0;
        }

        return totalSupplyCap - totalSupply;
    }

    function claimRewards(FuseAction[] calldata calls_) external override nonReentrant restricted {
        uint256 callsCount = calls_.length;
        for (uint256 i; i < callsCount; ++i) {
            calls_[i].fuse.functionDelegateCall(calls_[i].data);
        }
    }

    /// @notice Returns the total assets in the vault
    /// @dev value not take into account runtime accrued interest in the markets, and NOT take into account runtime accrued performance fee
    /// @return total assets in the vault, represented in underlying token decimals
    function totalAssets() public view virtual override returns (uint256) {
        uint256 grossTotalAssets = _getGrossTotalAssets();
        uint256 unrealizedManagementFee = _getUnrealizedManagementFee(grossTotalAssets);

        if (unrealizedManagementFee >= grossTotalAssets) {
            return 0;
        } else {
            return grossTotalAssets - unrealizedManagementFee;
        }
    }

    /// @notice Returns the total assets in the vault for a specific market
    /// @param marketId_ The market id
    /// @return total assets in the Plasma Vault for given market, represented in underlying token decimals
    function totalAssetsInMarket(uint256 marketId_) public view virtual returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(marketId_);
    }

    /// @notice Returns the unrealized management fee in underlying token decimals
    /// @dev Unrealized management fee is calculated based on the management fee in percentage and the time since the last update
    /// @return unrealized management fee, represented in underlying token decimals
    function getUnrealizedManagementFee() public view returns (uint256) {
        return _getUnrealizedManagementFee(_getGrossTotalAssets());
    }

    /// @dev Mustn't use updateInternal, because is reserved for PlasmaVaultBase to call it as delegatecall in context of PlasmaVault
    function updateInternal(address, address, uint256) public {
        revert UnsupportedMethod();
    }

    function executeInternal(FuseAction[] calldata calls_) external {
        if (address(this) != msg.sender) {
            revert Errors.WrongCaller(msg.sender);
        }
        uint256 callsCount = calls_.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

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
    }

    function _deposit(uint256 assets_, address receiver_) internal returns (uint256) {
        if (assets_ == 0) {
            revert NoAssetsToDeposit();
        }
        if (receiver_ == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.deposit(assets_, receiver_);
    }

    function _addPerformanceFee(uint256 totalAssetsBefore_) internal {
        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter < totalAssetsBefore_) {
            return;
        }

        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();

        uint256 fee = Math.mulDiv(
            totalAssetsAfter - totalAssetsBefore_,
            feeData.feeInPercentage,
            FEE_PERCENTAGE_DECIMALS_MULTIPLIER
        );

        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        _mint(feeData.feeAccount, convertToShares(fee));

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);
    }

    function _realizeManagementFee() internal {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();

        uint256 unrealizedFeeInUnderlying = getUnrealizedManagementFee();

        PlasmaVaultLib.updateManagementFeeData();

        uint256 unrealizedFeeInShares = convertToShares(unrealizedFeeInUnderlying);

        if (unrealizedFeeInShares == 0) {
            return;
        }

        /// @dev minting is an act of management fee realization
        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        _mint(feeData.feeAccount, unrealizedFeeInShares);

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);

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

            uint256 balanceOf;
            uint256 fusesLength = fuses.length;

            for (uint256 i; left != 0 && i < fusesLength; ++i) {
                params = PlasmaVaultLib.getInstantWithdrawalFusesParams(fuses[i], i);

                /// @dev always first param is amount, by default is 0 in storage, set to left
                params[0] = bytes32(left);

                fuses[i].functionDelegateCall(abi.encodeWithSignature("instantWithdraw(bytes32[])", params));

                balanceOf = IERC20(asset()).balanceOf(address(this));

                if (assets_ > balanceOf) {
                    left = assets_ - balanceOf;
                } else {
                    left = 0;
                }

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
        uint256[] memory markets = _checkBalanceFusesDependencies(markets_);
        uint256 marketsLength = markets.length;

        /// @dev USD price is represented in 8 decimals
        (uint256 underlyingAssetPrice, uint256 underlyingAssePriceDecimals) = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        ).getAssetPrice(asset());

        dataToCheck.marketsToCheck = new MarketToCheck[](marketsLength);

        for (uint256 i; i < marketsLength; ++i) {
            if (markets[i] == 0) {
                break;
            }

            balanceFuse = FusesLib.getBalanceFuse(markets[i]);

            wadBalanceAmountInUSD = abi.decode(
                balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()")),
                (uint256)
            );
            dataToCheck.marketsToCheck[i].marketId = markets[i];

            dataToCheck.marketsToCheck[i].balanceInMarket = IporMath.convertWadToAssetDecimals(
                IporMath.division(
                    wadBalanceAmountInUSD * IporMath.BASIS_OF_POWER ** underlyingAssePriceDecimals,
                    underlyingAssetPrice
                ),
                (decimals() - _decimalsOffset())
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

    function _checkBalanceFusesDependencies(uint256[] memory markets_) internal view returns (uint256[] memory) {
        uint256 marketsLength = markets_.length;
        if (marketsLength == 0) {
            return markets_;
        }
        uint256[] memory marketsChecked = new uint256[](marketsLength * 2);
        uint256[] memory marketsToCheck = markets_;
        uint256 index;
        uint256[] memory tempMarketsToCheck;

        while (marketsToCheck.length > 0) {
            tempMarketsToCheck = new uint256[](marketsLength * 2);
            uint256 tempIndex;

            for (uint256 i; i < marketsToCheck.length; ++i) {
                if (!_checkIfExistsMarket(marketsChecked, marketsToCheck[i])) {
                    if (marketsChecked.length == index) {
                        marketsChecked = _increaseArray(marketsChecked, marketsChecked.length * 2);
                    }

                    marketsChecked[index] = marketsToCheck[i];
                    ++index;

                    uint256 dependentMarketsLength = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck[i]).length;
                    if (dependentMarketsLength > 0) {
                        for (uint256 j; j < dependentMarketsLength; ++j) {
                            if (tempMarketsToCheck.length == tempIndex) {
                                tempMarketsToCheck = _increaseArray(tempMarketsToCheck, tempMarketsToCheck.length * 2);
                            }
                            tempMarketsToCheck[tempIndex] = PlasmaVaultLib.getDependencyBalanceGraph(marketsToCheck[i])[
                                j
                            ];
                            ++tempIndex;
                        }
                    }
                }
            }
            marketsToCheck = _getUniqueElements(tempMarketsToCheck);
        }

        return _getUniqueElements(marketsChecked);
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
        address rewardsClaimManagerAddress = PlasmaVaultLib.getRewardsClaimManagerAddress();

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
                FEE_PERCENTAGE_DECIMALS_MULTIPLIER /// @dev feeInPercentage uses 2 decimal places, example 10000 = 100%
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
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0) && this.withdraw.selector == sig) {
            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
            uint256 amount = _extractAmountFromWithdrawAndRedeem();
            if (!WithdrawManager(withdrawManager).canWithdrawAndUpdate(caller_, amount)) {
                revert WithdrawIsNotAllowed(caller_, amount);
            }
        } else if (withdrawManager != address(0) && this.redeem.selector == sig) {
            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
            uint256 amount = convertToAssets(_extractAmountFromWithdrawAndRedeem());

            if (!WithdrawManager(withdrawManager).canWithdrawAndUpdate(caller_, amount)) {
                revert WithdrawIsNotAllowed(caller_, amount);
            }
        } else if (
            this.deposit.selector == sig ||
            this.mint.selector == sig ||
            this.depositWithPermit.selector == sig ||
            this.redeem.selector == sig ||
            this.withdraw.selector == sig
        ) {
            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
        } else {
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        }

        if (!immediate) {
            if (delay > 0) {
                AccessManagedStorage storage $ = _getAccessManagedStorage();
                $._consumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller_, data_);
                $._consumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }

    function _msgSender() internal view override returns (address) {
        return ContextClientStorageLib.getSenderFromContext();
    }

    function _update(address from_, address to_, uint256 value_) internal virtual override {
        PLASMA_VAULT_BASE.functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, from_, to_, value_)
        );
    }

    function _decimalsOffset() internal view virtual override returns (uint8) {
        return PlasmaVaultLib.DECIMALS_OFFSET;
    }

    /// @dev Notice! Amount are assets when withdraw or shares when redeem
    function _extractAmountFromWithdrawAndRedeem() private view returns (uint256) {
        (uint256 amount, , ) = abi.decode(_msgData()[4:], (uint256, address, address));
        return amount;
    }

    function _contains(uint256[] memory array_, uint256 element_, uint256 count_) private pure returns (bool) {
        for (uint256 i; i < count_; ++i) {
            if (array_[i] == element_) {
                return true;
            }
        }
        return false;
    }

    function _getUniqueElements(uint256[] memory inputArray_) private pure returns (uint256[] memory) {
        uint256[] memory tempArray = new uint256[](inputArray_.length);
        uint256 count = 0;

        for (uint256 i; i < inputArray_.length; ++i) {
            if (inputArray_[i] != 0 && !_contains(tempArray, inputArray_[i], count)) {
                tempArray[count] = inputArray_[i];
                count++;
            }
        }

        uint256[] memory uniqueArray = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            uniqueArray[i] = tempArray[i];
        }

        return uniqueArray;
    }
}
