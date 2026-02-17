// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryWrapper} from "../../contracts/factory/FusionFactoryWrapper.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract FusionFactoryWrapperTest is Test {
    address public constant EXISTING_FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public wrapperAdmin = makeAddr("WRAPPER_ADMIN");
    address public vaultCreator = makeAddr("VAULT_CREATOR");
    address public vaultOwner = makeAddr("VAULT_OWNER");
    address public guardian = makeAddr("GUARDIAN");
    address public atomist = makeAddr("ATOMIST");
    address public alpha = makeAddr("ALPHA");
    address public unauthorized = makeAddr("UNAUTHORIZED");

    // Whitelist user with known private key for signing
    uint256 public whitelistPrivateKey = 0xA11CE;
    address public whitelistUser;

    FusionFactoryWrapper public wrapper;

    function setUp() public {
        whitelistUser = vm.addr(whitelistPrivateKey);

        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 24475332);

        wrapper = new FusionFactoryWrapper(EXISTING_FUSION_FACTORY_PROXY, wrapperAdmin);

        bytes32 vaultCreatorRole = wrapper.VAULT_CREATOR_ROLE();
        vm.prank(wrapperAdmin);
        wrapper.grantRole(vaultCreatorRole, vaultCreator);
    }

    // ============ createVault Tests ============

    function testCreateVaultWithAllRoles() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);

        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);

        _assertHasRole(am, Roles.OWNER_ROLE, vaultOwner);
        _assertHasRole(am, Roles.GUARDIAN_ROLE, guardian);
        _assertHasRole(am, Roles.ATOMIST_ROLE, atomist);
        _assertHasRole(am, Roles.ALPHA_ROLE, alpha);
        _assertHasRole(am, Roles.WHITELIST_ROLE, whitelistUser);
        _assertHasRole(am, Roles.FUSE_MANAGER_ROLE, atomist);
        assertTrue(instance.plasmaVault != address(0));
    }

    function testWrapperHasNoVaultRolesAfterCreation() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);

        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);

        _assertNotHasRole(am, Roles.OWNER_ROLE, address(wrapper));
        _assertNotHasRole(am, Roles.ATOMIST_ROLE, address(wrapper));
        _assertNotHasRole(am, Roles.ADMIN_ROLE, address(wrapper));
    }

    function testOnlyVaultCreatorCanCreateVault() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        bytes32 role = wrapper.VAULT_CREATOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, role)
        );
        vm.prank(unauthorized);
        wrapper.createVault(input);
    }

    function testAdminCanGrantVaultCreatorRole() public {
        address newCreator = makeAddr("NEW_CREATOR");
        bytes32 role = wrapper.VAULT_CREATOR_ROLE();

        vm.prank(wrapperAdmin);
        wrapper.grantRole(role, newCreator);

        assertTrue(wrapper.hasRole(role, newCreator));
    }

    function testOwnerCanManageRolesAfterCreation() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);

        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);

        address newAtomist = makeAddr("NEW_ATOMIST");
        vm.prank(vaultOwner);
        am.grantRole(Roles.ATOMIST_ROLE, newAtomist, 0);

        _assertHasRole(am, Roles.ATOMIST_ROLE, newAtomist);
    }

    function testAtomistCanManageSubRoles() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);

        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);

        address newAlpha = makeAddr("NEW_ALPHA");
        address newWhitelist = makeAddr("NEW_WHITELIST");
        address newFuseManager = makeAddr("NEW_FUSE_MANAGER");

        vm.startPrank(atomist);
        am.grantRole(Roles.ALPHA_ROLE, newAlpha, 0);
        am.grantRole(Roles.WHITELIST_ROLE, newWhitelist, 0);
        am.grantRole(Roles.FUSE_MANAGER_ROLE, newFuseManager, 0);
        vm.stopPrank();

        _assertHasRole(am, Roles.ALPHA_ROLE, newAlpha);
        _assertHasRole(am, Roles.WHITELIST_ROLE, newWhitelist);
        _assertHasRole(am, Roles.FUSE_MANAGER_ROLE, newFuseManager);
    }

    function testGuardianZeroAddressSkipped() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        input.guardian = address(0);

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);

        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);
        _assertNotHasRole(am, Roles.GUARDIAN_ROLE, address(0));
    }

    function testRevertOnZeroOwner() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        input.owner = address(0);

        vm.prank(vaultCreator);
        vm.expectRevert(FusionFactoryWrapper.OwnerZeroAddress.selector);
        wrapper.createVault(input);
    }

    function testRevertOnZeroAtomist() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        input.atomist = address(0);

        vm.prank(vaultCreator);
        vm.expectRevert(FusionFactoryWrapper.AtomistZeroAddress.selector);
        wrapper.createVault(input);
    }

    function testRevertOnZeroAlpha() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        input.alpha = address(0);

        vm.prank(vaultCreator);
        vm.expectRevert(FusionFactoryWrapper.AlphaZeroAddress.selector);
        wrapper.createVault(input);
    }

    function testRevertOnZeroWhitelist() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        input.whitelist = address(0);

        vm.prank(vaultCreator);
        vm.expectRevert(FusionFactoryWrapper.WhitelistZeroAddress.selector);
        wrapper.createVault(input);
    }

    function testMultipleVaultsIndependent() public {
        FusionFactoryWrapper.CreateVaultInput memory input1 = _createFullInput();

        address owner2 = makeAddr("OWNER2");
        address atomist2 = makeAddr("ATOMIST2");
        FusionFactoryWrapper.CreateVaultInput memory input2 = _createFullInput();
        input2.assetName = "Second Vault";
        input2.assetSymbol = "SV";
        input2.owner = owner2;
        input2.atomist = atomist2;

        vm.startPrank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory i1 = wrapper.createVault(input1);
        FusionFactoryLogicLib.FusionInstance memory i2 = wrapper.createVault(input2);
        vm.stopPrank();

        assertTrue(i1.plasmaVault != i2.plasmaVault);
        assertTrue(i1.accessManager != i2.accessManager);

        IporFusionAccessManager am1 = IporFusionAccessManager(i1.accessManager);
        IporFusionAccessManager am2 = IporFusionAccessManager(i2.accessManager);

        _assertHasRole(am1, Roles.OWNER_ROLE, vaultOwner);
        _assertHasRole(am2, Roles.OWNER_ROLE, owner2);
        _assertNotHasRole(am2, Roles.OWNER_ROLE, vaultOwner);
        _assertNotHasRole(am1, Roles.ATOMIST_ROLE, atomist2);
    }

    function testWhitelistCanDeposit() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVault(input);

        PlasmaVault vault = PlasmaVault(instance.plasmaVault);

        uint256 depositAmount = 1_000e6;
        deal(USDC, whitelistUser, depositAmount);

        vm.startPrank(whitelistUser);
        ERC20(USDC).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, whitelistUser);
        vm.stopPrank();

        assertGt(shares, 0, "Whitelist user should receive shares");
        assertEq(vault.balanceOf(whitelistUser), shares);
    }

    // ============ createVaultSigned Tests ============

    function testCreateVaultSignedSuccess() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        (uint8 v, bytes32 r, bytes32 s) = _signInput(input, whitelistPrivateKey);

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVaultSigned(input, v, r, s);

        IporFusionAccessManager am = IporFusionAccessManager(instance.accessManager);

        _assertHasRole(am, Roles.OWNER_ROLE, vaultOwner);
        _assertHasRole(am, Roles.ATOMIST_ROLE, atomist);
        _assertHasRole(am, Roles.WHITELIST_ROLE, whitelistUser);
        _assertHasRole(am, Roles.ALPHA_ROLE, alpha);
        _assertHasRole(am, Roles.FUSE_MANAGER_ROLE, atomist);
        _assertNotHasRole(am, Roles.OWNER_ROLE, address(wrapper));
        _assertNotHasRole(am, Roles.ATOMIST_ROLE, address(wrapper));
    }

    function testCreateVaultSignedRevertOnWrongSigner() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        // Sign with a different private key (not whitelistUser)
        uint256 wrongKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = _signInput(input, wrongKey);

        vm.prank(vaultCreator);
        vm.expectRevert(FusionFactoryWrapper.InvalidSignature.selector);
        wrapper.createVaultSigned(input, v, r, s);
    }

    function testCreateVaultSignedRevertOnTamperedInput() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        (uint8 v, bytes32 r, bytes32 s) = _signInput(input, whitelistPrivateKey);

        // Tamper with input after signing
        input.assetName = "Tampered Vault";

        vm.prank(vaultCreator);
        vm.expectRevert(FusionFactoryWrapper.InvalidSignature.selector);
        wrapper.createVaultSigned(input, v, r, s);
    }

    function testCreateVaultSignedOnlyVaultCreator() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        (uint8 v, bytes32 r, bytes32 s) = _signInput(input, whitelistPrivateKey);
        bytes32 role = wrapper.VAULT_CREATOR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, role)
        );
        vm.prank(unauthorized);
        wrapper.createVaultSigned(input, v, r, s);
    }

    function testCreateVaultSignedWhitelistCanDeposit() public {
        FusionFactoryWrapper.CreateVaultInput memory input = _createFullInput();
        (uint8 v, bytes32 r, bytes32 s) = _signInput(input, whitelistPrivateKey);

        vm.prank(vaultCreator);
        FusionFactoryLogicLib.FusionInstance memory instance = wrapper.createVaultSigned(input, v, r, s);

        PlasmaVault vault = PlasmaVault(instance.plasmaVault);

        uint256 depositAmount = 1_000e6;
        deal(USDC, whitelistUser, depositAmount);

        vm.startPrank(whitelistUser);
        ERC20(USDC).approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, whitelistUser);
        vm.stopPrank();

        assertGt(shares, 0, "Whitelist user should receive shares");
    }

    // ============ Assertion Helpers ============

    function _assertHasRole(IporFusionAccessManager am, uint64 roleId, address account) internal view {
        (bool isMember, ) = am.hasRole(roleId, account);
        assertTrue(isMember);
    }

    function _assertNotHasRole(IporFusionAccessManager am, uint64 roleId, address account) internal view {
        (bool isMember, ) = am.hasRole(roleId, account);
        assertFalse(isMember);
    }

    // ============ Input & Signing Helpers ============

    function _createFullInput() internal view returns (FusionFactoryWrapper.CreateVaultInput memory) {
        return FusionFactoryWrapper.CreateVaultInput({
            assetName: "Wrapped Vault",
            assetSymbol: "WV",
            underlyingToken: USDC,
            redemptionDelayInSeconds: 0,
            daoFeePackageIndex: 0,
            owner: vaultOwner,
            guardian: guardian,
            atomist: atomist,
            alpha: alpha,
            whitelist: whitelistUser
        });
    }

    function _signInput(
        FusionFactoryWrapper.CreateVaultInput memory input,
        uint256 privateKey
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                wrapper.CREATE_VAULT_INPUT_TYPEHASH(),
                keccak256(bytes(input.assetName)),
                keccak256(bytes(input.assetSymbol)),
                input.underlyingToken,
                input.redemptionDelayInSeconds,
                input.daoFeePackageIndex,
                input.owner,
                input.guardian,
                input.atomist,
                input.alpha,
                input.whitelist
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(wrapper.DOMAIN_SEPARATOR(), structHash);
        (v, r, s) = vm.sign(privateKey, digest);
    }
}
