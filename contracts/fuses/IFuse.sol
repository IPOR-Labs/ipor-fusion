// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IFuseCommon} from "./IFuseCommon.sol";

interface IFuse is IFuseCommon {
    function enter(bytes calldata data) external;

    function exit(bytes calldata data) external;

    /// Vault details:
    /// - has a list of fuses
    /// - Vault is a ERC-4626
    /// - Vault is working like a Router, fuses are like stateless Services
    /// - DEBT is on a Vault not on a specific fuse
    /// - One fuse can be used in many Vaults

    //// Fuse responsible for
    /// - a specific action in a specific protocol
    /// - fuse can be treated as a one specific command with REVERT action

    /// Fuse types
    /// 1 - Borrow fuses
    /// 2 - Supply fuses
    /// 3 - Balance fuses
    /// 4 - FlashLoan fuses
    /// 5 - Swap fuses

    /// Scenario:
    /// 1 FlashLoan on Morpho - 100 wstETH
    /// 2. Inside flashloan action - execute 3 actions
    /// 3. 1 - AaveV3SupplyFuse - 40 wstETH
    /// 4. 2 - AaveV3BorrowFuse - 30 wETH
    /// 5. 3 - Native Swap wETH to wstETH - 30 wstETH - required to repay flashloan

    /// UPDATE Vault Balance -  algorithm
    /// 1 - for a given asset check supply in external protocol
    /// 2 - for a given asset check borrow in external protocol
    /// 3 - for a given asset check fee in external protocol
    /// 4 - supply - borrow - fee = balance in a given asset
    /// 5 - calculate balance in given asset to value in undelying asset in Vault
    /// 6 - update in Vault balance for a given asset and connet

    // benefits
    /// 1. IPOR alpha can work on different vaults
    /// 2. New abstraction layer - simplification
    /// 3. Competition between alphas
    /// 4. Lightweigth ERC4626
    /// 5. Developer engagement
    /// 6. Solve Asset Management in IPOR
    /// 7. Flashloan on Vault
}
