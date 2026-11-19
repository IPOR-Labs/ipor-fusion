// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {IPlasmaVault} from "../../contracts/interfaces/IPlasmaVault.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {
    InitializationData,
    RoleToFunction
} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @title Tests that the access manager initializer maps `realizeManagementFee` to the ALPHA role
contract InitializeAccessManagerRealizeManagementFeeTest is Test {
    /// @dev Base role-to-function entries written for the plasma vault itself (was 43 before realizeManagementFee, 44 before realizePerformanceFee)
    uint256 private constant BASE_ROLES_TO_FUNCTION_LENGTH = 45;
    /// @dev Entries added by the rewards claim (8), withdraw (8, two releaseFunds overloads since IL-9653), fee (6), context (10) and price oracle (9) managers
    uint256 private constant MANAGERS_ROLES_TO_FUNCTION_LENGTH = 8 + 8 + 6 + 10 + 9;

    address private constant ADMIN = address(0x1);
    address private constant PLASMA_VAULT = address(0x123);
    address private constant WITHDRAW_MANAGER = address(0x126);

    IporFusionAccessManager private _accessManager;

    function setUp() public {
        _accessManager = new IporFusionAccessManager(ADMIN, 0);
    }

    function testShouldGenerateBaseEntriesPlusManagerEntries() public {
        // given
        DataForInitialization memory data = _dataForInitialization();

        // when
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // then
        assertEq(
            initData.roleToFunctions.length,
            BASE_ROLES_TO_FUNCTION_LENGTH + MANAGERS_ROLES_TO_FUNCTION_LENGTH,
            "44 base entries plus manager entries"
        );
    }

    function testShouldMapRealizeManagementFeeToAlphaRoleExactlyOnce() public {
        // given
        DataForInitialization memory data = _dataForInitialization();

        // when
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // then
        uint256 matches;
        for (uint256 i; i < initData.roleToFunctions.length; ++i) {
            RoleToFunction memory entry = initData.roleToFunctions[i];
            if (entry.functionSelector == IPlasmaVault.realizeManagementFee.selector) {
                ++matches;
                assertEq(entry.target, PLASMA_VAULT, "target is the plasma vault");
                assertEq(entry.roleId, Roles.ALPHA_ROLE, "role is ALPHA_ROLE");
                assertEq(entry.minimalExecutionDelay, 0, "no minimal execution delay");
            }
        }
        assertEq(matches, 1, "exactly one realizeManagementFee entry");
    }

    function testShouldMapBothReleaseFundsOverloadsToAlphaRoleExactlyOnce() public {
        // given
        DataForInitialization memory data = _dataForInitialization();
        bytes4 twoArgs = bytes4(keccak256("releaseFunds(uint256,uint256)"));
        bytes4 threeArgs = bytes4(keccak256("releaseFunds(uint256,uint256,uint256)"));

        // when
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // then
        uint256 twoArgsMatches;
        uint256 threeArgsMatches;
        for (uint256 i; i < initData.roleToFunctions.length; ++i) {
            RoleToFunction memory entry = initData.roleToFunctions[i];
            if (entry.target != WITHDRAW_MANAGER) continue;
            if (entry.functionSelector == twoArgs) {
                ++twoArgsMatches;
                assertEq(entry.roleId, Roles.ALPHA_ROLE, "releaseFunds(uint256,uint256) role is ALPHA_ROLE");
                assertEq(entry.minimalExecutionDelay, 0, "releaseFunds(uint256,uint256) no delay");
            } else if (entry.functionSelector == threeArgs) {
                ++threeArgsMatches;
                assertEq(entry.roleId, Roles.ALPHA_ROLE, "releaseFunds(uint256,uint256,uint256) role is ALPHA_ROLE");
                assertEq(entry.minimalExecutionDelay, 0, "releaseFunds(uint256,uint256,uint256) no delay");
            }
        }
        assertEq(twoArgsMatches, 1, "exactly one releaseFunds(uint256,uint256) entry");
        assertEq(threeArgsMatches, 1, "exactly one releaseFunds(uint256,uint256,uint256) entry");
    }

    function testShouldSetTargetFunctionRoleOfBothReleaseFundsOverloadsAfterInitialization() public {
        // given
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            _dataForInitialization()
        );

        // when
        vm.prank(ADMIN);
        _accessManager.initialize(initData);

        // then
        assertEq(
            _accessManager.getTargetFunctionRole(WITHDRAW_MANAGER, bytes4(keccak256("releaseFunds(uint256,uint256)"))),
            Roles.ALPHA_ROLE,
            "releaseFunds(uint256,uint256) requires ALPHA_ROLE"
        );
        assertEq(
            _accessManager.getTargetFunctionRole(
                WITHDRAW_MANAGER,
                bytes4(keccak256("releaseFunds(uint256,uint256,uint256)"))
            ),
            Roles.ALPHA_ROLE,
            "releaseFunds(uint256,uint256,uint256) requires ALPHA_ROLE"
        );
    }

    function testShouldNotLeaveEmptyRoleToFunctionEntries() public {
        // given
        DataForInitialization memory data = _dataForInitialization();

        // when
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // then
        for (uint256 i; i < initData.roleToFunctions.length; ++i) {
            assertTrue(
                initData.roleToFunctions[i].target != address(0) &&
                    initData.roleToFunctions[i].functionSelector != bytes4(0),
                "empty roleToFunctions entry"
            );
        }
    }

    function testShouldSetTargetFunctionRoleOfRealizeManagementFeeAfterInitialization() public {
        // given
        DataForInitialization memory data = _dataForInitialization();
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // when
        vm.prank(ADMIN);
        _accessManager.initialize(initData);

        // then
        assertEq(
            _accessManager.getTargetFunctionRole(PLASMA_VAULT, IPlasmaVault.realizeManagementFee.selector),
            Roles.ALPHA_ROLE,
            "realizeManagementFee requires ALPHA_ROLE"
        );
    }

    function _dataForInitialization() private pure returns (DataForInitialization memory data) {
        data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: PLASMA_VAULT,
            accessManager: address(0x124),
            rewardsClaimManager: address(0x125),
            withdrawManager: WITHDRAW_MANAGER,
            feeManager: address(0x127),
            contextManager: address(0x128),
            priceOracleMiddlewareManager: address(0x129)
        });
    }
}
