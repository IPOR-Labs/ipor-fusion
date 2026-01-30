// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4EModeFuse, AaveV4EModeFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4EModeFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";

/// @title AaveV4EModeFuseTest
/// @notice Tests for AaveV4EModeFuse contract
contract AaveV4EModeFuseTest is Test {
    uint256 public constant MARKET_ID = 43;

    AaveV4EModeFuse public eModeFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;

    function setUp() public {
        // Deploy contracts
        eModeFuse = new AaveV4EModeFuse(MARKET_ID);
        spoke = new MockAaveV4Spoke();

        // Grant spoke substrate
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = AaveV4SubstrateLib.encodeSpoke(address(spoke));

        vaultMock = new PlasmaVaultMock(address(eModeFuse), address(0));
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // Label
        vm.label(address(eModeFuse), "AaveV4EModeFuse");
        vm.label(address(vaultMock), "PlasmaVaultMock");
        vm.label(address(spoke), "MockAaveV4Spoke");
    }

    // ============ Constructor Tests ============

    function testShouldDeployWithValidMarketId() public view {
        assertEq(eModeFuse.VERSION(), address(eModeFuse));
        assertEq(eModeFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(AaveV4EModeFuse.AaveV4EModeFuseInvalidMarketId.selector);
        new AaveV4EModeFuse(0);
    }

    // ============ Enter (setEMode) Tests ============

    function testShouldSetEModeCategory() public {
        // given
        uint8 category = 1;

        // when
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(spoke), eModeCategory: category})
        );

        // then
        uint8 result = spoke.getUserEMode(address(vaultMock));
        assertEq(result, category, "E-Mode category should be set to 1");
    }

    function testShouldDisableEMode() public {
        // given - set category 1 first
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(spoke), eModeCategory: 1})
        );
        assertEq(spoke.getUserEMode(address(vaultMock)), 1);

        // when - disable by setting 0
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(spoke), eModeCategory: 0})
        );

        // then
        uint8 result = spoke.getUserEMode(address(vaultMock));
        assertEq(result, 0, "E-Mode should be disabled");
    }

    function testShouldChangeEModeCategory() public {
        // given - set category 1
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(spoke), eModeCategory: 1})
        );
        assertEq(spoke.getUserEMode(address(vaultMock)), 1);

        // when - change to category 2
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(spoke), eModeCategory: 2})
        );

        // then
        uint8 result = spoke.getUserEMode(address(vaultMock));
        assertEq(result, 2, "E-Mode category should be changed to 2");
    }

    function testShouldRevertWhenSpokeSubstrateNotGranted() public {
        // given
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        bytes32 expectedSubstrate = AaveV4SubstrateLib.encodeSpoke(address(ungrantedSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4EModeFuse.AaveV4EModeFuseUnsupportedSubstrate.selector,
                expectedSubstrate
            )
        );
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(ungrantedSpoke), eModeCategory: 1})
        );
    }

    function testShouldEmitEnterEvent() public {
        // given
        uint8 category = 1;

        // when/then
        vm.expectEmit(false, false, false, true);
        emit AaveV4EModeFuse.AaveV4EModeFuseEnter(address(eModeFuse), address(spoke), category);
        vaultMock.enterAaveV4EMode(
            AaveV4EModeFuseEnterData({spoke: address(spoke), eModeCategory: category})
        );
    }

    // ============ Transient Storage Tests ============

    function testShouldEnterTransient() public {
        // given
        uint8 category = 2;

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(uint256(category));

        vaultMock.setInputs(address(eModeFuse), inputs);

        // when
        vaultMock.enterAaveV4EModeTransient();

        // then
        uint8 result = spoke.getUserEMode(address(vaultMock));
        assertEq(result, category, "E-Mode should be set via transient storage");
    }
}
