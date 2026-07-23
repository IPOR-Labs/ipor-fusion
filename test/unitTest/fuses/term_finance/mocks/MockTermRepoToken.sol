// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockTermRepoToken is ERC20 {
    uint8 private immutable DECIMALS_VAL;
    uint256 public redemptionValue;
    bytes32 public termRepoId;
    bool public decimalsReverts;
    bool public redemptionValueReverts;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS_VAL = decimals_;
    }

    function decimals() public view override returns (uint8) {
        if (decimalsReverts) revert("MockTermRepoToken: decimals reverts");
        return DECIMALS_VAL;
    }

    function setRedemptionValue(uint256 v_) external {
        redemptionValue = v_;
    }

    function setDecimalsReverts(bool r_) external {
        decimalsReverts = r_;
    }

    function setRedemptionValueReverts(bool r_) external {
        redemptionValueReverts = r_;
    }

    function setTermRepoId(bytes32 id_) external {
        termRepoId = id_;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function burn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }

    function exposedRedemptionValue() external view returns (uint256) {
        if (redemptionValueReverts) revert("MockTermRepoToken: redemptionValue reverts");
        return redemptionValue;
    }
}
