// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @title Tests `realizeManagementFee` access control on a vault cloned by the FusionFactory
/// @dev The clone is initialised through the current `IporFusionAccessManagerInitializerLibV1`, so these tests
///      prove the ALPHA_ROLE mapping reaches factory-created vaults.
contract FusionFactoryRealizeManagementFeeTest is Test {
    FusionFactory public fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses public factoryAddresses;
    address public plasmaVaultBase;
    address public priceOracleMiddleware;
    address public burnRequestFeeFuse;
    address public burnRequestFeeBalanceFuse;
    MockERC20 public underlyingToken;
    address public daoFeeManager;
    address public maintenanceManager;
    address public owner;
    address public daoFeeRecipient;

    FusionFactoryLogicLib.FusionInstance internal instance;
    address public atomist;
    address public alpha;
    address public depositor;
    address public outsider;

    function setUp() public {
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        owner = address(0x777);
        daoFeeRecipient = address(0x888);
        daoFeeManager = address(0x111);
        maintenanceManager = address(0x222);

        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware oracleImplementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(oracleImplementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        FusionFactory fusionFactoryImplementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);

        _updateBaseAddresses();
        _cloneAndSetupRoles();
    }

    function _updateBaseAddresses() private {
        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(1);

        address accessManagerBase = address(new IporFusionAccessManager(owner, 1 seconds));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address contextManagerBase = address(new ContextManager(owner, approvedAddresses));
        address priceManagerBase = address(new PriceOracleMiddlewareManager(owner, priceOracleMiddleware));

        address plasmaVaultCoreBase = address(new PlasmaVault());

        address rewardsManagerBase = address(new RewardsClaimManager(owner, plasmaVaultCoreBase));

        vm.prank(maintenanceManager);
        fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
    }

    /// @dev A fresh clone with a management fee, an ALPHA and a depositor on the whitelist
    function _cloneAndSetupRoles() private {
        instance = fusionFactory.clone("Test Asset", "TEST", address(underlyingToken), 1 seconds, owner, 0);

        atomist = makeAddr("atomist");
        alpha = makeAddr("alpha");
        depositor = makeAddr("depositor");
        outsider = makeAddr("outsider");

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();
        vm.startPrank(atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        underlyingToken.mint(depositor, 1_000_000e18);
        vm.startPrank(depositor);
        underlyingToken.approve(instance.plasmaVault, type(uint256).max);
        PlasmaVault(instance.plasmaVault).deposit(1_000_000e18, depositor);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
    }

    function testShouldRealizeManagementFeeWhenCalledByAlpha() public {
        // given
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = IPlasmaVaultGovernance(instance.plasmaVault)
            .getManagementFeeData();
        assertGt(feeData.feeInPercentage, 0, "the clone charges a management fee");
        uint256 feeSharesBefore = PlasmaVault(instance.plasmaVault).balanceOf(feeData.feeAccount);

        // when
        vm.recordLogs();
        vm.prank(alpha);
        uint256 feeShares = PlasmaVault(instance.plasmaVault).realizeManagementFee();

        // then
        assertGt(feeShares, 0, "fee shares returned");
        assertEq(
            PlasmaVault(instance.plasmaVault).balanceOf(feeData.feeAccount) - feeSharesBefore,
            feeShares,
            "fee account grows by the returned shares"
        );
        assertEq(_sharesInManagementFeeRealizedEvent(vm.getRecordedLogs()), feeShares, "event carries minted shares");
    }

    function testShouldRevertRealizeManagementFeeWhenCalledByOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        vm.prank(owner);
        PlasmaVault(instance.plasmaVault).realizeManagementFee();
    }

    function testShouldRevertRealizeManagementFeeWhenCalledByAtomistWithoutAlphaRole() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, atomist));
        vm.prank(atomist);
        PlasmaVault(instance.plasmaVault).realizeManagementFee();
    }

    function testShouldRevertRealizeManagementFeeWhenCalledByAccountOutsideRoles() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider));
        vm.prank(outsider);
        PlasmaVault(instance.plasmaVault).realizeManagementFee();
    }

    /// @dev Returns the shares of the single `ManagementFeeRealized` event emitted by the vault, reverts the test if none
    function _sharesInManagementFeeRealizedEvent(Vm.Log[] memory logs_) private view returns (uint256 shares) {
        uint256 found;
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == instance.plasmaVault &&
                logs_[i].topics[0] == PlasmaVault.ManagementFeeRealized.selector
            ) {
                ++found;
                (, shares) = abi.decode(logs_[i].data, (uint256, uint256));
            }
        }
        assertEq(found, 1, "exactly one ManagementFeeRealized emitted");
    }
}
