// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockRemoteVault} from "./MockRemoteVault.sol";
import {TrackedVaultPricingLib} from "../../../contracts/crosschain/lib/TrackedVaultPricingLib.sol";

/// @title MockFaultyVault
/// @notice `MockRemoteVault` whose `balanceOf` / `convertToAssets` can be switched to revert (IL-8602), or to return
///         a payload shorter than a word. IL-8784 adds `redeem` / `maxRedeem` faults for the removal sweep.
contract MockFaultyVault is MockRemoteVault {
    bool public balanceReverts;
    bool public convertReverts;
    bool public shortReturn;
    bool public assetReverts;
    bool public burnsGas;
    bool public convertReturnsMax;
    /// @dev IL-8645: when non-zero, `asset()` reports this token instead (an upgradeable vault changed its asset).
    address public driftedAsset;

    /// @dev IL-8784: `redeem` reverts with `RedeemBroken()`.
    error RedeemBroken();

    bool public redeemReverts;
    bool public redeemBurnsGas;
    bool public redeemReturnsEmpty;
    bool public redeemBombs;
    bool public maxRedeemReverts;
    bool public maxRedeemCapped;
    uint256 public maxRedeemCap;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockRemoteVault(asset_, name_, symbol_) {}

    function setFaults(bool balanceReverts_, bool convertReverts_, bool shortReturn_) external {
        balanceReverts = balanceReverts_;
        convertReverts = convertReverts_;
        shortReturn = shortReturn_;
    }

    /// @dev Extra faults: `asset()` reverts, and every read burns all forwarded gas (infinite loop).
    function setExtraFaults(bool assetReverts_, bool burnsGas_) external {
        assetReverts = assetReverts_;
        burnsGas = burnsGas_;
    }

    /// @dev `convertToAssets` returns type(uint256).max (above the dispatcher's uint128 bound).
    function setConvertReturnsMax(bool convertReturnsMax_) external {
        convertReturnsMax = convertReturnsMax_;
    }

    /// @dev IL-8784 redeem faults: revert with a custom error, burn all forwarded gas, succeed with empty returndata,
    ///      or revert with a 200 kB returndata bomb.
    function setRedeemFaults(bool reverts_, bool burnsGas_, bool returnsEmpty_, bool bombs_) external {
        redeemReverts = reverts_;
        redeemBurnsGas = burnsGas_;
        redeemReturnsEmpty = returnsEmpty_;
        redeemBombs = bombs_;
    }

    /// @dev IL-8784: `maxRedeem` reverts, or is capped at `cap_`.
    function setMaxRedeemFaults(bool reverts_, bool capped_, uint256 cap_) external {
        maxRedeemReverts = reverts_;
        maxRedeemCapped = capped_;
        maxRedeemCap = cap_;
    }

    /// @dev True while `redeem` runs, so the OpenZeppelin `maxRedeem` self-check inside it ignores `maxRedeemReverts`.
    bool private _redeeming;

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (maxRedeemReverts && !_redeeming) revert("maxRedeem broken");
        uint256 max = super.maxRedeem(owner_);
        return maxRedeemCapped && maxRedeemCap < max ? maxRedeemCap : max;
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        if (redeemBurnsGas) {
            while (true) {}
        }
        if (redeemBombs) {
            assembly {
                revert(0, 200000)
            }
        }
        if (redeemReverts) revert RedeemBroken();
        _redeeming = true;
        uint256 assets = super.redeem(shares_, receiver_, owner_);
        _redeeming = false;
        if (redeemReturnsEmpty) {
            assembly {
                return(0, 0)
            }
        }
        return assets;
    }

    function setDriftedAsset(address driftedAsset_) external {
        driftedAsset = driftedAsset_;
    }

    function asset() public view override returns (address) {
        if (assetReverts) revert("asset broken");
        if (driftedAsset != address(0)) return driftedAsset;
        return super.asset();
    }

    function _burn() private view {
        if (burnsGas) {
            while (true) {}
        }
    }

    function balanceOf(address account_) public view override(IERC20, ERC20) returns (uint256) {
        _burn();
        if (balanceReverts) revert("balanceOf broken");
        if (shortReturn) {
            assembly {
                mstore(0, 0x01)
                return(0, 4)
            }
        }
        return super.balanceOf(account_);
    }

    function convertToAssets(uint256 shares_) public view override returns (uint256) {
        _burn();
        if (convertReverts) revert("convertToAssets broken");
        if (convertReturnsMax) return type(uint256).max;
        return super.convertToAssets(shares_);
    }
}

/// @notice Exposes the internal pricing library so its gas pre-check can be driven with an explicit gas limit.
contract TrackedVaultPricingHarness {
    function read(address vault_, address holder_) external view returns (bool ok, uint256 amount) {
        return TrackedVaultPricingLib.shares(vault_, holder_);
    }
}
