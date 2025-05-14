// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMarketBalanceFuse} from "../../IMarketBalanceFuse.sol";
import {Errors} from "../../../libraries/errors/Errors.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IporMath} from "../../../libraries/math/IporMath.sol";

/// @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
contract LiquityBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    uint256 private constant LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS = 18;

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    // The balance is composed of the value of the Plasma Vault in USD
    // The Plasma Vault can contain BOLD (former LUSD), ETH, wstETH, and rETH
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = registriesRaw.length;

        if (len == 0) return 0;

        int256 balanceTemp;
        uint256 lastGoodPrice;
        IPriceFeed priceFeed;
        address plasmaVault = address(this);

        address boldToken = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[0])).boldToken();
        uint256 boldBalance = IERC20Metadata(boldToken).balanceOf(plasmaVault);

        for (uint256 i; i < len; ++i) {
            address registry = PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]);
            IERC20Metadata token = IAddressesRegistry(registry).collToken();
            priceFeed = IAddressesRegistry(registry).priceFeed();
            lastGoodPrice = priceFeed.lastGoodPrice();
            if (lastGoodPrice == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }
            uint256 decimals = token.decimals();
            int256 balance = int256(token.balanceOf(plasmaVault));
            if (balance > 0) {
                balanceTemp += IporMath.convertToWadInt(
                    balance * int256(lastGoodPrice),
                    decimals + LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS
                );
            }
        }

        return balanceTemp.toUint256() + boldBalance;
    }
}
