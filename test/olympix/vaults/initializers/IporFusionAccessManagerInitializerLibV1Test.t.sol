// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {
    IporFusionAccessManagerInitializerLibV1Caller
} from "test/test_helpers/lib_callers/IporFusionAccessManagerInitializerLibV1Caller.sol";
import {
    DataForInitialization,
    PlasmaVaultAddress
} from "contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";

/// @dev Target contract: contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol
///      (via IporFusionAccessManagerInitializerLibV1Caller harness)
contract IporFusionAccessManagerInitializerLibV1Test is
    OlympixUnitTest("IporFusionAccessManagerInitializerLibV1Caller")
{
    IporFusionAccessManagerInitializerLibV1Caller internal caller;

    function setUp() public override {
        caller = new IporFusionAccessManagerInitializerLibV1Caller();
    }

    function _emptyData() internal returns (DataForInitialization memory data) {
        data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: makeAddr("plasmaVault"),
            accessManager: makeAddr("accessManager"),
            rewardsClaimManager: makeAddr("rewardsClaimManager"),
            withdrawManager: makeAddr("withdrawManager"),
            feeManager: makeAddr("feeManager"),
            contextManager: makeAddr("contextManager"),
            priceOracleMiddlewareManager: makeAddr("priceOracleMiddlewareManager")
        });
    }

    function test_example_generate_returnsRoleAndFunctionConfig() public {
        DataForInitialization memory data = _emptyData();

        InitializationData memory result = caller.generateInitializeIporPlasmaVault(data);

        assertGt(result.roleToFunctions.length, 0, "function access configuration should not be empty");
        assertGt(result.adminRoles.length, 0, "role hierarchy configuration should not be empty");
    }

    function test_example_generate_assignsProvidedAdmins() public {
        DataForInitialization memory data = _emptyData();
        address admin = makeAddr("admin");
        data.admins = new address[](1);
        data.admins[0] = admin;

        InitializationData memory result = caller.generateInitializeIporPlasmaVault(data);

        bool adminFound;
        for (uint256 i; i < result.accountToRoles.length; i++) {
            if (result.accountToRoles[i].account == admin) {
                adminFound = true;
                break;
            }
        }
        assertTrue(adminFound, "provided admin should receive a role assignment");
    }

    function test_example_generate_moreAccountsMoreAssignments() public {
        DataForInitialization memory base = _emptyData();
        InitializationData memory baseline = caller.generateInitializeIporPlasmaVault(base);

        DataForInitialization memory extended = _emptyData();
        extended.alphas = new address[](2);
        extended.alphas[0] = makeAddr("alpha1");
        extended.alphas[1] = makeAddr("alpha2");
        InitializationData memory result = caller.generateInitializeIporPlasmaVault(extended);

        assertEq(
            result.accountToRoles.length,
            baseline.accountToRoles.length + 2,
            "each provided alpha should add exactly one role assignment"
        );
    }
}
