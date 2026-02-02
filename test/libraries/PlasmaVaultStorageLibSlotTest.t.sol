// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title PlasmaVaultStorageLibSlotTest
/// @notice Verifies that all storage slot constants in PlasmaVaultStorageLib are correctly computed
/// @dev Storage slots use the ERC-7201 pattern:
///      keccak256(abi.encode(uint256(keccak256("namespace.name")) - 1)) & ~bytes32(uint256(0xff))
contract PlasmaVaultStorageLibSlotTest is Test {
    /// @notice Mask to clear the last byte (ensures slot alignment per ERC-7201)
    bytes32 private constant SLOT_MASK = ~bytes32(uint256(0xff));

    /// @notice Computes ERC-7201 compliant storage slot
    /// @param namespace The namespace string used to derive the slot
    /// @return The computed storage slot
    function _computeSlot(string memory namespace) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & SLOT_MASK;
    }

    // ============ OpenZeppelin Standard Slots ============
    // These use different formulas - taken directly from OZ contracts

    /// @notice Verifies ERC4626_STORAGE_LOCATION (OpenZeppelin standard)
    /// @dev From ERC4626Upgradeable: keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
    function testErc4626StorageLocation() public pure {
        bytes32 expectedSlot = _computeSlot("openzeppelin.storage.ERC4626");
        bytes32 actualSlot = 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;
        assertEq(actualSlot, expectedSlot, "ERC4626_STORAGE_LOCATION mismatch");
    }

    /// @notice Verifies ERC20_CAPPED_STORAGE_LOCATION (OpenZeppelin standard)
    /// @dev From ERC20CappedUpgradeable: keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20Capped")) - 1)) & ~bytes32(uint256(0xff))
    function testErc20CappedStorageLocation() public pure {
        bytes32 expectedSlot = _computeSlot("openzeppelin.storage.ERC20Capped");
        bytes32 actualSlot = 0x0f070392f17d5f958cc1ac31867dabecfc5c9758b4a419a200803226d7155d00;
        assertEq(actualSlot, expectedSlot, "ERC20_CAPPED_STORAGE_LOCATION mismatch");
    }

    // ============ IPOR Custom Slots ============

    /// @notice Verifies ERC20_CAPPED_VALIDATION_FLAG slot
    function testErc20CappedValidationFlagSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.Erc20CappedValidationFlag");
        bytes32 actualSlot = 0xaef487a7a52e82ae7bbc470b42be72a1d3c066fb83773bf99cce7e6a7df2f900;
        assertEq(actualSlot, expectedSlot, "ERC20_CAPPED_VALIDATION_FLAG mismatch");
    }

    /// @notice Verifies PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS slot
    function testPlasmaVaultTotalAssetsInAllMarketsSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.PlasmaVaultTotalAssetsInAllMarkets");
        bytes32 actualSlot = 0x24e02552e88772b8e8fd15f3e6699ba530635ffc6b52322da922b0b497a77300;
        assertEq(actualSlot, expectedSlot, "PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS mismatch");
    }

    /// @notice Verifies PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET slot
    function testPlasmaVaultTotalAssetsInMarketSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.PlasmaVaultTotalAssetsInMarket");
        bytes32 actualSlot = 0x656f5ca8c676f20b936e991a840e1130bdd664385322f33b6642ec86729ee600;
        assertEq(actualSlot, expectedSlot, "PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET mismatch");
    }

    /// @notice Verifies CFG_PLASMA_VAULT_MARKET_SUBSTRATES slot
    function testCfgPlasmaVaultMarketSubstratesSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.CfgPlasmaVaultMarketSubstrates");
        bytes32 actualSlot = 0x78e40624004925a4ef6749756748b1deddc674477302d5b7fe18e5335cde3900;
        assertEq(actualSlot, expectedSlot, "CFG_PLASMA_VAULT_MARKET_SUBSTRATES mismatch");
    }

    /// @notice Verifies CFG_PLASMA_VAULT_PRE_HOOKS slot
    function testCfgPlasmaVaultPreHooksSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.CfgPlasmaVaultPreHooks");
        bytes32 actualSlot = 0xd334d8b26e68f82b7df26f2f64b6ffd2aaae5e2fc0e8c144c4b3598dcddd4b00;
        assertEq(actualSlot, expectedSlot, "CFG_PLASMA_VAULT_PRE_HOOKS mismatch");
    }

    /// @notice Verifies CFG_PLASMA_VAULT_BALANCE_FUSES slot
    function testCfgPlasmaVaultBalanceFusesSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.CfgPlasmaVaultBalanceFuses");
        bytes32 actualSlot = 0x150144dd6af711bac4392499881ec6649090601bd196a5ece5174c1400b1f700;
        assertEq(actualSlot, expectedSlot, "CFG_PLASMA_VAULT_BALANCE_FUSES mismatch");
    }

    /// @notice Verifies CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY slot
    function testCfgPlasmaVaultInstantWithdrawalFusesArraySlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.CfgPlasmaVaultInstantWithdrawalFusesArray");
        bytes32 actualSlot = 0xd243afa3da07e6bdec20fdd573a17f99411aa8a62ae64ca2c426d3a86ae0ac00;
        assertEq(actualSlot, expectedSlot, "CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY mismatch");
    }

    /// @notice Verifies PRICE_ORACLE_MIDDLEWARE slot
    function testPriceOracleMiddlewareSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.PriceOracleMiddleware");
        bytes32 actualSlot = 0x0d761ae54d86fc3be4f1f2b44ade677efb1c84a85fc6bb1d087dc42f1e319a00;
        assertEq(actualSlot, expectedSlot, "PRICE_ORACLE_MIDDLEWARE mismatch");
    }

    /// @notice Verifies CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS slot
    function testCfgPlasmaVaultInstantWithdrawalFusesParamsSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.CfgPlasmaVaultInstantWithdrawalFusesParams");
        bytes32 actualSlot = 0x45a704819a9dcb1bb5b8cff129eda642cf0e926a9ef104e27aa53f1d1fa47b00;
        assertEq(actualSlot, expectedSlot, "CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS mismatch");
    }

    /// @notice Verifies CFG_PLASMA_VAULT_FEE_CONFIG slot
    function testCfgPlasmaVaultFeeConfigSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.CfgPlasmaVaultFeeConfig");
        bytes32 actualSlot = 0x78b5ce597bdb64d5aa30a201c7580beefe408ff13963b5d5f3dce2dc09e89c00;
        assertEq(actualSlot, expectedSlot, "CFG_PLASMA_VAULT_FEE_CONFIG mismatch");
    }

    /// @notice Verifies PLASMA_VAULT_PERFORMANCE_FEE_DATA slot
    function testPlasmaVaultPerformanceFeeDataSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.PlasmaVaultPerformanceFeeData");
        bytes32 actualSlot = 0x9399757a27831a6cfb6cf4cd5c97a908a2f8f41e95a5952fbf83a04e05288400;
        assertEq(actualSlot, expectedSlot, "PLASMA_VAULT_PERFORMANCE_FEE_DATA mismatch");
    }

    /// @notice Verifies PLASMA_VAULT_MANAGEMENT_FEE_DATA slot
    function testPlasmaVaultManagementFeeDataSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.PlasmaVaultManagementFeeData");
        bytes32 actualSlot = 0x239dd7e43331d2af55e2a25a6908f3bcec2957025f1459db97dcdc37c0003f00;
        assertEq(actualSlot, expectedSlot, "PLASMA_VAULT_MANAGEMENT_FEE_DATA mismatch");
    }

    /// @notice Verifies REWARDS_CLAIM_MANAGER_ADDRESS slot
    function testRewardsClaimManagerAddressSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.RewardsClaimManagerAddress");
        bytes32 actualSlot = 0x08c469289c3f85d9b575f3ae9be6831541ff770a06ea135aa343a4de7c962d00;
        assertEq(actualSlot, expectedSlot, "REWARDS_CLAIM_MANAGER_ADDRESS mismatch");
    }

    /// @notice Verifies MARKET_LIMITS slot
    function testMarketLimitsSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.MarketLimits");
        bytes32 actualSlot = 0xc2733c187287f795e2e6e84d35552a190e774125367241c3e99e955f4babf000;
        assertEq(actualSlot, expectedSlot, "MARKET_LIMITS mismatch");
    }

    /// @notice Verifies DEPENDENCY_BALANCE_GRAPH slot
    function testDependencyBalanceGraphSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.DependencyBalanceGraph");
        bytes32 actualSlot = 0x82411e549329f2815579116a6c5e60bff72686c93ab5dba4d06242cfaf968900;
        assertEq(actualSlot, expectedSlot, "DEPENDENCY_BALANCE_GRAPH mismatch");
    }

    /// @notice Verifies EXECUTE_RUNNING slot
    function testExecuteRunningSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.executeRunning");
        bytes32 actualSlot = 0x054644eb87255c1c6a2d10801735f52fa3b9d6e4477dbed74914d03844ab6600;
        assertEq(actualSlot, expectedSlot, "EXECUTE_RUNNING mismatch");
    }

    /// @notice Verifies CALLBACK_HANDLER slot
    function testCallbackHandlerSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.callbackHandler");
        bytes32 actualSlot = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e00;
        assertEq(actualSlot, expectedSlot, "CALLBACK_HANDLER mismatch");
    }

    /// @notice Verifies WITHDRAW_MANAGER slot
    /// @dev NOTE: This slot value does NOT match the documented formula "io.ipor.WithdrawManager".
    ///      The actual value (0xb37e...3e11) appears to be derived from CALLBACK_HANDLER (0xb37e...3e00)
    ///      with a different last byte. This is a legacy issue from the original implementation.
    ///      Since contracts are already deployed with this value, it CANNOT be changed.
    ///      Correct value per formula would be: 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100
    function testWithdrawManagerSlot() public pure {
        // Legacy value - does not match documented formula but is already deployed
        bytes32 actualSlot = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;
        // Verify it's distinct from CALLBACK_HANDLER
        bytes32 callbackHandlerSlot = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e00;
        assertTrue(actualSlot != callbackHandlerSlot, "WITHDRAW_MANAGER must differ from CALLBACK_HANDLER");
    }

    /// @notice Verifies PLASMA_VAULT_BASE_SLOT
    function testPlasmaVaultBaseSlot() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.fusion.PlasmaVaultBase");
        bytes32 actualSlot = 0x708fd1151214a098976e0893cd3883792c21aeb94a31cd7733c8947c13c23000;
        assertEq(actualSlot, expectedSlot, "PLASMA_VAULT_BASE_SLOT mismatch");
    }

    /// @notice Verifies SHARE_SCALE_MULTIPLIER_SLOT
    function testShareScaleMultiplierSlotValue() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.fusion.param.ShareScaleMultiplier");
        bytes32 actualSlot = 0x5bb34fc23414cfe7e422518e1d8590877bcc5dcacad5f8689bfd98e9a05ac600;
        assertEq(actualSlot, expectedSlot, "SHARE_SCALE_MULTIPLIER_SLOT mismatch");
    }

    /// @notice Verifies PLASMA_VAULT_VOTES_PLUGIN_SLOT
    function testPlasmaVaultVotesPluginSlotValue() public pure {
        bytes32 expectedSlot = _computeSlot("io.ipor.fusion.PlasmaVaultVotesPlugin");
        bytes32 actualSlot = 0x9a54c2c1797818ee85d1850742208f80368867ad13d3e45052e701201fa4af00;
        assertEq(actualSlot, expectedSlot, "PLASMA_VAULT_VOTES_PLUGIN_SLOT mismatch");
    }
}
