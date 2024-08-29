// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/ERC20Capped.sol)

pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";

/**
 * @dev Extension of {ERC20} that adds a cap to the supply of tokens.
 * Modified for Plasma Vaults purposes.
 */
abstract contract ERC20CappedUpgradeable is Initializable, ERC20Upgradeable {
    /**
     * @dev Total supply cap has been exceeded.
     */
    error ERC20ExceededCap(uint256 increasedSupply, uint256 cap);

    /**
     * @dev The supplied cap is not a valid cap.
     */
    error ERC20InvalidCap(uint256 cap);

    /**
     * @dev Sets the value of the `cap`. This value is immutable, it can only be
     * set once during construction.
     */
    function __ERC20Capped_init(uint256 cap_) internal onlyInitializing {
        // solhint-disable-previous-line func-name-mixedcase
        __ERC20Capped_init_unchained(cap_);
    }

    function __ERC20Capped_init_unchained(uint256 cap_) internal onlyInitializing {
        // solhint-disable-previous-line func-name-mixedcase
        PlasmaVaultStorageLib.ERC20CappedStorage storage $ = PlasmaVaultStorageLib.getERC20CappedStorage();
        if (cap_ == 0) {
            revert ERC20InvalidCap(0);
        }
        $.cap = cap_;
    }

    /**
     * @dev Returns the cap on the token's total supply.
     */
    function cap() public view virtual returns (uint256) {
        PlasmaVaultStorageLib.ERC20CappedStorage storage $ = PlasmaVaultStorageLib.getERC20CappedStorage();
        return $.cap;
    }

    /// @notice Customized update, only total supply cap check. Method not updated for total supply and balance.
    function _update(address from_, address, uint256) internal virtual override {
        if (from_ == address(0)) {
            uint256 maxSupply = cap();
            uint256 supply = totalSupply();
            if (supply > maxSupply) {
                revert ERC20ExceededCap(supply, maxSupply);
            }
        }
    }
}
