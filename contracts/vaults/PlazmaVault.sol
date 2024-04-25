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
import {PlazmaVaultConfigLib} from "../libraries/PlazmaVaultConfigLib.sol";
import {PlazmaVaultLib} from "../libraries/PlazmaVaultLib.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {IIporPriceOracle} from "../priceOracle/IIporPriceOracle.sol";
import {Errors} from "../libraries/errors/Errors.sol";

contract PlazmaVault is ERC4626Permit, Ownable2Step {
    using Address for address;
    using SafeCast for int256;

    address private constant USD = address(0x0000000000000000000000000000000000000348);
    uint256 public constant DEFAULT_SLIPPAGE_IN_PERCENTAGE = 2;

    error NoSharesToRedeem();
    error NoAssetsToWithdraw();

    //TODO: setup Vault type - required for fee

    struct FuseAction {
        address fuse;
        bytes data;
    }

    struct MarketBalanceFuseConfig {
        /// @dev When marketId is 0, then fuse is independent to a market - example flashloan fuse
        uint256 marketId;
        address fuse;
    }

    struct MarketSubstratesConfig {
        uint256 marketId;
        /// @dev it could be list of assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
        bytes32[] substrates;
    }

    IIporPriceOracle public immutable PRICE_ORACLE;
    uint256 public immutable BASE_CURRENCY_DECIMALS;

    address public dao;
    uint256 public performanceFeeInPercentage;

    error InvalidAlpha();
    error UnsupportedFuse();

    /// @param assetName Name of the asset
    /// @param assetSymbol Symbol of the asset
    /// @param underlyingToken Address of the underlying token
    /// @param alphas Array of alphas initially granted to execute actions on the Plazma Vault
    /// @param marketSubstratesConfigs Array of market configurations
    /// @param fuses Array of fuses
    /// @param balanceFuses Array of balance fuses
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
        address daoInput,
        uint256 performanceFeeInPercentageInput
    )
        ERC4626Permit(IERC20(underlyingToken))
        ERC20Permit(assetName)
        ERC20(assetName, assetSymbol)
        Ownable(initialOwner)
    {
        PRICE_ORACLE = IIporPriceOracle(iporPriceOracle);

        if (PRICE_ORACLE.BASE_CURRENCY() != USD) {
            revert Errors.UnsupportedBaseCurrencyFromOracle(Errors.UNSUPPORTED_BASE_CURRENCY);
        }

        BASE_CURRENCY_DECIMALS = PRICE_ORACLE.BASE_CURRENCY_DECIMALS();

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
            PlazmaVaultConfigLib.grandMarketSubstrates(
                marketSubstratesConfigs[i].marketId,
                marketSubstratesConfigs[i].substrates
            );
        }

        dao = daoInput;
        performanceFeeInPercentage = performanceFeeInPercentageInput;
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

        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter > totalAssetsBefore) {
            _calculateAndMintPerformanceFee(totalAssetsAfter - totalAssetsBefore);
        }
    }

    /// @notice Returns the total assets in the vault
    /// @return total assets in the vault, represented in underlying token decimals
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + PlazmaVaultLib.getTotalAssetsInAllMarkets();
    }

    /// @notice Returns the total assets in the vault for a specific market
    /// @param marketId The market id
    /// @return total assets in the vault for the market, represented in underlying token decimals
    function totalAssetsInMarket(uint256 marketId) public view virtual returns (uint256) {
        return PlazmaVaultLib.getTotalAssetsInMarket(marketId);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (assets == 0) {
            revert NoAssetsToWithdraw();
        }
        uint256 totalAssetsBefore = totalAssets();

        _withdrawFromMarkets(assets, IERC20(asset()).balanceOf(address(this)));

        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter > totalAssetsBefore) {
            _calculateAndMintPerformanceFee(totalAssetsAfter - totalAssetsBefore);
        }

        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (shares == 0) {
            revert NoSharesToRedeem();
        }

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

        assets = convertToAssets(shares);

        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter > totalAssetsBefore) {
            _calculateAndMintPerformanceFee(totalAssetsAfter - totalAssetsBefore);
        }

        return super.redeem(shares, receiver, owner);
    }

    function isAlphaGranted(address alpha) external view returns (bool) {
        return AlphasLib.isAlphaGranted(alpha);
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

    function isFuseSupported(address fuse) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse);
    }

    function getFuses() external view returns (address[] memory) {
        return FusesLib.getFusesArray();
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

    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId, fuse);
    }

    function addBalanceFuse(uint256 marketId, address fuse) external onlyOwner {
        _addBalanceFuse(marketId, fuse);
    }

    function removeBalanceFuse(uint256 marketId, address fuse) external onlyOwner {
        FusesLib.removeBalanceFuse(marketId, fuse);
    }

    function isMarketSubstrateGranted(uint256 marketId, bytes32 substrate) external view returns (bool) {
        return PlazmaVaultConfigLib.isMarketSubstrateGranted(marketId, substrate);
    }

    function grandMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external onlyOwner {
        PlazmaVaultConfigLib.grandMarketSubstrates(marketId, substrates);
    }

    function updateInstantWithdrawalFuses(
        PlazmaVaultLib.InstantWithdrawalFusesParamsStruct[] calldata fuses
    ) external onlyOwner {
        PlazmaVaultLib.updateInstantWithdrawalFuses(fuses);
    }

    function _calculateAndMintPerformanceFee(uint256 deltasInUnderlying) internal {
        uint256 fee = Math.mulDiv(deltasInUnderlying, performanceFeeInPercentage, 100);
        _mint(dao, convertToShares(fee));
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
            address[] memory fuses = PlazmaVaultLib.getInstantWithdrawalFuses();

            uint256[] memory markets = new uint256[](fuses.length);

            left = assets - vaultCurrentBalanceUnderlying;

            uint256 i;
            uint256 fusesLength = fuses.length;

            for (i; left != 0 && i < fusesLength; ++i) {
                params = PlazmaVaultLib.getInstantWithdrawalFusesParams(fuses[i], i);

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
        uint256 underlyingAssetPrice = PRICE_ORACLE.getAssetPrice(asset());

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
                PlazmaVaultLib.updateTotalAssetsInMarket(
                    markets[i],
                    IporMath.convertWadToAssetDecimals(
                        IporMath.division(wadBalanceAmountInUSD * 10 ** BASE_CURRENCY_DECIMALS, underlyingAssetPrice),
                        decimals()
                    )
                );
        }

        if (deltasInUnderlying != 0) {
            PlazmaVaultLib.addToTotalAssetsInAllMarkets(deltasInUnderlying);
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

    /// TODO: use in fuse when fuse configurator contract is ready
    //solhint-disable-next-line
    function onMorphoFlashLoan(uint256 flashLoanAmount, bytes calldata data) external payable {
        //        uint256 assetBalanceBeforeCalls = IERC20(WST_ETH).balanceOf(payable(this));

        FuseAction[] memory calls = abi.decode(data, (FuseAction[]));

        if (calls.length == 0) {
            return;
        }

        PlazmaVault(payable(this)).execute(calls);

        //        uint256 assetBalanceAfterCalls = IERC20(WST_ETH).balanceOf(payable(this));
    }

    receive() external payable {}

    fallback() external {
        ///TODO: read msg.sender (if Morpho) and read method signature to determine fuse address to execute
        /// delegate call on method onMorphoFlashLoan
        /// separate contract with configuration which fuse use which flashloan method and protocol
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

    function deposit(uint256 assets, address receiver) public override OnlyGrantedAccess returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override OnlyGrantedAccess returns (uint256) {
        return super.mint(shares, receiver);
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

    function isAccessControlActivated() external view returns (bool) {
        return AccessControlLib.isControlAccessActivated();
    }

    modifier OnlyGrantedAccess() {
        AccessControlLib.isAccessGrantedToVault(msg.sender);
        _;
    }
}
