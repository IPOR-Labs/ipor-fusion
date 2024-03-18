// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IConnectorCommon} from "./IConnectorCommon.sol";

interface IConnector is IConnectorCommon {
    function enter(bytes calldata data) external returns (bytes memory executionStatus);

    function exit(bytes calldata data) external returns (bytes memory executionStatus);

    /// Vault details:
    /// - has a list of connectors
    /// - Vault is a ERC-4626
    /// - Vault is working like a Router, connectors are like stateless Services
    /// - DEBT is on a Vault not on a specific connector
    /// - One connector can be used in many Vaults

    //// Connector responsible for
    /// - a specific action in a specific protocol
    /// - connector can be treated as a one specific command with REVERT action

    /// Connector types
    /// 1 - Borrow connectors
    /// 2 - Supply connectors
    /// 3 - Balance connectors
    /// 4 - FlashLoan connectors
    /// 5 - Swap connectors

    /// Scenario:
    /// 1 FlashLoan on Morpho - 100 wstETH
    /// 2. Inside flashloan action - execute 3 actions
    /// 3. 1 - AaveV3SupplyConnector - 40 wstETH
    /// 4. 2 - AaveV3BorrowConnector - 30 wETH
    /// 5. 3 - Native Swap wETH to wstETH - 30 wstETH - required to repay flashloan

    /// UPDATE Vault Balance -  algorithm
    /// 1 - for a given asset check supply in external protocol
    /// 2 - for a given asset check borrow in external protocol
    /// 3 - for a given asset check fee in external protocol
    /// 4 - supply - borrow - fee = balance in a given asset
    /// 5 - calculate balance in given asset to value in undelying asset in Vault
    /// 6 - update in Vault balance for a given asset and connet

    // benefits
    /// 1. IPOR keeper can work on different vaults
    /// 2. New abstraction layer - simplification
    /// 3. Competition between keepers
    /// 4. Lightweigth ERC4626
    /// 5. Developer engagement
    /// 6. Solve Asset Management in IPOR
    /// 7. Flashloan on Vault
}
