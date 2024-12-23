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
    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address public constant BASE_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address public constant BASE_WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address public constant BASE_CBETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;

    address public constant BASE_UNIVERSAL_ROUTER_UNISWAP = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;
    address public constant BASE_MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    address public constant BASE_MOONWELL_COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;

    // Oracle Addresses - Base Network
    address public constant BASE_CHAINLINK_ETH_PRICE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address public constant BASE_CHAINLINK_USDC_PRICE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address public constant BASE_CHAINLINK_CBBTC_PRICE = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address public constant BASE_CHAINLINK_CBETH_PRICE = 0xd7818272B9e248357d13057AAb0B417aF31E817d;
    address public constant BASE_CHAINLINK_WSTETH_TO_ETH_PRICE = 0x43a5C292A453A3bF3606fa856197f09D7B74251a;

    // Morpho Market IDs - Base Network
    bytes32 public constant BASE_MORPHO_WETH_USDC_MARKET_ID =
        0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda;

    // Moonwell Addresses - Base Network
    address public constant BASE_M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address public constant BASE_M_CBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;
    address public constant BASE_M_WSTETH = 0x627Fe393Bc6EdDA28e99AE648fD6fF362514304b;
    address public constant BASE_M_CBETH = 0x3bf93770f2d4a794c3d9EBEfBAeBAE2a8f09A5E5;

    // Protocol Addresses - Arbitrum Network
    address public constant ARB_WST_ETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address public constant ARBITRUM_PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address public constant ARBITRUM_PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
}
