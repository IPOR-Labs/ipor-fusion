// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title TestAddresses
/// @notice Library containing common test addresses
/// @dev Contains constant addresses used across tests
library TestAddresses {
    // Role Addresses
    address public constant DAO = address(1111111);
    address public constant OWNER = address(2222222);
    address public constant ADMIN = address(3333333);
    address public constant ATOMIST = address(4444444);
    address public constant ALPHA = address(5555555);
    address public constant USER = address(6666666);
    address public constant GUARDIAN = address(7777777);
    address public constant FUSE_MANAGER = address(8888888);
    address public constant CLAIM_REWARDS = address(7777777);
    address public constant TRANSFER_REWARDS_MANAGER = address(8888888);
    address public constant CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER = address(9999999);

    // Protocol Addresses - Base Network
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant DAI = 0x73b06D8d18De422E269645eaCe15400DE7462417;

    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNIVERSAL_ROUTER_UNISWAP = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address public constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Oracle Addresses - Base Network
    address public constant CHAINLINK_ETH_PRICE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address public constant CHAINLINK_USDC_PRICE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    // Morpho Market IDs - Base Network
    bytes32 public constant MORPHO_WETH_USDC_MARKET_ID =
        0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda;

    // Moonwell Addresses - Base Network
    address public constant M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
}
