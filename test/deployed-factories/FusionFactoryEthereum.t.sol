// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {Roles} from "../../contracts/libraries/Roles.sol";

/// @dev Minimal interface transcribed from the implementation-bound T22 ABI.
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

    function getFusionFactoryIndex() external view returns (uint256);

    function getPlasmaVaultBaseAddress() external view returns (address);
}

interface IPilotFeeManager {
    function IPOR_DAO_MANAGEMENT_FEE() external view returns (uint256);

    function IPOR_DAO_PERFORMANCE_FEE() external view returns (uint256);

    function getIporDaoFeeRecipientAddress() external view returns (address);
}

/// @notice Compatibility test for the unchanged Ethereum FusionFactory deployment.
/// @dev It creates a new instance on an ephemeral fork but never upgrades, etches,
/// reconfigures, funds or grants roles on an existing contract.
contract FusionFactoryEthereumDeployedUsageTest is Test {
    address private constant PILOT_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 private constant FORK_BLOCK = 25937526;

    IPilotFusionFactory private factory;
    address private caller;
    address private vaultOwner;

    function setUp() public {
        uint256 forkBlock = vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK);
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), forkBlock);

        factory = IPilotFusionFactory(PILOT_FACTORY);
        caller = makeAddr("pilotCaller");
        vaultOwner = makeAddr("pilotVaultOwner");
    }

    function testCreateVaultThroughUnchangedPilotFactory() public {
        assertEq(block.chainid, 1, "wrong chain");
        assertEq(block.number, vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK), "fork runner block was ignored");
        assertTrue(PILOT_FACTORY.code.length > 0, "factory code missing");
        assertTrue(caller != vaultOwner, "caller and owner must remain distinct");

        (IPilotFusionFactory.FeePackage[] memory packages, bool isCustom) = factory.getBusinessClientFeePackages(
            caller
        );
        assertFalse(isCustom, "test caller unexpectedly has a custom package");
        assertTrue(packages.length > 0, "no effective fee package");
        uint256 previousIndex = factory.getFusionFactoryIndex();

        vm.prank(caller);
        IPilotFusionFactory.FusionInstance memory instance = factory.clone(
            "Agent Readiness USDC Vault",
            "arUSDC",
            USDC,
            1 days,
            vaultOwner,
            0
        );

        assertEq(instance.index, previousIndex + 1, "factory index mismatch");
        assertEq(instance.version, 8, "factory version mismatch");
        assertEq(instance.initialOwner, vaultOwner, "returned owner mismatch");
        assertEq(instance.underlyingToken, USDC, "returned asset mismatch");
        assertEq(instance.plasmaVaultBase, factory.getPlasmaVaultBaseAddress(), "vault base mismatch");
        assertEq(IERC4626(instance.plasmaVault).asset(), USDC, "vault asset mismatch");
        assertEq(IERC20Metadata(instance.plasmaVault).name(), "Agent Readiness USDC Vault", "vault name mismatch");
        assertEq(IERC20Metadata(instance.plasmaVault).symbol(), "arUSDC", "vault symbol mismatch");

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
