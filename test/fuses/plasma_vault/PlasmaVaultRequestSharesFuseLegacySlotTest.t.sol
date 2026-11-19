// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    PlasmaVaultRequestSharesFuse,
    PlasmaVaultRequestSharesFuseEnterData,
    PlasmaVaultRequestSharesFuseInvalidWithdrawManager
} from "../../../contracts/fuses/plasma_vault/PlasmaVaultRequestSharesFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {MockLegacyRemotePlasmaVault} from "../../crosschain/mocks/MockLegacyRemotePlasmaVault.sol";
import {MockRemotePlasmaVault, MockWithdrawManager} from "../../crosschain/mocks/MockRemoteVault.sol";

contract LegacySlotTestAsset is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Parent vault stand-in: runs the fuse by delegatecall (as PlasmaVault.execute does) with the market
///      substrates stored in its own storage. The target is the vault under test.
contract LegacySlotParent {
    function grant(uint256 marketId_, address target_) external {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(target_);
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates);
    }

    function enterViaFuse(address fuse_, address target_, uint256 shares_) external {
        (bool ok, bytes memory ret) = fuse_.delegatecall(
            abi.encodeCall(
                PlasmaVaultRequestSharesFuse.enter,
                (PlasmaVaultRequestSharesFuseEnterData({sharesAmount: shares_, plasmaVault: target_}))
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice IL-9424: PlasmaVaultRequestSharesFuse reads the target's withdraw manager with the legacy-slot fallback.
contract PlasmaVaultRequestSharesFuseLegacySlotTest is Test {
    event PlasmaVaultRequestSharesFuseEnter(address version, address plasmaVault, uint256 sharesAmount);

    uint256 private constant MARKET_ID = 77;
    bytes32 private constant CORRECTED_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    PlasmaVaultRequestSharesFuse private _fuse;
    LegacySlotParent private _parent;
    LegacySlotTestAsset private _asset;

    function setUp() public {
        _fuse = new PlasmaVaultRequestSharesFuse(MARKET_ID);
        _parent = new LegacySlotParent();
        _asset = new LegacySlotTestAsset();
    }

    function _fundParent(address target_, uint256 shares_) private {
        _asset.mint(address(this), shares_);
        _asset.approve(target_, shares_);
        (bool ok, ) = target_.call(abi.encodeWithSignature("deposit(uint256,address)", shares_, address(_parent)));
        assertTrue(ok, "deposit failed");
    }

    function testShouldRequestSharesFromLegacySlotTarget() public {
        // given
        MockLegacyRemotePlasmaVault target = new MockLegacyRemotePlasmaVault(_asset, "T", "T");
        MockWithdrawManager manager = new MockWithdrawManager(address(target));
        target.setLegacyWithdrawManager(address(manager));
        _parent.grant(MARKET_ID, address(target));
        _fundParent(address(target), 100e18);

        // when
        vm.expectEmit(address(_parent));
        emit PlasmaVaultRequestSharesFuseEnter(address(_fuse), address(target), 40e18);
        _parent.enterViaFuse(address(_fuse), address(target), 40e18);

        // then
        assertEq(manager.requestedShares(address(_parent)), 40e18, "request stored for the parent");
    }

    function testShouldPreferCorrectedSlotOverLegacySlot() public {
        // given
        MockLegacyRemotePlasmaVault target = new MockLegacyRemotePlasmaVault(_asset, "T", "T");
        MockWithdrawManager legacyManager = new MockWithdrawManager(address(target));
        MockWithdrawManager correctedManager = new MockWithdrawManager(address(target));
        target.setLegacyWithdrawManager(address(legacyManager));
        vm.store(address(target), CORRECTED_SLOT, bytes32(uint256(uint160(address(correctedManager)))));
        _parent.grant(MARKET_ID, address(target));
        _fundParent(address(target), 100e18);

        // when
        _parent.enterViaFuse(address(_fuse), address(target), 25e18);

        // then
        assertEq(correctedManager.requestedShares(address(_parent)), 25e18, "corrected slot manager used");
        assertEq(legacyManager.requestedShares(address(_parent)), 0, "legacy slot manager untouched");
    }

    function testShouldRequestSharesFromCorrectedSlotTarget() public {
        // given
        MockRemotePlasmaVault target = new MockRemotePlasmaVault(_asset, "T", "T");
        MockWithdrawManager manager = new MockWithdrawManager(address(target));
        target.setWithdrawManager(address(manager));
        _parent.grant(MARKET_ID, address(target));
        _fundParent(address(target), 100e18);

        // when
        _parent.enterViaFuse(address(_fuse), address(target), 10e18);

        // then
        assertEq(manager.requestedShares(address(_parent)), 10e18, "request stored for the parent");
    }

    function testShouldRevertWhenTargetHasNoWithdrawManager() public {
        // given
        MockLegacyRemotePlasmaVault target = new MockLegacyRemotePlasmaVault(_asset, "T", "T");
        _parent.grant(MARKET_ID, address(target));
        _fundParent(address(target), 100e18);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultRequestSharesFuseInvalidWithdrawManager.selector, address(target))
        );
        _parent.enterViaFuse(address(_fuse), address(target), 10e18);
    }
}
