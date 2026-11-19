// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    ConfigureInstantWithdrawalFuse,
    ConfigureInstantWithdrawalFuseEnterData
} from "../../contracts/fuses/maintenance/ConfigureInstantWithdrawalFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct, PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

/// @title PlasmaVaultLibStaleEntriesTest
/// @notice Tests for verifying proper cleanup of stale instant withdrawal fuses mapping entries
contract PlasmaVaultLibStaleEntriesTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address private constant FUSE_A = address(0x2000);
    address private constant FUSE_X = address(0x2001);
    /// @dev CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS of PlasmaVaultStorageLib
    bytes32 private constant INSTANT_WITHDRAWAL_FUSES_PARAMS_SLOT =
        0x45a704819a9dcb1bb5b8cff129eda642cf0e926a9ef104e27aa53f1d1fa47b00;

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

        PlasmaVault plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
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

    /// @notice A key outside the current list holds params written by an older build; a governance write that reuses it must replace them
    function testShouldNotAppendToStaleParamsWrittenByOlderLogicViaGovernance() public {
        // given
        (PlasmaVault vault, ) = _createVaultWithStaleKey();

        // when
        IPlasmaVaultGovernance(address(vault)).configureInstantWithdrawalFuses(_staleReuseConfig());

        // then
        _assertReplacedParams(vault);
    }

    /// @notice Same as above, but the new write goes through ConfigureInstantWithdrawalFuse.enter
    function testShouldNotAppendToStaleParamsWrittenByOlderLogicViaConfigureFuse() public {
        // given
        (PlasmaVault vault, ConfigureInstantWithdrawalFuse configureFuse) = _createVaultWithStaleKey();
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(configureFuse),
            data: abi.encodeWithSelector(
                ConfigureInstantWithdrawalFuse.enter.selector,
                ConfigureInstantWithdrawalFuseEnterData({fuses: _staleReuseConfig()})
            )
        });

        // when
        vm.prank(alpha);
        vault.execute(actions);

        // then
        _assertReplacedParams(vault);
    }

    function _staleReuseConfig() private pure returns (InstantWithdrawalFusesParamsStruct[] memory cfg) {
        cfg = new InstantWithdrawalFusesParamsStruct[](2);
        bytes32[] memory a = new bytes32[](1);
        a[0] = bytes32(uint256(0xa1));
        bytes32[] memory x = new bytes32[](1);
        x[0] = bytes32(uint256(0xb1));
        cfg[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, a);
        cfg[1] = InstantWithdrawalFusesParamsStruct(FUSE_X, x);
    }

    function _assertReplacedParams(PlasmaVault vault_) private view {
        bytes32[] memory p0 = IPlasmaVaultGovernance(address(vault_)).getInstantWithdrawalFusesParams(FUSE_A, 0);
        assertEq(p0.length, 1, "entry 0 length");
        assertEq(p0[0], bytes32(uint256(0xa1)), "entry 0 value");
        bytes32[] memory p1 = IPlasmaVaultGovernance(address(vault_)).getInstantWithdrawalFusesParams(FUSE_X, 1);
        assertEq(p1.length, 1, "stale params must not remain after the key is reused");
        assertEq(p1[0], bytes32(uint256(0xb1)), "entry 1 value");
    }

    /// @dev Builds a vault whose current list is [FUSE_A] and plants [s0, s1] under the key (FUSE_X, 1), as an older build would have left it
    function _createVaultWithStaleKey()
        private
        returns (PlasmaVault vault, ConfigureInstantWithdrawalFuse configureFuse)
    {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        vault = PlasmaVaultCloneLib.newPlasmaVault();
        vault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(vault), accessManager, withdrawManager);

        configureFuse = new ConfigureInstantWithdrawalFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        address[] memory fuses = new address[](3);
        fuses[0] = FUSE_A;
        fuses[1] = FUSE_X;
        fuses[2] = address(configureFuse);
        IPlasmaVaultGovernance(address(vault)).addFuses(fuses);
        IPlasmaVaultGovernance(address(vault)).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET))
        );

        // current list: only FUSE_A at index 0
        InstantWithdrawalFusesParamsStruct[] memory initial = new InstantWithdrawalFusesParamsStruct[](1);
        bytes32[] memory a = new bytes32[](1);
        a[0] = bytes32(uint256(0x01));
        initial[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, a);
        IPlasmaVaultGovernance(address(vault)).configureInstantWithdrawalFuses(initial);

        // plant the old-logic leftover under (FUSE_X, 1): array length 2 with two elements
        bytes32 arraySlot = keccak256(
            abi.encode(keccak256(abi.encodePacked(FUSE_X, uint256(1))), INSTANT_WITHDRAWAL_FUSES_PARAMS_SLOT)
        );
        vm.store(address(vault), arraySlot, bytes32(uint256(2)));
        bytes32 dataSlot = keccak256(abi.encode(arraySlot));
        vm.store(address(vault), dataSlot, bytes32(uint256(0xdead01)));
        vm.store(address(vault), bytes32(uint256(dataSlot) + 1), bytes32(uint256(0xdead02)));
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
