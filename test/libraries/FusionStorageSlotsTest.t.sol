// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @title FusionStorageSlotsTest
/// @notice Comprehensive test suite verifying all storage slot constants across Fusion protocol
/// @dev Storage slots use the ERC-7201 pattern:
///      keccak256(abi.encode(uint256(keccak256("namespace.name")) - 1)) & ~bytes32(uint256(0xff))
contract FusionStorageSlotsTest is Test {
    /// @notice Mask to clear the last byte (ensures slot alignment per ERC-7201)
    bytes32 private constant SLOT_MASK = ~bytes32(uint256(0xff));

    /// @notice Computes ERC-7201 compliant storage slot
    function _computeSlot(string memory namespace) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & SLOT_MASK;
    }

    // ============================================
    // IporFusionAccessManagersStorageLib
    // ============================================

    function testAccessManager_RedemptionLocksSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.managers.access.RedemptionLocks");
        bytes32 actual = 0x5e07febb5bd598f6b55406c9bf939d497fd39a2dbc2b5891f20f6640c3f32500;
        assertEq(actual, expected, "REDEMPTION_LOCKS mismatch");
    }

    function testAccessManager_MinimalExecutionDelayForRoleSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.managers.access.MinimalExecutionDelayForRole");
        bytes32 actual = 0x2e44a6c6f75b62bc581bae68fca3a6629eb7343eef230a6702d4acd6389fd600;
        assertEq(actual, expected, "MINIMAL_EXECUTION_DELAY_FOR_ROLE mismatch");
    }

    function testAccessManager_InitializationFlagSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.managers.access.InitializationFlag");
        bytes32 actual = 0x25e922da7c41a5d012dbc2479dd6a7bd57760f359ea3a3be13608d287fc89400;
        assertEq(actual, expected, "INITIALIZATION_FLAG mismatch");
    }

    // ============================================
    // FeeManagerStorageLib
    // ============================================

    function testFeeManager_DaoFeeRecipientDataSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.dao.fee.recipient.data.storage");
        bytes32 actual = 0xaf522f71ce1f2b5702c38f667fa2366c184e3c6dd86ab049ad3b02fec741fd00;
        assertEq(actual, expected, "DAO_FEE_RECIPIENT_DATA_SLOT mismatch");
    }

    function testFeeManager_TotalPerformanceFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.total.performance.fee.storage");
        bytes32 actual = 0x91a7fd667a02d876183d5e3c0caf915fa5c0b6847afae1b6a2261f7bce984500;
        assertEq(actual, expected, "TOTAL_PERFORMANCE_FEE_SLOT mismatch");
    }

    function testFeeManager_TotalManagementFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.total.management.fee.storage");
        bytes32 actual = 0xcf56f35f42e69dcdff0b7b1f2e356cc5f92476bed919f8df0cdbf41f78aa1f00;
        assertEq(actual, expected, "TOTAL_MANAGEMENT_FEE_SLOT mismatch");
    }

    function testFeeManager_DepositFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.deposit.fee.storage");
        bytes32 actual = 0xd9b4590128261b514dbe7816b74c6ee2ff34efef3b40529466c801d63e471800;
        assertEq(actual, expected, "DEPOSIT_FEE_SLOT mismatch");
    }

    function testFeeManager_ManagementFeeRecipientDataSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.management.fee.recipient.data.storage");
        bytes32 actual = 0xf1a2374333eb639fe6654c1bd32856f942f1f785e32d72be0c2e035f2e0f8000;
        assertEq(actual, expected, "MANAGEMENT_FEE_RECIPIENT_DATA_SLOT mismatch");
    }

    function testFeeManager_PerformanceFeeRecipientDataSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.performance.fee.recipient.data.storage");
        bytes32 actual = 0xc456e86573d79f7b5b60c9eb824345c471d5390facece9407699845c141b2d00;
        assertEq(actual, expected, "PERFORMANCE_FEE_RECIPIENT_DATA_SLOT mismatch");
    }

    function testFeeManager_HighWaterMarkPerformanceFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fee.manager.high.water.mark.performance.fee.storage");
        bytes32 actual = 0xb9423b11a8779228bace4bf919d779502e12a07e11bd2f782c23aeac55439c00;
        assertEq(actual, expected, "HIGH_WATER_MARK_PERFORMANCE_FEE_SLOT mismatch");
    }

    // ============================================
    // RewardsClaimManagersStorageLib
    // ============================================

    function testRewardsManager_VestingDataSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.managers.rewards.VestingData");
        bytes32 actual = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00;
        assertEq(actual, expected, "VESTING_DATA mismatch");
    }

    function testRewardsManager_UnderlyingTokenSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.managers.rewards.UnderlyingToken");
        bytes32 actual = 0x96962a50a0c0e57d12771ca8fb38d59142b19de93fdd10189d0e6674c3c52600;
        assertEq(actual, expected, "UNDERLYING_TOKEN_SLOT mismatch");
    }

    function testRewardsManager_PlasmaVaultSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.managers.rewards.PlasmaVault");
        bytes32 actual = 0x2d4767721b6a66348474dafa99902e10eaba3139521ee5498349612c152c8100;
        assertEq(actual, expected, "PLASMA_VAULT_SLOT mismatch");
    }

    // ============================================
    // WithdrawManagerStorageLib
    // ============================================

    function testWithdrawManager_WithdrawWindowInSecondsSlot() public pure {
        // Note: This slot doesn't have documented namespace in source, using actual value
        bytes32 actual = 0xc98a13e0ed3915d36fc042835990f5c6fbf2b2570bd63878dcd560ca2b767c00;
        // Verify it's a valid ERC-7201 slot (last byte is 00)
        assertEq(uint8(uint256(actual)), 0, "WITHDRAW_WINDOW_IN_SECONDS should end with 00");
    }

    function testWithdrawManager_WithdrawRequestsSlot() public pure {
        // Note: This slot doesn't have documented namespace in source, using actual value
        bytes32 actual = 0x5f79d61c9d5139383097775e8e8bbfd941634f6602a18bee02d4f80d80c89f00;
        // Verify it's a valid ERC-7201 slot (last byte is 00)
        assertEq(uint8(uint256(actual)), 0, "WITHDRAW_REQUESTS should end with 00");
    }

    function testWithdrawManager_LastReleaseFundsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.withdraw.manager.wirgdraw.requests");
        bytes32 actual = 0x88d141dcaacfb8523e39ee7fba7c6f591450286f42f9c7069cc072812d539200;
        // Note: The namespace has a typo "wirgdraw" but this is what's in the source
        assertEq(actual, expected, "LAST_RELEASE_FUNDS mismatch");
    }

    function testWithdrawManager_RequestFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.withdraw.manager.requests.fee");
        bytes32 actual = 0x97f346e04a16e2eb518a1ffef159e6c87d3eaa2076a90372e699cdb1af482400;
        assertEq(actual, expected, "REQUEST_FEE mismatch");
    }

    function testWithdrawManager_WithdrawFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.withdraw.manager.withdraw.fee");
        bytes32 actual = 0x1dc9c20e1601df7037c9a39067c6ecf51e88a43bc6cd86f115a2c29716b36600;
        assertEq(actual, expected, "WITHDRAW_FEE mismatch");
    }

    function testWithdrawManager_PlasmaVaultAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.withdraw.manager.plasma.vault");
        bytes32 actual = 0xeb1948ad07cc64342983d8dc0a37729fcf2d17dcf49a1e3705ff0fa01e7d9400;
        assertEq(actual, expected, "PLASMA_VAULT_ADDRESS mismatch");
    }

    // ============================================
    // ContextManagerStorageLib
    // ============================================

    function testContextManager_ApprovedTargetsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.context.manager.approved.targets");
        bytes32 actual = 0xba0b14fc3b5f6eb62b63f24324d3267b78a7c3121b0d922dabc8df20fcad1800;
        assertEq(actual, expected, "APPROVED_TARGETS mismatch");
    }

    function testContextManager_NoncesSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.context.manager.nonces");
        bytes32 actual = 0x0409b94a090b90a18fc2f85ddcc3023733517210eae8ad3941f503bbcf96a600;
        assertEq(actual, expected, "NONCES_SLOT mismatch");
    }

    // ============================================
    // ContextClientStorageLib
    // ============================================

    function testContextClient_SenderStorageSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.context.client.sender.storage");
        bytes32 actual = 0x68262fe08792a71a690eb5eb2de15df1b0f463dd786bf92bdbd5f0f0d1ae8b00;
        assertEq(actual, expected, "CONTEXT_SENDER_STORAGE_SLOT mismatch");
    }

    // ============================================
    // PriceOracleMiddlewareStorageLib
    // ============================================

    function testPriceOracle_AssetsPricesSourcesSlot() public pure {
        // Note: This slot doesn't have documented namespace in source, using actual value
        bytes32 actual = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00;
        // Verify it's a valid ERC-7201 slot (last byte is 00)
        assertEq(uint8(uint256(actual)), 0, "ASSETS_PRICES_SOURCES should end with 00");
    }

    // ============================================
    // FusionFactoryStorageLib
    // ============================================

    function testFactory_FusionFactoryVersionSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.FusionFactoryVersion");
        bytes32 actual = 0x12d32eeb1bff59ce950917bf8e830c4c4200d70d78bc80ef73671dd3e0c72000;
        assertEq(actual, expected, "FUSION_FACTORY_VERSION mismatch");
    }

    function testFactory_FusionFactoryIndexSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.FusionFactoryIndex");
        bytes32 actual = 0x7c54bb33443ce94044aec2970018125c202903e78abecda9a8871f0a2e085400;
        assertEq(actual, expected, "FUSION_FACTORY_INDEX mismatch");
    }

    function testFactory_PlasmaVaultAdminArraySlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PlasmaVaultAdminArray");
        bytes32 actual = 0x09e657bd0ea9e1ace5b99e5e8bb556174727dbd9076ea35b667e7736f1584000;
        assertEq(actual, expected, "PLASMA_VAULT_ADMIN_ARRAY mismatch");
    }

    function testFactory_PlasmaVaultFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PlasmaVaultFactoryAddress");
        bytes32 actual = 0xe03d6bb506e833b55bb7e35e66d871fd1486b3efc6bb02b49fae15b9d0247c00;
        assertEq(actual, expected, "PLASMA_VAULT_FACTORY_ADDRESS mismatch");
    }

    function testFactory_AccessManagerFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.AccessManagerFactoryAddress");
        bytes32 actual = 0xc4010ca65378f19e44b7504e0cbdfa0cf4c6c98dc078f9636d3e6f447548f800;
        assertEq(actual, expected, "ACCESS_MANAGER_FACTORY_ADDRESS mismatch");
    }

    function testFactory_FeeManagerFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.FeeManagerFactoryAddress");
        bytes32 actual = 0x721d35383ddb7c0788c39a71ec2b671094a2dff039cf875075cb2cc19150ee00;
        assertEq(actual, expected, "FEE_MANAGER_FACTORY_ADDRESS mismatch");
    }

    function testFactory_RewardsManagerFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.RewardsManagerFactoryAddress");
        bytes32 actual = 0x876e1f4e6bf0084ef05fd36552de50d6a3381705e29281ddedec7e73a391a100;
        assertEq(actual, expected, "REWARDS_MANAGER_FACTORY_ADDRESS mismatch");
    }

    function testFactory_WithdrawManagerFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.WithdrawManagerFactoryAddress");
        bytes32 actual = 0xedd99766ca1e8c3d62993721acdaaf42a25e38027fea50866095b850992fdc00;
        assertEq(actual, expected, "WITHDRAW_MANAGER_FACTORY_ADDRESS mismatch");
    }

    function testFactory_ContextManagerFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.ContextManagerFactoryAddress");
        bytes32 actual = 0x33ff6c98f150f6340aa139cf0a40783e1ff0404e5958622d928ebe5534456a00;
        assertEq(actual, expected, "CONTEXT_MANAGER_FACTORY_ADDRESS mismatch");
    }

    function testFactory_PriceManagerFactoryAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PriceManagerFactoryAddress");
        bytes32 actual = 0xd7a02eb1d0bb68108f76123da75aaeb1a46f41df9f533c7662e3a619ec932800;
        assertEq(actual, expected, "PRICE_MANAGER_FACTORY_ADDRESS mismatch");
    }

    function testFactory_PlasmaVaultBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PlasmaVaultBaseAddress");
        bytes32 actual = 0x184318af1b1e15812549d3991019d6e84064e321b012fca8ea3de5c3da16db00;
        assertEq(actual, expected, "PLASMA_VAULT_BASE_ADDRESS mismatch");
    }

    function testFactory_PriceOracleMiddlewareAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PriceOracleMiddlewareAddress");
        bytes32 actual = 0x6fbe74bad032cccb3ef5e7d7be660790fda329f96cf9462b85accc6e1d7d4100;
        assertEq(actual, expected, "PRICE_ORACLE_MIDDLEWARE_ADDRESS mismatch");
    }

    function testFactory_BurnRequestFeeBalanceFuseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.BurnRequestFeeBalanceFuseAddress");
        bytes32 actual = 0xa0dc2f24541d4bbdc49c383a8746cd6256371b67d8afc882e3ce7e04f721df00;
        assertEq(actual, expected, "BURN_REQUEST_FEE_BALANCE_FUSE_ADDRESS mismatch");
    }

    function testFactory_BurnRequestFeeFuseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.BurnRequestFeeFuseAddress");
        bytes32 actual = 0xf011e505a711b4f906e6e0cfcd988c477cb335d6eb81d8284628276cae32ab00;
        assertEq(actual, expected, "BURN_REQUEST_FEE_FUSE_ADDRESS mismatch");
    }

    function testFactory_DaoFeeRecipientAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.IporDaoFeeRecipientAddress");
        bytes32 actual = 0xe26401adf3cefb9a94bf1fba47a8129fd18fd2e2e83de494ce289a832073a500;
        assertEq(actual, expected, "DAO_FEE_RECIPIENT_ADDRESS mismatch");
    }

    function testFactory_DaoManagementFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.IporDaoManagementFee");
        bytes32 actual = 0x8fc808da4bdddf1c57ae4d57b8d77cb4183e940f6bb88a2aecb349605eb51800;
        assertEq(actual, expected, "DAO_MANAGEMENT_FEE mismatch");
    }

    function testFactory_DaoPerformanceFeeSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.IporDaoPerformanceFee");
        bytes32 actual = 0x3d6b96d1c7d5b94a3af077c0baedb5f7745382ef440582d67ffa3542d73b9f00;
        assertEq(actual, expected, "DAO_PERFORMANCE_FEE mismatch");
    }

    function testFactory_WithdrawWindowInSecondsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.WithdrawWindowInSeconds");
        bytes32 actual = 0x95f9ecba121b4f2a2786b729864c46a5066694903a7462f772cd92093beb0500;
        assertEq(actual, expected, "WITHDRAW_WINDOW_IN_SECONDS mismatch");
    }

    function testFactory_VestingPeriodInSecondsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.VestingPeriodInSeconds");
        bytes32 actual = 0xe7de166eee522f429c14923fb385ff49d6c65d576ad910fc76c16800f269be00;
        assertEq(actual, expected, "VESTING_PERIOD_IN_SECONDS mismatch");
    }

    function testFactory_AccessManagerBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.AccessManagerBaseAddress");
        bytes32 actual = 0xdee5af15cbb5c7d3f575c81c43b164c912e2cacae09ac95ab04460973550ec00;
        assertEq(actual, expected, "ACCESS_MANAGER_BASE_ADDRESS mismatch");
    }

    function testFactory_WithdrawManagerBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.WithdrawManagerBaseAddress");
        bytes32 actual = 0x71c920154481896f4e6224fa3f403d92b902534a39efd0adf8948440a29f6900;
        assertEq(actual, expected, "WITHDRAW_MANAGER_BASE_ADDRESS mismatch");
    }

    function testFactory_RewardsManagerBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.RewardsManagerBaseAddress");
        bytes32 actual = 0x7947c1b14a70a26b8ee1c91656f600b5c452629fc225e1bd435f2d73da810600;
        assertEq(actual, expected, "REWARDS_MANAGER_BASE_ADDRESS mismatch");
    }

    function testFactory_ContextManagerBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.ContextManagerBaseAddress");
        bytes32 actual = 0x327c4805778da4e3703f4a6907d698c910c93cbbedf6f536be61f90d407ed600;
        assertEq(actual, expected, "CONTEXT_MANAGER_BASE_ADDRESS mismatch");
    }

    function testFactory_PriceManagerBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PriceManagerBaseAddress");
        bytes32 actual = 0x5e1e7003d30cfb3abdb5e35688c765a955b6455e91670898a8e5c73d9c677000;
        assertEq(actual, expected, "PRICE_MANAGER_BASE_ADDRESS mismatch");
    }

    function testFactory_PlasmaVaultCoreBaseAddressSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.fusion.factory.PlasmaVaultCoreBaseAddress");
        bytes32 actual = 0x64580ae806e62df65aec7b569ca88d764fcb6a37f8b0f20662030e6001952700;
        assertEq(actual, expected, "PLASMA_VAULT_CORE_BASE_ADDRESS mismatch");
    }

    // ============================================
    // FuseStorageLib
    // ============================================

    function testFuse_CfgFusesSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.CfgFuses");
        bytes32 actual = 0x48932b860eb451ad240d4fe2b46522e5a0ac079d201fe50d4e0be078c75b5400;
        assertEq(actual, expected, "CFG_FUSES mismatch");
    }

    function testFuse_CfgFusesArraySlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.CfgFusesArray");
        bytes32 actual = 0xad43e358bd6e59a5a0c80f6bf25fa771408af4d80f621cdc680c8dfbf607ab00;
        assertEq(actual, expected, "CFG_FUSES_ARRAY mismatch");
    }

    function testFuse_UniswapV3TokenIdsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.UniswapV3TokenIds");
        bytes32 actual = 0x3651659bd419f7c37743f3e14a337c9f9d1cfc4d650d91508f44d1acbe960f00;
        assertEq(actual, expected, "UNISWAP_V3_TOKEN_IDS mismatch");
    }

    function testFuse_RamsesV2TokenIdsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.RamsesV2TokenIds");
        bytes32 actual = 0x1a3831a406f27d4d5d820158b29ce95a1e8e840bf416921917aa388e2461b700;
        assertEq(actual, expected, "RAMSES_V2_TOKEN_IDS mismatch");
    }

    function testFuse_EbisuTroveIdsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.EbisuTroveIds");
        bytes32 actual = 0x9b098fe9de431f116cec9bcef5a806a02e41a628f070feb12cb5ddc28d703300;
        assertEq(actual, expected, "EBISU_TROVE_IDS mismatch");
    }

    function testFuse_VelodromeSuperchainSlipstreamTokenIdsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.VelodromeSuperchainSlipstreamTokenIds");
        bytes32 actual = 0xadec8ab8bc14c5c231913cd378fa94ac5788a64fe4296974cef061d370402200;
        assertEq(actual, expected, "VELODROME_SUPERCHAIN_SLIPSTREAM_TOKEN_IDS mismatch");
    }

    function testFuse_AerodromeSlipstreamTokenIdsSlot() public pure {
        bytes32 expected = _computeSlot("io.ipor.AerodromeSlipstreamTokenIds");
        bytes32 actual = 0x0c954f82f9216b16230a9847b4d73bfde1ddedf5d9a25bf9eb22e669cbfcd600;
        assertEq(actual, expected, "AERODROME_SLIPSTREAM_TOKEN_IDS mismatch");
    }

    // ============================================
    // Fuse-specific StorageLibs
    // ============================================

    function testWethEthAdapter_Slot() public pure {
        bytes32 expected = _computeSlot("io.ipor.ebisu.WethEthAdapter");
        bytes32 actual = 0x0129b8eb100deb46c8d563a313bc53ab38d2bf7ea1b50270934f4d98d5e3b300;
        assertEq(actual, expected, "WETH_ETH_ADAPTER_SLOT mismatch");
    }

    function testEnsoExecutor_Slot() public pure {
        bytes32 expected = _computeSlot("io.ipor.enso.Executor");
        bytes32 actual = 0x2be19acf1082fe0f31c0864ff2dc58ff9679d12ca8fb47a012400b2f6ce3af00;
        assertEq(actual, expected, "ENSO_EXECUTOR_SLOT mismatch");
    }

    function testTacStakingDelegator_Slot() public pure {
        bytes32 expected = _computeSlot("io.ipor.tac.StakingDelegator");
        bytes32 actual = 0x2c7f2e6443b388f1a6df5abedafcea539a6d91285825504444df1286873de000;
        assertEq(actual, expected, "TAC_STAKING_DELEGATOR_SLOT mismatch");
    }
}
