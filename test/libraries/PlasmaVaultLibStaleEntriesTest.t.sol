// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct, PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

/// @title PlasmaVaultLibStaleEntriesTest
/// @notice Tests for verifying proper cleanup of stale instant withdrawal fuses mapping entries
contract PlasmaVaultLibStaleEntriesTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address public atomist = address(this);
    address public alpha = address(0x1);

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    /// @notice Sets up the test environment with forked mainnet and price oracle middleware
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    /// @notice Tests that stale instant withdrawal fuse params are properly cleaned up when reconfiguring with fewer fuses
    /// @dev Verifies that when configuring from 5 fuses to 2 fuses, the entries for indices 2-4 are deleted
    function testShouldCleanupStaleInstantWithdrawalFusesParams() public {
        // given
        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        PlasmaVault plasmaVault = new PlasmaVault();
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager
            )
        );

        // Create 5 mock fuse addresses
        address[] memory mockFuses = new address[](5);
        for (uint256 i = 0; i < 5; ++i) {
            mockFuses[i] = address(uint160(0x1000 + i));
        }

        // Add fuses as supported
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(mockFuses);

        // Configure instant withdrawal fuses with 5 entries, each with unique params
        InstantWithdrawalFusesParamsStruct[] memory initialFusesCfg = new InstantWithdrawalFusesParamsStruct[](5);
        for (uint256 i = 0; i < 5; ++i) {
            bytes32[] memory params = new bytes32[](1);
            params[0] = bytes32(uint256(100 + i)); // Unique param for each fuse
            initialFusesCfg[i] = InstantWithdrawalFusesParamsStruct(mockFuses[i], params);
        }

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(initialFusesCfg);

        // Verify all 5 entries are set correctly
        for (uint256 i = 0; i < 5; ++i) {
            bytes32[] memory retrievedParams = IPlasmaVaultGovernance(address(plasmaVault))
                .getInstantWithdrawalFusesParams(mockFuses[i], i);
            assertEq(retrievedParams.length, 1, "Initial config should have 1 param");
            assertEq(retrievedParams[0], bytes32(uint256(100 + i)), "Initial param value should match");
        }

        // Reconfigure with only 2 fuses
        InstantWithdrawalFusesParamsStruct[] memory newFusesCfg = new InstantWithdrawalFusesParamsStruct[](2);
        for (uint256 i = 0; i < 2; ++i) {
            bytes32[] memory params = new bytes32[](1);
            params[0] = bytes32(uint256(200 + i)); // Different params for new config
            newFusesCfg[i] = InstantWithdrawalFusesParamsStruct(mockFuses[i], params);
        }

        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(newFusesCfg);

        // Verify new configuration (indices 0, 1) has correct params
        for (uint256 i = 0; i < 2; ++i) {
            bytes32[] memory retrievedParams = IPlasmaVaultGovernance(address(plasmaVault))
                .getInstantWithdrawalFusesParams(mockFuses[i], i);
            assertEq(retrievedParams.length, 1, "New config should have 1 param");
            assertEq(retrievedParams[0], bytes32(uint256(200 + i)), "New param value should match");
        }

        // **CRITICAL CHECK**: Verify that stale entries (indices 2, 3, 4) from OLD config are not accessible
        // After reconfiguration to 2 fuses, accessing indices >= 2 should revert with InstantWithdrawalFuseIndexOutOfBounds
        for (uint256 i = 2; i < 5; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(PlasmaVaultLib.InstantWithdrawalFuseIndexOutOfBounds.selector, i, 2)
            );
            IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFusesParams(mockFuses[i], i);
        }
    }

    /// @notice Creates an access manager with default roles if not specified
    /// @param usersToRoles_ The user roles configuration (uses defaults if superAdmin is zero address)
    /// @param redemptionDelay_ The redemption delay period in seconds
    /// @return The configured IporFusionAccessManager instance
    function createAccessManager(
        UsersToRoles memory usersToRoles_,
        uint256 redemptionDelay_
    ) public returns (IporFusionAccessManager) {
        if (usersToRoles_.superAdmin == address(0)) {
            usersToRoles_.superAdmin = atomist;
            usersToRoles_.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles_.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles_, redemptionDelay_, vm);
    }
}
