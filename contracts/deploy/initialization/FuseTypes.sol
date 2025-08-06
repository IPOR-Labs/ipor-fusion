// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library FuseTypes {

    uint16 public constant AAVE_V2_BALANCE_FUSE_ID = 1;
    string public constant AAVE_V2_BALANCE_FUSE_NAME = "AAVE_V2_BALANCE_FUSE";

    uint16 public constant AAVE_V2_SUPPLY_FUSE_ID = 2;
    string public constant AAVE_V2_SUPPLY_FUSE_NAME = "AAVE_V2_SUPPLY_FUSE";

    uint16 public constant AAVE_V3_BALANCE_FUSE_ID = 3;
    string public constant AAVE_V3_BALANCE_FUSE_NAME = "AAVE_V3_BALANCE_FUSE";

    uint16 public constant AAVE_V3_SUPPLY_FUSE_ID = 4;
    string public constant AAVE_V3_SUPPLY_FUSE_NAME = "AAVE_V3_SUPPLY_FUSE";

    uint16 public constant AAVE_V3_BORROW_FUSE_ID = 5;
    string public constant AAVE_V3_BORROW_FUSE_NAME = "AAVE_V3_BORROW_FUSE";

    uint16 public constant BURN_REQUEST_FEE_FUSE_ID = 6;
    string public constant BURN_REQUEST_FEE_FUSE_NAME = "BURN_REQUEST_FEE_FUSE";

    uint16 public constant SPARK_BALANCE_FUSE_ID = 7;
    string public constant SPARK_BALANCE_FUSE_NAME = "SPARK_BALANCE_FUSE";

    uint16 public constant SPARK_SUPPLY_FUSE_ID = 8;
    string public constant SPARK_SUPPLY_FUSE_NAME = "SPARK_SUPPLY_FUSE";

    uint16 public constant COMPOUND_V2_BALANCE_FUSE_ID = 9;
    string public constant COMPOUND_V2_BALANCE_FUSE_NAME = "COMPOUND_V2_BALANCE_FUSE";

    uint16 public constant COMPOUND_V2_SUPPLY_FUSE_ID = 10;
    string public constant COMPOUND_V2_SUPPLY_FUSE_NAME = "COMPOUND_V2_SUPPLY_FUSE";

    uint16 public constant COMPOUND_V3_BALANCE_FUSE_ID = 11;
    string public constant COMPOUND_V3_BALANCE_FUSE_NAME = "COMPOUND_V3_BALANCE_FUSE";

    uint16 public constant COMPOUND_V3_SUPPLY_FUSE_ID = 12;
    string public constant COMPOUND_V3_SUPPLY_FUSE_NAME = "COMPOUND_V3_SUPPLY_FUSE";

    uint16 public constant COMPOUND_V3_CLAIM_FUSE_ID = 13;
    string public constant COMPOUND_V3_CLAIM_FUSE_NAME = "COMPOUND_V3_CLAIM_FUSE";

    uint16 public constant CURVE_CHILD_LIQUIDITY_GAUGE_BALANCE_FUSE_ID = 14;
    string public constant CURVE_CHILD_LIQUIDITY_GAUGE_BALANCE_FUSE_NAME = "CURVE_CHILD_LIQUIDITY_GAUGE_BALANCE_FUSE";

    uint16 public constant CURVE_CHILD_LIQUIDITY_GAUGE_SUPPLY_FUSE_ID = 15;
    string public constant CURVE_CHILD_LIQUIDITY_GAUGE_SUPPLY_FUSE_NAME = "CURVE_CHILD_LIQUIDITY_GAUGE_SUPPLY_FUSE";

    uint16 public constant CURVE_CHILD_LIQUIDITY_GAUGE_ERC4626_BALANCE_FUSE_ID = 16;
    string public constant CURVE_CHILD_LIQUIDITY_GAUGE_ERC4626_BALANCE_FUSE_NAME = "CURVE_CHILD_LIQUIDITY_GAUGE_ERC4626_BALANCE_FUSE";

    uint16 public constant CURVE_STABLESWAP_NG_SINGLE_SIDE_BALANCE_FUSE_ID = 17;
    string public constant CURVE_STABLESWAP_NG_SINGLE_SIDE_BALANCE_FUSE_NAME = "CURVE_STABLESWAP_NG_SINGLE_SIDE_BALANCE_FUSE";

    uint16 public constant CURVE_STABLESWAP_NG_SINGLE_SIDE_SUPPLY_FUSE_ID = 18;
    string public constant CURVE_STABLESWAP_NG_SINGLE_SIDE_SUPPLY_FUSE_NAME = "CURVE_STABLESWAP_NG_SINGLE_SIDE_SUPPLY_FUSE";

    uint16 public constant CURVE_GAUGE_TOKEN_CLAIM_FUSE_ID = 19;
    string public constant CURVE_GAUGE_TOKEN_CLAIM_FUSE_NAME = "CURVE_GAUGE_TOKEN_CLAIM_FUSE";

    uint16 public constant ERC20_BALANCE_FUSE_ID = 20;
    string public constant ERC20_BALANCE_FUSE_NAME = "ERC20_BALANCE_FUSE";

    uint16 public constant ERC4626_BALANCE_FUSE_ID = 21;
    string public constant ERC4626_BALANCE_FUSE_NAME = "ERC4626_BALANCE_FUSE";

    uint16 public constant ERC4626_SUPPLY_FUSE_ID = 22;
    string public constant ERC4626_SUPPLY_FUSE_NAME = "ERC4626_SUPPLY_FUSE";

    uint16 public constant EULER_V2_BALANCE_FUSE_ID = 23;
    string public constant EULER_V2_BALANCE_FUSE_NAME = "EULER_V2_BALANCE_FUSE";

    uint16 public constant EULER_V2_SUPPLY_FUSE_ID = 24;
    string public constant EULER_V2_SUPPLY_FUSE_NAME = "EULER_V2_SUPPLY_FUSE";

    uint16 public constant EULER_V2_BORROW_FUSE_ID = 25;
    string public constant EULER_V2_BORROW_FUSE_NAME = "EULER_V2_BORROW_FUSE";

    uint16 public constant EULER_V2_COLLATERAL_FUSE_ID = 26;
    string public constant EULER_V2_COLLATERAL_FUSE_NAME = "EULER_V2_COLLATERAL_FUSE";

    uint16 public constant EULER_V2_CONTROLLER_FUSE_ID = 27;
    string public constant EULER_V2_CONTROLLER_FUSE_NAME = "EULER_V2_CONTROLLER_FUSE";

    uint16 public constant FLUID_INSTADAPP_STAKING_BALANCE_FUSE_ID = 28;
    string public constant FLUID_INSTADAPP_STAKING_BALANCE_FUSE_NAME = "FLUID_INSTADAPP_STAKING_BALANCE_FUSE";

    uint16 public constant FLUID_INSTADAPP_STAKING_SUPPLY_FUSE_ID = 29;
    string public constant FLUID_INSTADAPP_STAKING_SUPPLY_FUSE_NAME = "FLUID_INSTADAPP_STAKING_SUPPLY_FUSE";

    uint16 public constant FLUID_INSTADAPP_CLAIM_FUSE_ID = 30;
    string public constant FLUID_INSTADAPP_CLAIM_FUSE_NAME = "FLUID_INSTADAPP_CLAIM_FUSE";

    uint16 public constant FLUID_PROOF_CLAIM_FUSE_ID = 31;
    string public constant FLUID_PROOF_CLAIM_FUSE_NAME = "FLUID_PROOF_CLAIM_FUSE";

    uint16 public constant GEARBOX_V3_FARM_BALANCE_FUSE_ID = 32;
    string public constant GEARBOX_V3_FARM_BALANCE_FUSE_NAME = "GEARBOX_V3_FARM_BALANCE_FUSE";

    uint16 public constant GEARBOX_V3_FARM_SUPPLY_FUSE_ID = 33;
    string public constant GEARBOX_V3_FARM_SUPPLY_FUSE_NAME = "GEARBOX_V3_FARM_SUPPLY_FUSE";

    uint16 public constant GEARBOX_V3_FARM_D_TOKEN_CLAIM_FUSE_ID = 34;
    string public constant GEARBOX_V3_FARM_D_TOKEN_CLAIM_FUSE_NAME = "GEARBOX_V3_FARM_D_TOKEN_CLAIM_FUSE";

    uint16 public constant HARVEST_DO_HARD_WORK_FUSE_ID = 35;
    string public constant HARVEST_DO_HARD_WORK_FUSE_NAME = "HARVEST_DO_HARD_WORK_FUSE";

    uint16 public constant MOONWELL_BALANCE_FUSE_ID = 36;
    string public constant MOONWELL_BALANCE_FUSE_NAME = "MOONWELL_BALANCE_FUSE";

    uint16 public constant MOONWELL_SUPPLY_FUSE_ID = 37;
    string public constant MOONWELL_SUPPLY_FUSE_NAME = "MOONWELL_SUPPLY_FUSE";

    uint16 public constant MOONWELL_BORROW_FUSE_ID = 38;
    string public constant MOONWELL_BORROW_FUSE_NAME = "MOONWELL_BORROW_FUSE";

    uint16 public constant MOONWELL_ENABLE_MARKET_FUSE_ID = 39;
    string public constant MOONWELL_ENABLE_MARKET_FUSE_NAME = "MOONWELL_ENABLE_MARKET_FUSE";

    uint16 public constant MOONWELL_CLAIM_FUSE_ID = 40;
    string public constant MOONWELL_CLAIM_FUSE_NAME = "MOONWELL_CLAIM_FUSE";

    uint16 public constant MORPHO_BALANCE_FUSE_ID = 41;
    string public constant MORPHO_BALANCE_FUSE_NAME = "MORPHO_BALANCE_FUSE";

    uint16 public constant MORPHO_BORROW_FUSE_ID = 42;
    string public constant MORPHO_BORROW_FUSE_NAME = "MORPHO_BORROW_FUSE";

    uint16 public constant MORPHO_COLLATERAL_FUSE_ID = 43;
    string public constant MORPHO_COLLATERAL_FUSE_NAME = "MORPHO_COLLATERAL_FUSE";

    uint16 public constant MORPHO_FLASH_LOAN_FUSE_ID = 44;
    string public constant MORPHO_FLASH_LOAN_FUSE_NAME = "MORPHO_FLASH_LOAN_FUSE";

    uint16 public constant MORPHO_SUPPLY_FUSE_ID = 45;
    string public constant MORPHO_SUPPLY_FUSE_NAME = "MORPHO_SUPPLY_FUSE";

    uint16 public constant MORPHO_SUPPLY_WITH_CALLBACK_DATA_FUSE_ID = 46;
    string public constant MORPHO_SUPPLY_WITH_CALLBACK_DATA_FUSE_NAME = "MORPHO_SUPPLY_WITH_CALLBACK_DATA_FUSE";

    uint16 public constant MORPHO_CLAIM_FUSE_ID = 47;
    string public constant MORPHO_CLAIM_FUSE_NAME = "MORPHO_CLAIM_FUSE";

    uint16 public constant PENDLE_REDEEM_PT_AFTER_MATURITY_FUSE_ID = 48;
    string public constant PENDLE_REDEEM_PT_AFTER_MATURITY_FUSE_NAME = "PENDLE_REDEEM_PT_AFTER_MATURITY_FUSE";

    uint16 public constant PENDLE_SWAP_PT_FUSE_ID = 49;
    string public constant PENDLE_SWAP_PT_FUSE_NAME = "PENDLE_SWAP_PT_FUSE";

    uint16 public constant PLASMA_VAULT_REQUEST_SHARES_FUSE_ID = 50;
    string public constant PLASMA_VAULT_REQUEST_SHARES_FUSE_NAME = "PLASMA_VAULT_REQUEST_SHARES_FUSE";

    uint16 public constant PLASMA_VAULT_REDEEM_FROM_REQUEST_FUSE_ID = 51;
    string public constant PLASMA_VAULT_REDEEM_FROM_REQUEST_FUSE_NAME = "PLASMA_VAULT_REDEEM_FROM_REQUEST_FUSE";

    uint16 public constant RAMSES_V2_BALANCE_FUSE_ID = 52;
    string public constant RAMSES_V2_BALANCE_FUSE_NAME = "RAMSES_V2_BALANCE_FUSE";

    uint16 public constant RAMSES_V2_COLLECT_FUSE_ID = 53;
    string public constant RAMSES_V2_COLLECT_FUSE_NAME = "RAMSES_V2_COLLECT_FUSE";

    uint16 public constant RAMSES_V2_MODIFY_POSITION_FUSE_ID = 54;
    string public constant RAMSES_V2_MODIFY_POSITION_FUSE_NAME = "RAMSES_V2_MODIFY_POSITION_FUSE";

    uint16 public constant RAMSES_V2_NEW_POSITION_FUSE_ID = 55;
    string public constant RAMSES_V2_NEW_POSITION_FUSE_NAME = "RAMSES_V2_NEW_POSITION_FUSE";

    uint16 public constant RAMSES_CLAIM_FUSE_ID = 56;
    string public constant RAMSES_CLAIM_FUSE_NAME = "RAMSES_CLAIM_FUSE";

    uint16 public constant UNISWAP_V2_SWAP_FUSE_ID = 57;
    string public constant UNISWAP_V2_SWAP_FUSE_NAME = "UNISWAP_V2_SWAP_FUSE";

    uint16 public constant UNISWAP_V3_BALANCE_FUSE_ID = 58;
    string public constant UNISWAP_V3_BALANCE_FUSE_NAME = "UNISWAP_V3_BALANCE_FUSE";

    uint16 public constant UNISWAP_V3_COLLECT_FUSE_ID = 59;
    string public constant UNISWAP_V3_COLLECT_FUSE_NAME = "UNISWAP_V3_COLLECT_FUSE";

    uint16 public constant UNISWAP_V3_MODIFY_POSITION_FUSE_ID = 60;
    string public constant UNISWAP_V3_MODIFY_POSITION_FUSE_NAME = "UNISWAP_V3_MODIFY_POSITION_FUSE";

    uint16 public constant UNISWAP_V3_NEW_POSITION_FUSE_ID = 61;
    string public constant UNISWAP_V3_NEW_POSITION_FUSE_NAME = "UNISWAP_V3_NEW_POSITION_FUSE";

    uint16 public constant UNISWAP_V3_SWAP_FUSE_ID = 62;
    string public constant UNISWAP_V3_SWAP_FUSE_NAME = "UNISWAP_V3_SWAP_FUSE";

    uint16 public constant UNIVERSAL_TOKEN_SWAPPER_FUSE_ID = 63;
    string public constant UNIVERSAL_TOKEN_SWAPPER_FUSE_NAME = "UNIVERSAL_TOKEN_SWAPPER_FUSE";

    uint16 public constant UNIVERSAL_TOKEN_SWAPPER_ETH_FUSE_ID = 64;
    string public constant UNIVERSAL_TOKEN_SWAPPER_ETH_FUSE_NAME = "UNIVERSAL_TOKEN_SWAPPER_ETH_FUSE";

    uint16 public constant UNIVERSAL_TOKEN_SWAPPER_WITH_VERIFICATION_FUSE_ID = 65;
    string public constant UNIVERSAL_TOKEN_SWAPPER_WITH_VERIFICATION_FUSE_NAME = "UNIVERSAL_TOKEN_SWAPPER_WITH_VERIFICATION_FUSE";

    function getAllFuseIds() internal pure returns (uint16[] memory) {
        uint16[] memory fuseIds = new uint16[](65);
        fuseIds[0] = AAVE_V2_BALANCE_FUSE_ID;
        fuseIds[1] = AAVE_V2_SUPPLY_FUSE_ID;
        fuseIds[2] = AAVE_V3_BALANCE_FUSE_ID;
        fuseIds[3] = AAVE_V3_SUPPLY_FUSE_ID;
        fuseIds[4] = AAVE_V3_BORROW_FUSE_ID;
        fuseIds[5] = BURN_REQUEST_FEE_FUSE_ID;
        fuseIds[6] = SPARK_BALANCE_FUSE_ID;
        fuseIds[7] = SPARK_SUPPLY_FUSE_ID;
        fuseIds[8] = COMPOUND_V2_BALANCE_FUSE_ID;
        fuseIds[9] = COMPOUND_V2_SUPPLY_FUSE_ID;
        fuseIds[10] = COMPOUND_V3_BALANCE_FUSE_ID;
        fuseIds[11] = COMPOUND_V3_SUPPLY_FUSE_ID;
        fuseIds[12] = COMPOUND_V3_CLAIM_FUSE_ID;
        fuseIds[13] = CURVE_CHILD_LIQUIDITY_GAUGE_BALANCE_FUSE_ID;
        fuseIds[14] = CURVE_CHILD_LIQUIDITY_GAUGE_SUPPLY_FUSE_ID;
        fuseIds[15] = CURVE_CHILD_LIQUIDITY_GAUGE_ERC4626_BALANCE_FUSE_ID;
        fuseIds[16] = CURVE_STABLESWAP_NG_SINGLE_SIDE_BALANCE_FUSE_ID;
        fuseIds[17] = CURVE_STABLESWAP_NG_SINGLE_SIDE_SUPPLY_FUSE_ID;
        fuseIds[18] = CURVE_GAUGE_TOKEN_CLAIM_FUSE_ID;
        fuseIds[19] = ERC20_BALANCE_FUSE_ID;
        fuseIds[20] = ERC4626_BALANCE_FUSE_ID;
        fuseIds[21] = ERC4626_SUPPLY_FUSE_ID;
        fuseIds[22] = EULER_V2_BALANCE_FUSE_ID;
        fuseIds[23] = EULER_V2_SUPPLY_FUSE_ID;
        fuseIds[24] = EULER_V2_BORROW_FUSE_ID;
        fuseIds[25] = EULER_V2_COLLATERAL_FUSE_ID;
        fuseIds[26] = EULER_V2_CONTROLLER_FUSE_ID;
        fuseIds[27] = FLUID_INSTADAPP_STAKING_BALANCE_FUSE_ID;
        fuseIds[28] = FLUID_INSTADAPP_STAKING_SUPPLY_FUSE_ID;
        fuseIds[29] = FLUID_INSTADAPP_CLAIM_FUSE_ID;
        fuseIds[30] = FLUID_PROOF_CLAIM_FUSE_ID;
        fuseIds[31] = GEARBOX_V3_FARM_BALANCE_FUSE_ID;
        fuseIds[32] = GEARBOX_V3_FARM_SUPPLY_FUSE_ID;
        fuseIds[33] = GEARBOX_V3_FARM_D_TOKEN_CLAIM_FUSE_ID;
        fuseIds[34] = HARVEST_DO_HARD_WORK_FUSE_ID;
        fuseIds[35] = MOONWELL_BALANCE_FUSE_ID;
        fuseIds[36] = MOONWELL_SUPPLY_FUSE_ID;
        fuseIds[37] = MOONWELL_BORROW_FUSE_ID;
        fuseIds[38] = MOONWELL_ENABLE_MARKET_FUSE_ID;
        fuseIds[39] = MOONWELL_CLAIM_FUSE_ID;
        fuseIds[40] = MORPHO_BALANCE_FUSE_ID;
        fuseIds[41] = MORPHO_BORROW_FUSE_ID;
        fuseIds[42] = MORPHO_COLLATERAL_FUSE_ID;
        fuseIds[43] = MORPHO_FLASH_LOAN_FUSE_ID;
        fuseIds[44] = MORPHO_SUPPLY_FUSE_ID;
        fuseIds[45] = MORPHO_SUPPLY_WITH_CALLBACK_DATA_FUSE_ID;
        fuseIds[46] = MORPHO_CLAIM_FUSE_ID;
        fuseIds[47] = PENDLE_REDEEM_PT_AFTER_MATURITY_FUSE_ID;
        fuseIds[48] = PENDLE_SWAP_PT_FUSE_ID;
        fuseIds[49] = PLASMA_VAULT_REQUEST_SHARES_FUSE_ID;
        fuseIds[50] = PLASMA_VAULT_REDEEM_FROM_REQUEST_FUSE_ID;
        fuseIds[51] = RAMSES_V2_BALANCE_FUSE_ID;
        fuseIds[52] = RAMSES_V2_COLLECT_FUSE_ID;
        fuseIds[53] = RAMSES_V2_MODIFY_POSITION_FUSE_ID;
        fuseIds[54] = RAMSES_V2_NEW_POSITION_FUSE_ID;
        fuseIds[55] = RAMSES_CLAIM_FUSE_ID;
        fuseIds[56] = UNISWAP_V2_SWAP_FUSE_ID;
        fuseIds[57] = UNISWAP_V3_BALANCE_FUSE_ID;
        fuseIds[58] = UNISWAP_V3_COLLECT_FUSE_ID;
        fuseIds[59] = UNISWAP_V3_MODIFY_POSITION_FUSE_ID;
        fuseIds[60] = UNISWAP_V3_NEW_POSITION_FUSE_ID;
        fuseIds[61] = UNISWAP_V3_SWAP_FUSE_ID;
        fuseIds[62] = UNIVERSAL_TOKEN_SWAPPER_FUSE_ID;
        fuseIds[63] = UNIVERSAL_TOKEN_SWAPPER_ETH_FUSE_ID;
        fuseIds[64] = UNIVERSAL_TOKEN_SWAPPER_WITH_VERIFICATION_FUSE_ID;
        return fuseIds;
    }

    function getAllFuseNames() internal pure returns (string[] memory) {
        string[] memory fuseNames = new string[](65);
        fuseNames[0] = AAVE_V2_BALANCE_FUSE_NAME;
        fuseNames[1] = AAVE_V2_SUPPLY_FUSE_NAME;
        fuseNames[2] = AAVE_V3_BALANCE_FUSE_NAME;
        fuseNames[3] = AAVE_V3_SUPPLY_FUSE_NAME;
        fuseNames[4] = AAVE_V3_BORROW_FUSE_NAME;
        fuseNames[5] = BURN_REQUEST_FEE_FUSE_NAME;
        fuseNames[6] = SPARK_BALANCE_FUSE_NAME;
        fuseNames[7] = SPARK_SUPPLY_FUSE_NAME;
        fuseNames[8] = COMPOUND_V2_BALANCE_FUSE_NAME;
        fuseNames[9] = COMPOUND_V2_SUPPLY_FUSE_NAME;
        fuseNames[10] = COMPOUND_V3_BALANCE_FUSE_NAME;
        fuseNames[11] = COMPOUND_V3_SUPPLY_FUSE_NAME;
        fuseNames[12] = COMPOUND_V3_CLAIM_FUSE_NAME;
        fuseNames[13] = CURVE_CHILD_LIQUIDITY_GAUGE_BALANCE_FUSE_NAME;
        fuseNames[14] = CURVE_CHILD_LIQUIDITY_GAUGE_SUPPLY_FUSE_NAME;
        fuseNames[15] = CURVE_CHILD_LIQUIDITY_GAUGE_ERC4626_BALANCE_FUSE_NAME;
        fuseNames[16] = CURVE_STABLESWAP_NG_SINGLE_SIDE_BALANCE_FUSE_NAME;
        fuseNames[17] = CURVE_STABLESWAP_NG_SINGLE_SIDE_SUPPLY_FUSE_NAME;
        fuseNames[18] = CURVE_GAUGE_TOKEN_CLAIM_FUSE_NAME;
        fuseNames[19] = ERC20_BALANCE_FUSE_NAME;
        fuseNames[20] = ERC4626_BALANCE_FUSE_NAME;
        fuseNames[21] = ERC4626_SUPPLY_FUSE_NAME;
        fuseNames[22] = EULER_V2_BALANCE_FUSE_NAME;
        fuseNames[23] = EULER_V2_SUPPLY_FUSE_NAME;
        fuseNames[24] = EULER_V2_BORROW_FUSE_NAME;
        fuseNames[25] = EULER_V2_COLLATERAL_FUSE_NAME;
        fuseNames[26] = EULER_V2_CONTROLLER_FUSE_NAME;
        fuseNames[27] = FLUID_INSTADAPP_STAKING_BALANCE_FUSE_NAME;
        fuseNames[28] = FLUID_INSTADAPP_STAKING_SUPPLY_FUSE_NAME;
        fuseNames[29] = FLUID_INSTADAPP_CLAIM_FUSE_NAME;
        fuseNames[30] = FLUID_PROOF_CLAIM_FUSE_NAME;
        fuseNames[31] = GEARBOX_V3_FARM_BALANCE_FUSE_NAME;
        fuseNames[32] = GEARBOX_V3_FARM_SUPPLY_FUSE_NAME;
        fuseNames[33] = GEARBOX_V3_FARM_D_TOKEN_CLAIM_FUSE_NAME;
        fuseNames[34] = HARVEST_DO_HARD_WORK_FUSE_NAME;
        fuseNames[35] = MOONWELL_BALANCE_FUSE_NAME;
        fuseNames[36] = MOONWELL_SUPPLY_FUSE_NAME;
        fuseNames[37] = MOONWELL_BORROW_FUSE_NAME;
        fuseNames[38] = MOONWELL_ENABLE_MARKET_FUSE_NAME;
        fuseNames[39] = MOONWELL_CLAIM_FUSE_NAME;
        fuseNames[40] = MORPHO_BALANCE_FUSE_NAME;
        fuseNames[41] = MORPHO_BORROW_FUSE_NAME;
        fuseNames[42] = MORPHO_COLLATERAL_FUSE_NAME;
        fuseNames[43] = MORPHO_FLASH_LOAN_FUSE_NAME;
        fuseNames[44] = MORPHO_SUPPLY_FUSE_NAME;
        fuseNames[45] = MORPHO_SUPPLY_WITH_CALLBACK_DATA_FUSE_NAME;
        fuseNames[46] = MORPHO_CLAIM_FUSE_NAME;
        fuseNames[47] = PENDLE_REDEEM_PT_AFTER_MATURITY_FUSE_NAME;
        fuseNames[48] = PENDLE_SWAP_PT_FUSE_NAME;
        fuseNames[49] = PLASMA_VAULT_REQUEST_SHARES_FUSE_NAME;
        fuseNames[50] = PLASMA_VAULT_REDEEM_FROM_REQUEST_FUSE_NAME;
        fuseNames[51] = RAMSES_V2_BALANCE_FUSE_NAME;
        fuseNames[52] = RAMSES_V2_COLLECT_FUSE_NAME;
        fuseNames[53] = RAMSES_V2_MODIFY_POSITION_FUSE_NAME;
        fuseNames[54] = RAMSES_V2_NEW_POSITION_FUSE_NAME;
        fuseNames[55] = RAMSES_CLAIM_FUSE_NAME;
        fuseNames[56] = UNISWAP_V2_SWAP_FUSE_NAME;
        fuseNames[57] = UNISWAP_V3_BALANCE_FUSE_NAME;
        fuseNames[58] = UNISWAP_V3_COLLECT_FUSE_NAME;
        fuseNames[59] = UNISWAP_V3_MODIFY_POSITION_FUSE_NAME;
        fuseNames[60] = UNISWAP_V3_NEW_POSITION_FUSE_NAME;
        fuseNames[61] = UNISWAP_V3_SWAP_FUSE_NAME;
        fuseNames[62] = UNIVERSAL_TOKEN_SWAPPER_FUSE_NAME;
        fuseNames[63] = UNIVERSAL_TOKEN_SWAPPER_ETH_FUSE_NAME;
        fuseNames[64] = UNIVERSAL_TOKEN_SWAPPER_WITH_VERIFICATION_FUSE_NAME;
        return fuseNames;
    }
}
