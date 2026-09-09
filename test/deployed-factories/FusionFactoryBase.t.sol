// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {Roles} from "../../contracts/libraries/Roles.sol";

/// @dev The same minimal interface the Ethereum pilot uses; both deployments
/// report factory version 8 and expose this creation operation.
interface IPilotFusionFactory {
    struct FeePackage {
        uint256 managementFee;
        uint256 performanceFee;
        address feeRecipient;
    }

    struct FusionInstance {
        uint256 index;
        uint256 version;
        string assetName;
        string assetSymbol;
        uint8 assetDecimals;
        address underlyingToken;
        string underlyingTokenSymbol;
        uint8 underlyingTokenDecimals;
        address initialOwner;
        address plasmaVault;
        address plasmaVaultBase;
        address accessManager;
        address feeManager;
        address rewardsManager;
        address withdrawManager;
        address contextManager;
        address priceManager;
    }

    function clone(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        uint256 redemptionDelayInSeconds,
        address owner,
        uint256 daoFeePackageIndex
    ) external returns (FusionInstance memory);

    function getBusinessClientFeePackages(
        address client
    ) external view returns (FeePackage[] memory packages, bool isCustom);

    function getFusionFactoryVersion() external view returns (uint256);

    function getPlasmaVaultBaseAddress() external view returns (address);
}

interface IPilotFeeManager {
    function IPOR_DAO_MANAGEMENT_FEE() external view returns (uint256);

    function IPOR_DAO_PERFORMANCE_FEE() external view returns (uint256);

    function getIporDaoFeeRecipientAddress() external view returns (address);
}

/// @notice Compatibility test for the unchanged Base FusionFactory deployment.
/// @dev Fixture type: deployed-usage. Same shape as the Ethereum test, with Base's
/// own factory address, its own USDC and its own pinned block — no address or token
/// is shared between the two networks.
contract FusionFactoryBaseDeployedUsageTest is Test {
    address private constant BASE_FACTORY = 0x1455717668fA96534f675856347A973fA907e922;
    address private constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    /// @dev The Ethereum pilot's factory, used only to assert the two are distinct.
    address private constant ETHEREUM_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    uint256 private constant FORK_BLOCK = 51000000;

    IPilotFusionFactory private factory;
    address private caller;
    address private vaultOwner;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK));

        factory = IPilotFusionFactory(BASE_FACTORY);
        caller = makeAddr("baseCaller");
        vaultOwner = makeAddr("baseVaultOwner");
    }

    function testCreateVaultThroughUnchangedBaseFactory() public {
        assertEq(block.chainid, 8453, "wrong chain");
        assertEq(block.number, vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK), "fork runner block was ignored");
        assertTrue(BASE_FACTORY != ETHEREUM_FACTORY, "the two networks must not share a factory address");
        assertTrue(BASE_FACTORY.code.length > 0, "factory code missing");
        assertEq(factory.getFusionFactoryVersion(), 8, "unexpected factory version on Base");

        (IPilotFusionFactory.FeePackage[] memory packages, bool isCustom) = factory.getBusinessClientFeePackages(
            caller
        );
        assertFalse(isCustom, "test caller unexpectedly has a custom package");
        assertTrue(packages.length > 0, "no effective fee package");

        vm.prank(caller);
        IPilotFusionFactory.FusionInstance memory instance = factory.clone(
            "Base Readiness USDC Vault",
            "brUSDC",
            BASE_USDC,
            1 days,
            vaultOwner,
            0
        );

        assertEq(instance.version, 8, "returned version mismatch");
        assertEq(instance.initialOwner, vaultOwner, "returned owner mismatch");
        assertEq(instance.underlyingToken, BASE_USDC, "returned asset mismatch");
        assertEq(instance.underlyingTokenSymbol, "USDC", "underlying is not Base USDC");
        assertEq(instance.plasmaVaultBase, factory.getPlasmaVaultBaseAddress(), "vault base mismatch");
        assertEq(IERC4626(instance.plasmaVault).asset(), BASE_USDC, "vault asset mismatch");
        assertEq(IERC20Metadata(instance.plasmaVault).name(), "Base Readiness USDC Vault", "vault name mismatch");

        address[7] memory created = [
            instance.plasmaVault,
            instance.accessManager,
            instance.feeManager,
            instance.rewardsManager,
            instance.withdrawManager,
            instance.contextManager,
            instance.priceManager
        ];
        for (uint256 i; i < created.length; ++i) {
            assertTrue(created[i] != address(0), "factory returned zero component");
            assertTrue(created[i].code.length > 0, "created component has no code");
        }

        (bool isOwner, uint32 ownerDelay) = IAccessManager(instance.accessManager).hasRole(
            Roles.OWNER_ROLE,
            vaultOwner
        );
        assertTrue(isOwner, "requested owner lacks OWNER_ROLE");
        assertEq(ownerDelay, 0, "unexpected owner execution delay");

        IPilotFeeManager feeManager = IPilotFeeManager(instance.feeManager);
        assertEq(feeManager.IPOR_DAO_MANAGEMENT_FEE(), packages[0].managementFee, "management fee mismatch");
        assertEq(feeManager.IPOR_DAO_PERFORMANCE_FEE(), packages[0].performanceFee, "performance fee mismatch");
        assertEq(feeManager.getIporDaoFeeRecipientAddress(), packages[0].feeRecipient, "fee recipient mismatch");
    }
}
