// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title NapierConstants
/// @notice Library containing Napier V2 Core and Periphery addresses
/// @dev Contains constant addresses used in Napier tests, organized by chain
library NapierConstants {
    ///  Napier V2 Core - Arbitrum Network
    address public constant ARB_NAPIER_FACTORY = 0x0000001afbCA1E8CF82fe458B33C9954A65b987B;
    address public constant ARB_PT_BLUEPRINT = 0xd504C5c66ffd1cA0a58a2E17f147552808c07d77;
    address public constant ARB_ERC4626_RESOLVER_BLUEPRINT = 0x067eEfB72007dde6F87514D061889D411648Aa78;
    address public constant ARB_ACCESS_MANAGER_IMPLEMENTATION = 0x1775eb30212734a02B4C6709C98eBdC88Be26cb8;
    address public constant ARB_FEE_MODULE_IMPLEMENTATION = 0xB6A7f2ff3AA790A15841E8D785f5828952ead723;
    address public constant ARB_POOL_FEE_MODULE_IMPLEMENTATION = 0xE80f04F51EDc3d0680C1B428eB7d54B8FE9540E1;

    // Napier V2 Toki pool implementation - Arbitrum Network
    address public constant ARB_TOKI_POOL_DEPLOYER_IMPLEMENTATION = 0x3333fa2BEd91533D8Fe0F1B641582343A8529469;
    address public constant ARB_LIQUIDITY_TOKEN_IMPLEMENTATION = 0xcdE671cee0A17cb4c5c5d546B8724Cbac7d87A1D;
    address public constant ARB_TOKI_HOOK = 0x9aDec457F6992193731e605B53115261bA6a1888;

    ///  Napier V2 Periphery - Arbitrum Network
    address public constant ARB_UNIVERSAL_ROUTER = 0x000000d8B6Fb27de7229923DB7649e50DC5937e8;
    address public constant ARB_TOKI_ORACLE = 0xe9aa72336E86Abcf572356823b4db70e26539fe8;
    address public constant ARB_CHAINLINK_COMPT_ORACLE_FACTORY = 0x00000013f81B2e719d7183CFDd9f0e46CFbC8564;
    address public constant ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL = 0x0615eda12810C18E5B5382661e9e118880e18B85;
    address public constant ARB_TOKI_TWAP_ORACLE_IMPL = 0x3c1f9Df2f1C58CeEF741A0BC4b916Be32465EC3c;
}
