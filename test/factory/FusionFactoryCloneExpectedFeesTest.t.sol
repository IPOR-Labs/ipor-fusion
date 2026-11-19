// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Roles} from "../../contracts/libraries/Roles.sol";
import {RedemptionDelayLib} from "../../contracts/managers/access/RedemptionDelayLib.sol";
import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";

contract FusionFactoryCloneExpectedFeesTest is Test {
    FusionFactory public fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses public factoryAddresses;
    address public plasmaVaultBase;
    address public priceOracleMiddleware;
    address public burnRequestFeeFuse;
    address public burnRequestFeeBalanceFuse;
    MockERC20 public underlyingToken;
    address public owner;
    address public daoFeeManager;
    address public maintenanceManager;
    address public daoFeeRecipient;

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

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
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

        // Setup global DAO fee packages
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);

        // Setup base addresses for cloning
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

    error DaoFeePackageMismatch(
        uint256 index,
        FusionFactoryStorageLib.FeePackage expected,
        FusionFactoryStorageLib.FeePackage actual
    );

    /// @dev Low-level calls keep the test compilable against a base without the new selectors
    function _callFactory(bytes memory data_) private returns (FusionFactoryLogicLib.FusionInstance memory) {
        (bool ok, bytes memory ret) = address(fusionFactory).call(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return abi.decode(ret, (FusionFactoryLogicLib.FusionInstance));
    }

    function _cloneExpected(
        string memory name_,
        string memory symbol_,
        address asset_,
        uint256 delay_,
        address owner_,
        uint256 index_,
        FusionFactoryStorageLib.FeePackage memory expected_
    ) private returns (FusionFactoryLogicLib.FusionInstance memory) {
        return
            _callFactory(
                abi.encodeWithSignature(
                    "cloneWithExpectedFees(string,string,address,uint256,address,uint256,(uint256,uint256,address))",
                    name_,
                    symbol_,
                    asset_,
                    delay_,
                    owner_,
                    index_,
                    expected_
                )
            );
    }

    function _cloneSupervisedExpected(
        string memory name_,
        string memory symbol_,
        address asset_,
        uint256 delay_,
        address owner_,
        uint256 index_,
        FusionFactoryStorageLib.FeePackage memory expected_
    ) private returns (FusionFactoryLogicLib.FusionInstance memory) {
        return
            _callFactory(
                abi.encodeWithSignature(
                    "cloneSupervisedWithExpectedFees(string,string,address,uint256,address,uint256,(uint256,uint256,address))",
                    name_,
                    symbol_,
                    asset_,
                    delay_,
                    owner_,
                    index_,
                    expected_
                )
            );
    }

    function _pkg(
        uint256 mgmt_,
        uint256 perf_,
        address recipient_
    ) private pure returns (FusionFactoryStorageLib.FeePackage memory) {
        return
            FusionFactoryStorageLib.FeePackage({managementFee: mgmt_, performanceFee: perf_, feeRecipient: recipient_});
    }

    function _replaceGlobalPackage(FusionFactoryStorageLib.FeePackage memory pkg_) private {
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = pkg_;
        vm.prank(daoFeeManager);
        fusionFactory.setDaoFeePackages(packages);
    }

    function testShouldCloneWithMatchingExpectedFeePackage() public {
        // given
        FusionFactoryStorageLib.FeePackage memory expected = _pkg(333, 777, daoFeeRecipient);

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = _cloneExpected(
            "Vault",
            "VLT",
            address(underlyingToken),
            1 days,
            owner,
            0,
            expected
        );

        // then
        assertEq(FeeManager(instance.feeManager).getIporDaoFeeRecipientAddress(), daoFeeRecipient);
        assertEq(FeeManager(instance.feeManager).IPOR_DAO_MANAGEMENT_FEE(), 333);
        assertEq(FeeManager(instance.feeManager).IPOR_DAO_PERFORMANCE_FEE(), 777);
    }

    function testShouldRevertWhenPackagesReplacedAfterCallerRead() public {
        // given - the caller read package 0, then the DAO manager replaced it
        FusionFactoryStorageLib.FeePackage memory expected = _pkg(333, 777, daoFeeRecipient);
        FusionFactoryStorageLib.FeePackage memory replaced = _pkg(500, 5000, makeAddr("attacker"));
        _replaceGlobalPackage(replaced);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(DaoFeePackageMismatch.selector, 0, expected, replaced));
        _cloneExpected("Vault", "VLT", address(underlyingToken), 1 days, owner, 0, expected);
    }

    function testShouldRevertWhenOnlyRecipientDiffers() public {
        // given
        FusionFactoryStorageLib.FeePackage memory expected = _pkg(333, 777, daoFeeRecipient);
        FusionFactoryStorageLib.FeePackage memory replaced = _pkg(333, 777, makeAddr("other"));
        _replaceGlobalPackage(replaced);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(DaoFeePackageMismatch.selector, 0, expected, replaced));
        _cloneExpected("Vault", "VLT", address(underlyingToken), 1 days, owner, 0, expected);
    }

    function testOldCloneStillTakesWhateverPackageIsStoredAtExecution() public {
        // given - pins the behaviour of the unchanged entry point: no check against what the caller read
        address newRecipient = makeAddr("attacker");
        _replaceGlobalPackage(_pkg(500, 5000, newRecipient));

        // when
        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Vault",
            "VLT",
            address(underlyingToken),
            1 days,
            owner,
            0
        );

        // then
        assertEq(FeeManager(instance.feeManager).getIporDaoFeeRecipientAddress(), newRecipient);
        assertEq(FeeManager(instance.feeManager).IPOR_DAO_PERFORMANCE_FEE(), 5000);
    }

    function testShouldRevertOnOutOfBoundsIndexWithNewEntryPoint() public {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(FusionFactoryLogicLib.DaoFeePackageIndexOutOfBounds.selector, 1, 1));
        _cloneExpected("Vault", "VLT", address(underlyingToken), 1 days, owner, 1, _pkg(333, 777, daoFeeRecipient));
    }

    function testShouldCompareAgainstBusinessClientPackage() public {
        // given - a business client's own package takes precedence over the global one
        address client = makeAddr("client");
        address clientRecipient = makeAddr("clientRecipient");
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = _pkg(100, 500, clientRecipient);
        vm.prank(daoFeeManager);
        fusionFactory.setBusinessClientFeePackages(client, packages);

        // when / then - the global package no longer matches for this client
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(DaoFeePackageMismatch.selector, 0, _pkg(333, 777, daoFeeRecipient), packages[0])
        );
        _cloneExpected("Vault", "VLT", address(underlyingToken), 1 days, owner, 0, _pkg(333, 777, daoFeeRecipient));

        // and the client package matches
        vm.prank(client);
        FusionFactoryLogicLib.FusionInstance memory instance = _cloneExpected(
            "Vault",
            "VLT",
            address(underlyingToken),
            1 days,
            owner,
            0,
            packages[0]
        );
        assertEq(FeeManager(instance.feeManager).getIporDaoFeeRecipientAddress(), clientRecipient);
    }

    function testShouldCloneSupervisedWithExpectedFees() public {
        // given
        FusionFactoryStorageLib.FeePackage memory expected = _pkg(333, 777, daoFeeRecipient);

        // when
        vm.prank(maintenanceManager);
        FusionFactoryLogicLib.FusionInstance memory instance = _cloneSupervisedExpected(
            "Vault",
            "VLT",
            address(underlyingToken),
            1 days,
            owner,
            0,
            expected
        );

        // then
        assertEq(FeeManager(instance.feeManager).getIporDaoFeeRecipientAddress(), daoFeeRecipient);

        // and a mismatch reverts
        FusionFactoryStorageLib.FeePackage memory replaced = _pkg(1, 1, makeAddr("x"));
        _replaceGlobalPackage(replaced);
        vm.prank(maintenanceManager);
        vm.expectRevert(abi.encodeWithSelector(DaoFeePackageMismatch.selector, 0, expected, replaced));
        _cloneSupervisedExpected("Vault", "VLT", address(underlyingToken), 1 days, owner, 0, expected);
    }

    function testShouldRejectCloneSupervisedWithExpectedFeesWithoutRole() public {
        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(this),
                fusionFactory.MAINTENANCE_MANAGER_ROLE()
            )
        );
        _cloneSupervisedExpected(
            "Vault",
            "VLT",
            address(underlyingToken),
            1 days,
            owner,
            0,
            _pkg(333, 777, daoFeeRecipient)
        );
    }
}
