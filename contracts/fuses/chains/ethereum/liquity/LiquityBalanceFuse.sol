// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMarketBalanceFuse} from "../../../IMarketBalanceFuse.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";

/// @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
contract LiquityBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    uint256 private constant LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS = 18;
    error InvalidRegistry();

    // We fix only one registry for each vault, to allow more granularity
    IAddressesRegistry public immutable registry;
    IStabilityPool public immutable stabilityPool;
    IERC20Metadata public immutable collateralToken;
    IPriceFeed public immutable priceFeed;
    uint256 public immutable collTokenDecimals;
    IERC20Metadata public immutable boldToken;

    constructor(uint256 marketId, address _registry) {
        MARKET_ID = marketId;
        registry = IAddressesRegistry(_registry);
        stabilityPool = registry.stabilityPool();
        collateralToken = registry.collToken();
        priceFeed = registry.priceFeed();
        collTokenDecimals = collateralToken.decimals();
        boldToken = IERC20Metadata(registry.boldToken());
    }

    // The balance is composed of the value of the Plasma Vault in USD
    // The Plasma Vault can contain BOLD (former LUSD), WETH, wstETH, and rETH
    function balanceOf() external view override returns (uint256) {
        int256 collBalanceTemp;
        uint256 lastGoodPrice;
        address plasmaVault = address(this);

        // BOLD token is the same for all registries, so we can get it from the first one
        uint256 boldBalance = boldToken.balanceOf(plasmaVault);

        lastGoodPrice = priceFeed.lastGoodPrice();
        if (lastGoodPrice == 0) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }
        int256 stashedCollateral = int256(stabilityPool.stashedColl(plasmaVault));
        if (stashedCollateral > 0) {
            collBalanceTemp = IporMath.convertToWadInt(
                stashedCollateral * int256(lastGoodPrice),
                collTokenDecimals + LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS
            );
        }

        return collBalanceTemp.toUint256() + boldBalance + stabilityPool.deposits(plasmaVault);
    }
}
