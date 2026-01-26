// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {EulerV2BatchFuse, EulerV2BatchItem, EulerV2BatchFuseData} from "../../../contracts/fuses/euler/EulerV2BatchFuse.sol";
import {FusionFactoryLib} from "../../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IVault} from "ethereum-vault-connector/src/interfaces/IVault.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {EmptyFuse} from "./EmptyFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

contract EulerV2Batch is Test {
    address public constant EULER_V2_EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address public constant EULER_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant ATOMIST = TestAddresses.ATOMIST;
    address public constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address public constant ALPHA = TestAddresses.ALPHA;

    address public constant FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant BALANCE_FUSE_EULERV2 = 0xAE9a37DD9229687662834e6696e396e7837BAABD;

    EulerV2BatchFuse public fuse;
    EmptyFuse public emptyFuse;

    address public plasmaVault;
    address public accessManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23485836);

        FusionFactory fusionFactory = FusionFactory(FUSION_FACTORY);

        // Setup fee packages before creating vault
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "EulerV2Batch",
            "EULERV2BATCH",
            USDC,
            0,
            TestAddresses.OWNER,
            0
        );

        plasmaVault = fusionInstance.plasmaVault;
        accessManager = fusionInstance.accessManager;

        fuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, EULER_V2_EVC);
        emptyFuse = new EmptyFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);

        ZeroBalanceFuse zeroBalanceFuse = new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);

        _setupRoles();
        _grantMarketSubstratesForEuler();

        address[] memory fuses = new address[](2);
        fuses[0] = address(fuse);
        fuses[1] = address(emptyFuse);
        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).addFuses(fuses);
        vm.stopPrank();

        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(IporFusionMarkets.EULER_V2, BALANCE_FUSE_EULERV2);
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(zeroBalanceFuse)
        );
        vm.stopPrank();

        CallbackHandlerEuler callbackHandler = new CallbackHandlerEuler();
        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).updateCallbackHandler(
            address(callbackHandler),
            EULER_V2_EVC,
            CallbackHandlerEuler.onEulerFlashLoan.selector
        );
        vm.stopPrank();
    }

    function testShouldPassExampleFromEulerDocs() public {
        // TODO: Implement test with proper batch items
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](5);

        address[] memory assetsForApprovals = new address[](1);
        assetsForApprovals[0] = USDC;

        address[] memory eulerVaultsForApprovals = new address[](1);
        eulerVaultsForApprovals[0] = EULER_VAULT;

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory mockActions = new FuseAction[](1);
        mockActions[0] = FuseAction(address(emptyFuse), abi.encodeWithSelector(EmptyFuse.enter.selector));

        batchItems[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, plasmaVault, EULER_VAULT)
        );
        batchItems[1] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.borrow.selector, 1_000_000e6, plasmaVault)
        );
        batchItems[2] = EulerV2BatchItem(
            plasmaVault,
            bytes1(0x00),
            abi.encodeWithSelector(
                CallbackHandlerEuler.onEulerFlashLoan.selector,
                abi.encode(
                    CallbackData({
                        asset: USDC,
                        addressToApprove: EULER_VAULT,
                        amountToApprove: 1_000_000e6,
                        actionData: abi.encode(mockActions)
                    })
                )
            )
        );
        batchItems[3] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.repay.selector, 1_000_000e6, plasmaVault)
        );

        //todo add more batch items
        batchItems[4] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IVault.disableController.selector)
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithZeroAddressInBatchItems() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            address(0), // Zero address should cause revert
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, plasmaVault, EULER_VAULT)
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.ZeroAddress.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithEmptyBatchItems() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](0); // Empty array

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EmptyBatchItems.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithArrayLengthMismatch() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, plasmaVault, EULER_VAULT)
        );

        address[] memory assetsForApprovals = new address[](2); // 2 assets
        assetsForApprovals[0] = USDC;
        assetsForApprovals[1] = USDC;

        address[] memory eulerVaultsForApprovals = new address[](1); // 1 vault - mismatch!

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.ArrayLengthMismatch.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidEVCSelector() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(bytes4(0x12345678), plasmaVault, EULER_VAULT) // Invalid selector
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.UnsupportedOperation.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidPlasmaVaultCallback() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            address(fuse), // This should be plasmaVault for callback
            bytes1(0x00),
            abi.encodeWithSelector(bytes4(0x12345678), "invalid data") // Invalid callback selector
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.UnsupportedOperation.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidEulerVaultSelector() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(bytes4(0x12345678), 1000e6, plasmaVault) // Invalid selector
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.UnsupportedOperation.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidSubaccountInBorrow() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.borrow.selector, 1000e6, address(0x1234)) // Wrong subaccount
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EulerVaultInvalidPermissions.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidSubaccountInDeposit() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, 1000e6, address(0x1234)) // Wrong subaccount
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EulerVaultInvalidPermissions.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidSubaccountInWithdraw() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(ERC4626Upgradeable.withdraw.selector, 1000e6, address(0x1234), address(0x1234)) // Wrong subaccount
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EulerVaultInvalidPermissions.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidSubaccountInRepay() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_VAULT,
            bytes1(0x00),
            abi.encodeWithSelector(IBorrowing.repay.selector, 1000e6, address(0x1234)) // Wrong subaccount
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EulerVaultInvalidPermissions.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidAccountInEnableController() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, address(0x1234), EULER_VAULT) // Wrong account
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EVCInvalidCollateral.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRevertWithInvalidVaultInEnableController() public {
        EulerV2BatchItem[] memory batchItems = new EulerV2BatchItem[](1);
        batchItems[0] = EulerV2BatchItem(
            EULER_V2_EVC,
            bytes1(0x00),
            abi.encodeWithSelector(IEVC.enableController.selector, plasmaVault, address(0x1234)) // Invalid vault
        );

        address[] memory assetsForApprovals = new address[](0);
        address[] memory eulerVaultsForApprovals = new address[](0);

        EulerV2BatchFuseData memory batchData = EulerV2BatchFuseData(
            batchItems,
            assetsForApprovals,
            eulerVaultsForApprovals
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(fuse), abi.encodeWithSelector(EulerV2BatchFuse.enter.selector, batchData));

        vm.startPrank(ALPHA);
        vm.expectRevert(EulerV2BatchFuse.EVCInvalidCollateral.selector);
        PlasmaVault(plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function _setupRoles() private {
        // Grant ATOMIST_ROLE to ATOMIST using the admin
        vm.prank(TestAddresses.OWNER);
        IporFusionAccessManager(accessManager).grantRole(Roles.ATOMIST_ROLE, ATOMIST, 0);

        // Now ATOMIST can grant other roles
        vm.startPrank(ATOMIST);

        // Grant alpha role to ALPHA address
        IporFusionAccessManager(accessManager).grantRole(Roles.ALPHA_ROLE, TestAddresses.ALPHA, 0);

        // Grant fuse manager role to FUSE_MANAGER address
        IporFusionAccessManager(accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, TestAddresses.FUSE_MANAGER, 0);

        vm.stopPrank();
    }

    function _grantMarketSubstratesForEuler() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: EULER_VAULT, isCollateral: true, canBorrow: true, subAccounts: 0x00})
        );
        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        vm.stopPrank();
    }
}
