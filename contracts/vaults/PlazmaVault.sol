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
import {AccessControlLib} from "../libraries/AccessControlLib.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {MarketConfigurationLib} from "../libraries/MarketConfigurationLib.sol";
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

        //TODO: validations supported assets are supported by fuses
        for (uint256 i; i < fuses.length; ++i) {
            FusesLib.addFuse(fuses[i]);
        }

        //TODO: validations supported assets are supported by fuses
        for (uint256 i; i < balanceFuses.length; ++i) {
            FusesLib.setBalanceFuse(balanceFuses[i].marketId, balanceFuses[i].fuse);
        }

        for (uint256 i; i < marketSubstratesConfigs.length; ++i) {
            MarketConfigurationLib.grandSubstratesToMarket(
                marketSubstratesConfigs[i].marketId,
                marketSubstratesConfigs[i].substrates
            );
        }

        ///TODO: when adding new fuse - then validate if fuse support assets defined for a given Plazma Vault.
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

    function execute(FuseAction[] calldata calls) external {
        uint256 callsCount = calls.length;

        //TODO: move to transient storage
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex = 0;

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

        _updateBalances(markets);
    }

    function grantAlpha(address alpha) external onlyOwner {
        _grantAlpha(alpha);
    }

    function revokeAlpha(address alpha) external onlyOwner {
        AlphasLib.revokeAlpha(alpha);
    }

    function isAlphaGranted(address alpha) external view returns (bool) {
        return AlphasLib.isAlphaGranted(alpha);
    }

    function addFuse(address fuse) external onlyOwner {
        FusesLib.addFuse(fuse);
    }

    function removeFuse(address fuse) external onlyOwner {
        FusesLib.removeFuse(fuse);
    }

    function isFuseSupported(address fuse) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse);
    }

    function isBalanceFuseSupported(uint256 marketId, address fuse) external view returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId, fuse);
    }

    function addBalanceFuse(MarketBalanceFuseConfig memory fuseInput) external onlyOwner {
        FusesLib.setBalanceFuse(fuseInput.marketId, fuseInput.fuse);
    }

    function removeBalanceFuse(MarketBalanceFuseConfig memory fuseInput) external onlyOwner {
        FusesLib.removeBalanceFuse(fuseInput.marketId, fuseInput.fuse);
    }

    /// @notice Update balances in the vault for markets touched by the fuses during the execution of all FuseActions
    /// @param markets Array of market ids touched by the fuses in the FuseActions
    function _updateBalances(uint256[] memory markets) internal {
        int256 deltasInUnderlying = 0;
        uint256 wadBalanceAmountInUSD;
        address balanceFuse;

        /// @dev USD price is represented in 8 decimals
        uint256 underlyingAssetPrice = PRICE_ORACLE.getAssetPrice(asset());

        for (uint256 i; i < markets.length; ++i) {
            if (markets[i] == 0) {
                break;
            }

            balanceFuse = FusesLib.getMarketBalanceFuse(markets[i]);

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
            PlazmaVaultLib.addToTotalAssetsInMarkets(deltasInUnderlying);
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
