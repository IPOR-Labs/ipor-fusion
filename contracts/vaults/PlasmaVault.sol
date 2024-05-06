// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC4626Permit} from "../tokens/ERC4626/ERC4626Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AlphasLib} from "../libraries/AlphasLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {IIporPriceOracle} from "../priceOracle/IIporPriceOracle.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";

/// @title PlasmaVault contract, ERC4626 contract, decimals in underlying token decimals
contract PlasmaVault is ERC4626Permit, Ownable2Step {
    using Address for address;
    using SafeCast for int256;

    address private constant USD = address(0x0000000000000000000000000000000000000348);
    uint256 public constant DEFAULT_SLIPPAGE_IN_PERCENTAGE = 2;

    modifier OnlyGrantedAccess() {
        AccessControlLib.isAccessGrantedToVault(msg.sender);
        _;
    }

    error NoSharesToRedeem();
    error NoSharesToMint();
    error NoAssetsToWithdraw();
    error NoAssetsToDeposit();
    error InvalidAlpha();
    error UnsupportedFuse();

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);

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

    uint256 public immutable BASE_CURRENCY_DECIMALS;

    /// @param initialOwner Address of the owner
    /// @param assetName Name of the asset
    /// @param assetSymbol Symbol of the asset
    /// @param underlyingToken Address of the underlying token
    /// @param alphas Array of alphas initially granted to execute actions on the Plasma Vault
    /// @param marketSubstratesConfigs Array of market configurations
    /// @param fuses Array of fuses initially supported by the Plasma Vault
    /// @param balanceFuses Array of balance fuses initially supported by the Plasma Vault
    /// @param feeConfig Fee configuration, performance fee and management fee, with fee managers addresses
    constructor(
        address initialOwner,
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        address iporPriceOracle,
        address[] memory alphas,
        MarketSubstratesConfig[] memory marketSubstratesConfigs,
        address[] memory fuses,
        MarketBalanceFuseConfig[] memory balanceFuses,
        FeeConfig memory feeConfig
    )
        ERC4626Permit(IERC20(underlyingToken))
        ERC20Permit(assetName)
        ERC20(assetName, assetSymbol)
        Ownable(initialOwner)
    {
        IIporPriceOracle priceOracle = IIporPriceOracle(iporPriceOracle);

        if (priceOracle.BASE_CURRENCY() != USD) {
            revert Errors.UnsupportedBaseCurrencyFromOracle(Errors.UNSUPPORTED_BASE_CURRENCY);
        }

        BASE_CURRENCY_DECIMALS = priceOracle.BASE_CURRENCY_DECIMALS();

        PlasmaVaultLib.setPriceOracle(iporPriceOracle);

        for (uint256 i; i < alphas.length; ++i) {
            _grantAlpha(alphas[i]);
        }

        for (uint256 i; i < fuses.length; ++i) {
            _addFuse(fuses[i]);
        }

        for (uint256 i; i < balanceFuses.length; ++i) {
            _addBalanceFuse(balanceFuses[i].marketId, balanceFuses[i].fuse);
        }

        for (uint256 i; i < marketSubstratesConfigs.length; ++i) {
            PlasmaVaultConfigLib.grandMarketSubstrates(
                marketSubstratesConfigs[i].marketId,
                marketSubstratesConfigs[i].substrates
            );
        }

        PlasmaVaultLib.configurePerformanceFee(feeConfig.performanceFeeManager, feeConfig.performanceFeeInPercentage);
        PlasmaVaultLib.configureManagementFee(feeConfig.managementFeeManager, feeConfig.managementFeeInPercentage);

        PlasmaVaultLib.updateManagementFeeData();
    }

    receive() external payable {}

    fallback() external {
        ///TODO: read msg.sender (if Morpho) and read method signature to determine fuse address to execute
        /// delegate call on method onMorphoFlashLoan
        /// separate contract with configuration which fuse use which flashloan method and protocol
    }

    /// @notice Execute multiple FuseActions by a Alpha. Any FuseAction is moving funds between markets and vault. Fuse Action not consider deposit and withdraw from Vault.
    function execute(FuseAction[] calldata calls) external {
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

    /// @notice Returns the total assets in the vault
    /// @dev value not take into account runtime accrued interest in the markets, and NOT take into account runtime accrued management fee
    /// @return total assets in the vault, represented in underlying token decimals
    function totalAssets() public view virtual override returns (uint256) {
        uint256 totalAssetsWithoutUnrealizedManagementFee = _getTotalAssetsWithoutUnrealizedManagementFee();
        return
            totalAssetsWithoutUnrealizedManagementFee -
            _getUnrealizedManagementFee(totalAssetsWithoutUnrealizedManagementFee);
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
        return _getUnrealizedManagementFee(_getTotalAssetsWithoutUnrealizedManagementFee());
    }

    function deposit(uint256 assets, address receiver) public override OnlyGrantedAccess returns (uint256) {
        if (assets == 0) {
            revert NoAssetsToDeposit();
        }
        if (receiver == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override OnlyGrantedAccess returns (uint256) {
        if (shares == 0) {
            revert NoSharesToMint();
        }
        if (receiver == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
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

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
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

    function isAlphaGranted(address alpha) external view returns (bool) {
        return AlphasLib.isAlphaGranted(alpha);
    }

    function isMarketSubstrateGranted(uint256 marketId, bytes32 substrate) external view returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId, substrate);
    }

    function isFuseSupported(address fuse) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse);
    }

    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId, fuse);
    }

    function getFuses() external view returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    function isAccessControlActivated() external view returns (bool) {
        return AccessControlLib.isControlAccessActivated();
    }

    function getPriceOracle() external view returns (address) {
        return PlasmaVaultLib.getPriceOracle();
    }

    function getPerformanceFeeData() external view returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData) {
        feeData = PlasmaVaultLib.getPerformanceFeeData();
    }

    function getManagementFeeData() external view returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData) {
        feeData = PlasmaVaultLib.getManagementFeeData();
    }

    function grantAlpha(address alpha) external onlyOwner {
        if (alpha == address(0)) {
            revert Errors.WrongAddress();
        }
        _grantAlpha(alpha);
    }

    function revokeAlpha(address alpha) external onlyOwner {
        if (alpha == address(0)) {
            revert Errors.WrongAddress();
        }
        AlphasLib.revokeAlpha(alpha);
    }

    function addFuse(address fuse) external onlyOwner {
        _addFuse(fuse);
    }

    function removeFuse(address fuse) external onlyOwner {
        if (fuse == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.removeFuse(fuse);
    }

    function addBalanceFuse(uint256 marketId, address fuse) external onlyOwner {
        _addBalanceFuse(marketId, fuse);
    }

    function removeBalanceFuse(uint256 marketId, address fuse) external onlyOwner {
        FusesLib.removeBalanceFuse(marketId, fuse);
    }

    function grandMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external onlyOwner {
        PlasmaVaultConfigLib.grandMarketSubstrates(marketId, substrates);
    }

    function updateInstantWithdrawalFuses(
        PlasmaVaultLib.InstantWithdrawalFusesParamsStruct[] calldata fuses
    ) external onlyOwner {
        PlasmaVaultLib.updateInstantWithdrawalFuses(fuses);
    }

    function addFuses(address[] calldata fuses) external onlyOwner {
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.addFuse(fuses[i]);
        }
    }

    function removeFuses(address[] calldata fuses) external onlyOwner {
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.removeFuse(fuses[i]);
        }
    }

    function activateAccessControl() external onlyOwner {
        AccessControlLib.activateAccessControl();
    }

    function grantAccessToVault(address account) external onlyOwner {
        AccessControlLib.grantAccessToVault(account);
    }

    function revokeAccessToVault(address account) external onlyOwner {
        AccessControlLib.revokeAccessToVault(account);
    }

    function deactivateAccessControl() external onlyOwner {
        AccessControlLib.deactivateAccessControl();
    }

    function setPriceOracle(address priceOracle) external onlyOwner {
        IIporPriceOracle oldPriceOracle = IIporPriceOracle(PlasmaVaultLib.getPriceOracle());
        IIporPriceOracle newPriceOracle = IIporPriceOracle(priceOracle);
        if (
            oldPriceOracle.BASE_CURRENCY() != newPriceOracle.BASE_CURRENCY() ||
            oldPriceOracle.BASE_CURRENCY_DECIMALS() != newPriceOracle.BASE_CURRENCY_DECIMALS()
        ) {
            revert Errors.UnsupportedPriceOracle(Errors.PRICE_ORACLE_ERROR);
        }

        PlasmaVaultLib.setPriceOracle(priceOracle);
    }

    function configurePerformanceFee(address feeManager, uint256 feeInPercentage) external onlyOwner {
        PlasmaVaultLib.configurePerformanceFee(feeManager, feeInPercentage);
    }

    function configureManagementFee(address feeManager, uint256 feeInPercentage) external onlyOwner {
        PlasmaVaultLib.configureManagementFee(feeManager, feeInPercentage);
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

    function _addFuse(address fuse) internal {
        if (fuse == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addFuse(fuse);
    }

    function _addBalanceFuse(uint256 marketId, address fuse) internal {
        if (fuse == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addBalanceFuse(marketId, fuse);
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

    function _grantAlpha(address alpha) internal {
        if (alpha == address(0)) {
            revert InvalidAlpha();
        }

        AlphasLib.grantAlpha(alpha);
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

    function _getTotalAssetsWithoutUnrealizedManagementFee() internal view returns (uint256) {
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
}
