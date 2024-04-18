// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC4626Permit} from "../tokens/ERC4626/ERC4626Permit.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {AlphasLib} from "../libraries/AlphasLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {PlazmaVaultConfigLib} from "../libraries/PlazmaVaultConfigLib.sol";
import {PlazmaVaultLib} from "../libraries/PlazmaVaultLib.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {IIporPriceOracle} from "../priceOracle/IIporPriceOracle.sol";
import {Errors} from "../libraries/errors/Errors.sol";

contract PlazmaVault is ERC4626Permit, Ownable2Step {
    using Address for address;

    address private constant USD = address(0x0000000000000000000000000000000000000348);

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
        MarketBalanceFuseConfig[] memory balanceFuses
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

        ///TODO: when adding new fuse - then validate if fuse support assets defined for a given Plazma Vault.
    }

    function execute(FuseAction[] calldata calls) external {
        uint256 callsCount = calls.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

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

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        uint256 currentBalanceUnderlying = IERC20(asset()).balanceOf(address(this));

        uint256 left;

        if (assets >= currentBalanceUnderlying) {
            uint256 marketIndex;
            uint256 fuseMarketId;

            bytes32[] memory params;

            /// @dev assume that the same fuse can be used multiple times
            /// @dev assume that more than one fuse can be from the same market
            address[] memory fuses = PlazmaVaultLib.getInstantWithdrawalFuses();

            uint256[] memory markets = new uint256[](fuses.length);

            left = assets - currentBalanceUnderlying;

            for (uint256 i; left != 0 && i < fuses.length; ++i) {
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

        assets = assets - left;
        shares = previewWithdraw(assets);

        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Update balances in the vault for markets touched by the fuses during the execution of all FuseActions
    /// @param markets Array of market ids touched by the fuses in the FuseActions
    function _updateMarketsBalances(uint256[] memory markets) internal {
        int256 deltasInUnderlying = 0;
        uint256 wadBalanceAmountInUSD;
        address balanceFuse;

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
                        IporMath.division(wadBalanceAmountInUSD * underlyingAssetPrice, 10 ** BASE_CURRENCY_DECIMALS),
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

    function _checkIfExistsMarket(uint256[] memory markets, uint256 marketId) internal view returns (bool exists) {
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
}
