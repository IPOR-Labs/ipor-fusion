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
import "./LiquityConstants.sol";

contract LiquityBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    uint256 private constant LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS = 18;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    // The balance is composed of the value of the Plasma Vault in USD
    // The Plasma Vault can contain BOLD (former LUSD), ETH, wstETH, and rETH
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory assetsRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = assetsRaw.length;

        if (len == 0) return 0;

        address[3] memory registries = [
            LiquityConstants.LIQUITY_ETH_ADDRESSES_REGISTRY,
            LiquityConstants.LIQUITY_WSTETH_ADDRESSES_REGISTRY,
            LiquityConstants.LIQUITY_RETH_ADDRESSES_REGISTRY
        ];

        int256 balanceTemp;
        uint256 lastGoodPrice;
        IPriceFeed priceFeed;
        address plasmaVault = address(this);

        uint256 boldBalance = IERC20Metadata(LiquityConstants.LIQUITY_BOLD).balanceOf(plasmaVault);

        for (uint256 i; i < len; ++i) {
            address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetsRaw[i]);
            priceFeed = IAddressesRegistry(registries[i]).priceFeed();
            lastGoodPrice = priceFeed.lastGoodPrice();
            if (lastGoodPrice == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }
            uint256 decimals = IERC20Metadata(asset).decimals();
            int256 balance = int256(IERC20Metadata(asset).balanceOf(plasmaVault));
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
