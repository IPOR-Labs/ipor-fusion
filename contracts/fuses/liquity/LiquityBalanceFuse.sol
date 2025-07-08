// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";

import {console2} from "forge-std/console2.sol";

/// @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
contract LiquityBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    uint256 private constant LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS = 18;

    error InvalidMarketId();
    error InvalidRegistry();

    constructor(uint256 marketId) {
        if (marketId != IporFusionMarkets.LIQUITY_V2) revert InvalidMarketId();

        MARKET_ID = marketId;
    }

    // The balance is composed of the value of the Plasma Vault in USD
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = registriesRaw.length;

        if (len == 0) return 0;

        int256 collBalance;
        uint256 totalDeposits;
        uint256 lastGoodPrice;
        address plasmaVault = address(this);
        IAddressesRegistry registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[0]));

        // loop through all registries to calculate stashed collateral and deposits
        for (uint256 i = 0; i < len; ++i) {
            // avoid reassigning the registry if it is the same as the previous one
            if (i > 0) registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]));

            IStabilityPool stabilityPool;
            try registry.stabilityPool() returns (address pool) {
                stabilityPool = IStabilityPool(pool);
            } catch {
                // this registry does not have a stability pool, so we skip it
                continue;
            }

            lastGoodPrice = IPriceFeed(registry.priceFeed()).lastGoodPrice();
            if (lastGoodPrice == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }

            // The stashed collateral in the stability pool, i.e. not yet claimed
            // They are denominated in the collateral token, so we need to convert them to BOLD
            int256 stashedCollateral = int256(stabilityPool.stashedColl(plasmaVault));
            if (stashedCollateral > 0) {
                collBalance += IporMath.convertToWadInt(
                    stashedCollateral * int256(lastGoodPrice),
                    IERC20Metadata(registry.collToken()).decimals() + LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS
                );
            }

            // the deposits are added to the balance: they are denominated in BOLD, so no need to convert
            totalDeposits += stabilityPool.deposits(plasmaVault);
        }

        return collBalance.toUint256() + totalDeposits;
    }
}
