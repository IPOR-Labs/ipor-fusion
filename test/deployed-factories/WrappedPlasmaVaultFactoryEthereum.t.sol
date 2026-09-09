// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Minimal interfaces transcribed from the checkout's sources; the create
/// selector was confirmed present in the deployed implementation's runtime code.
interface IDeployedFusionFactory {
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
}

interface IDeployedWrappedPlasmaVaultFactory {
    function create(
        string memory name_,
        string memory symbol_,
        address plasmaVault_,
        address wrappedPlasmaVaultOwner_,
        address managementFeeAccount_,
        uint256 managementFeePercentage_,
        address performanceFeeAccount_,
        uint256 performanceFeePercentage_
    ) external returns (address wrappedPlasmaVault);
}

interface IWrappedPlasmaVault {
    struct PerformanceFeeData {
        address feeAccount;
        uint16 feeInPercentage;
    }

    struct ManagementFeeData {
        address feeAccount;
        uint16 feeInPercentage;
        uint32 lastUpdateTimestamp;
    }

    function PLASMA_VAULT() external view returns (address);

    function owner() external view returns (address);

    function configureManagementFee(address feeAccount_, uint256 feeInPercentage_) external;

    function getManagementFeeData() external view returns (ManagementFeeData memory);

    function getPerformanceFeeData() external view returns (PerformanceFeeData memory);
}

/// @notice Compatibility test for the deployed WrappedPlasmaVaultFactory — the
/// plain wrapper variant, not the whitelist one.
/// @dev Fixture type: deployed-usage. Both deployed factories are used unchanged:
/// no upgrade, no etch, no role granted, no funding. Everything created lives only
/// on the ephemeral fork.
contract WrappedPlasmaVaultFactoryEthereumTest is Test {
    address private constant FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant WRAPPER_FACTORY = 0xb17a9D70a73e0DcFfc12563Bcc0c1D68F3F353C8;
    /// @dev The whitelist variant is a different deployment with different rules.
    address private constant WHITELIST_WRAPPER_FACTORY = 0x30378C767A5F2c444287bCbdbdB29a73AF125151;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 private constant FORK_BLOCK = 25937526;
    uint256 private constant MANAGEMENT_FEE = 100; // 1% — the wrapper uses 10000 = 100%.
    uint256 private constant PERFORMANCE_FEE = 1000; // 10%

    IDeployedFusionFactory.FusionInstance private instance;
    address private wrapperOwner;
    address private managementFeeAccount;
    address private performanceFeeAccount;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK));

        wrapperOwner = makeAddr("wrapperOwner");
        managementFeeAccount = makeAddr("wrapperManagementFeeAccount");
        performanceFeeAccount = makeAddr("wrapperPerformanceFeeAccount");

        vm.prank(makeAddr("wrapperCaller"));
        instance = IDeployedFusionFactory(FUSION_FACTORY).clone(
            "Wrapped Pilot USDC Vault",
            "wpUSDC",
            USDC,
            1 hours,
            makeAddr("plasmaVaultOwner"),
            0
        );
    }

    function testShouldCreateAWrapperBoundToTheVaultWithTheRequestedFees() public {
        assertTrue(WRAPPER_FACTORY.code.length > 0, "wrapper factory has no code");
        assertTrue(WHITELIST_WRAPPER_FACTORY != WRAPPER_FACTORY, "the two variants must be different deployments");

        vm.prank(makeAddr("wrapperCaller"));
        address wrapper = IDeployedWrappedPlasmaVaultFactory(WRAPPER_FACTORY).create(
            "Wrapped Pilot USDC",
            "wUSDC",
            instance.plasmaVault,
            wrapperOwner,
            managementFeeAccount,
            MANAGEMENT_FEE,
            performanceFeeAccount,
            PERFORMANCE_FEE
        );

        assertTrue(wrapper != address(0) && wrapper.code.length > 0, "wrapper was not created");

        // Binding to the vault, in both directions that can be read.
        assertEq(IWrappedPlasmaVault(wrapper).PLASMA_VAULT(), instance.plasmaVault, "wrapper wraps another vault");
        assertEq(
            IERC4626(wrapper).asset(),
            IERC4626(instance.plasmaVault).asset(),
            "wrapper asset differs from the vault's"
        );
        assertEq(IERC4626(wrapper).asset(), USDC, "wrapper asset is not USDC");
        assertEq(IERC20Metadata(wrapper).name(), "Wrapped Pilot USDC", "wrapper name mismatch");
        assertEq(IERC20Metadata(wrapper).symbol(), "wUSDC", "wrapper symbol mismatch");

        // Ownership and fees are the wrapper's own, separate from the vault's.
        assertEq(IWrappedPlasmaVault(wrapper).owner(), wrapperOwner, "wrapper owner mismatch");
        IWrappedPlasmaVault.ManagementFeeData memory management = IWrappedPlasmaVault(wrapper).getManagementFeeData();
        IWrappedPlasmaVault.PerformanceFeeData memory performance = IWrappedPlasmaVault(wrapper)
            .getPerformanceFeeData();
        assertEq(management.feeAccount, managementFeeAccount, "management fee account mismatch");
        assertEq(uint256(management.feeInPercentage), MANAGEMENT_FEE, "management fee mismatch");
        assertEq(performance.feeAccount, performanceFeeAccount, "performance fee account mismatch");
        assertEq(uint256(performance.feeInPercentage), PERFORMANCE_FEE, "performance fee mismatch");
    }

    function testShouldRestrictWrapperConfigurationToItsOwner() public {
        vm.prank(makeAddr("wrapperCaller"));
        address wrapper = IDeployedWrappedPlasmaVaultFactory(WRAPPER_FACTORY).create(
            "Wrapped Pilot USDC",
            "wUSDC",
            instance.plasmaVault,
            wrapperOwner,
            managementFeeAccount,
            MANAGEMENT_FEE,
            performanceFeeAccount,
            PERFORMANCE_FEE
        );

        // The vault's own owner has no power over the wrapper.
        vm.prank(instance.initialOwner);
        vm.expectRevert();
        IWrappedPlasmaVault(wrapper).configureManagementFee(managementFeeAccount, 200);

        vm.prank(wrapperOwner);
        IWrappedPlasmaVault(wrapper).configureManagementFee(managementFeeAccount, 200);
        assertEq(
            uint256(IWrappedPlasmaVault(wrapper).getManagementFeeData().feeInPercentage),
            200,
            "owner could not configure the fee"
        );
    }

    function testShouldRejectInvalidWrapperInputs() public {
        vm.startPrank(makeAddr("wrapperCaller"));

        vm.expectRevert();
        IDeployedWrappedPlasmaVaultFactory(WRAPPER_FACTORY).create(
            "Wrapped Pilot USDC",
            "wUSDC",
            address(0),
            wrapperOwner,
            managementFeeAccount,
            MANAGEMENT_FEE,
            performanceFeeAccount,
            PERFORMANCE_FEE
        );

        // 10000 is 100%; anything above it is refused.
        vm.expectRevert();
        IDeployedWrappedPlasmaVaultFactory(WRAPPER_FACTORY).create(
            "Wrapped Pilot USDC",
            "wUSDC",
            instance.plasmaVault,
            wrapperOwner,
            managementFeeAccount,
            10001,
            performanceFeeAccount,
            PERFORMANCE_FEE
        );

        vm.stopPrank();
    }
}
