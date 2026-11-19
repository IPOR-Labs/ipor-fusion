// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EVCUtil} from "ethereum-vault-connector/src/utils/EVCUtil.sol";

/// @title MockEvcVault
/// @notice ERC-4626 vault that authenticates its callers through the Ethereum Vault Connector, the way Euler EVK
///         vaults do: a call relayed by the EVC is treated as coming from the account the EVC authenticated
///         (`EVCUtil._msgSender`). It passes the dispatchers' admission check (`code` + `asset()`), so it can be
///         allowlisted and tracked (IL-9654).
/// @dev 1:1 asset:share (no offset), like `MockRemoteVault`.
contract MockEvcVault is ERC4626, EVCUtil {
    constructor(IERC20 asset_, address evc_) ERC4626(asset_) ERC20("EVC Vault", "eVLT") EVCUtil(evc_) {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    function _msgSender() internal view override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }
}
