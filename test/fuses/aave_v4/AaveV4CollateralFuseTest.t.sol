// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {
    AaveV4CollateralFuse,
    AaveV4CollateralFuseEnterData,
    AaveV4CollateralFuseExitData
} from "../../../contracts/fuses/aave_v4/AaveV4CollateralFuse.sol";
import {AaveV4SupplyFuse, AaveV4SupplyFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {AaveV4BorrowFuse, AaveV4BorrowFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title AaveV4CollateralFuseTest
/// @notice Tests for AaveV4CollateralFuse contract
contract AaveV4CollateralFuseTest is Test {
    uint256 public constant MARKET_ID = 49;
    uint256 public constant RESERVE_ID = 1;

    AaveV4CollateralFuse public collateralFuse;
    AaveV4SupplyFuse public supplyFuse;
    AaveV4BorrowFuse public borrowFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;
    ERC20Mock public token;

    function setUp() public {
        collateralFuse = new AaveV4CollateralFuse(MARKET_ID);
        supplyFuse = new AaveV4SupplyFuse(MARKET_ID);
        borrowFuse = new AaveV4BorrowFuse(MARKET_ID);
        vaultMock = new PlasmaVaultMock(address(collateralFuse), address(0));
        spoke = new MockAaveV4Spoke();
        token = new ERC20Mock("Test Token", "TST", 18);

        spoke.addReserve(RESERVE_ID, address(token));
        token.mint(address(spoke), 1_000_000e18);

        // reserve granted as collateral + borrowable
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, true));

        vm.label(address(collateralFuse), "AaveV4CollateralFuse");
        vm.label(address(vaultMock), "PlasmaVaultMock");
        vm.label(address(spoke), "MockAaveV4Spoke");
        vm.label(address(token), "TestToken");
    }

    // ============ Constructor Tests ============

    function testShouldDeployWithValidMarketId() public view {
        assertEq(collateralFuse.VERSION(), address(collateralFuse));
        assertEq(collateralFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(AaveV4CollateralFuse.AaveV4CollateralFuseInvalidMarketId.selector);
        new AaveV4CollateralFuse(0);
    }

    // ============ Enter (enable collateral) Tests ============

    function testShouldEnableCollateral() public {
        // when
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        // then
        (bool usingAsCollateral, bool borrowing) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertTrue(usingAsCollateral, "Reserve should be enabled as collateral");
        assertFalse(borrowing);
    }

    function testShouldEmitEnterEvent() public {
        vm.expectEmit(false, false, false, true);
        emit AaveV4CollateralFuse.AaveV4CollateralFuseEnter(address(collateralFuse), address(spoke), RESERVE_ID);

        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));
    }

    function testShouldBeIdempotentWhenEnablingTwice() public {
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertTrue(usingAsCollateral);
    }

    function testShouldRevertEnterWhenGrantLacksIsCollateral() public {
        // given - regrant as borrow-only
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, true));

        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4CollateralFuse.AaveV4CollateralFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));
    }

    function testShouldRevertEnterWhenReserveNotGranted() public {
        uint256 otherReserveId = 2;
        spoke.addReserve(otherReserveId, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4CollateralFuse.AaveV4CollateralFuseUnsupportedSubstrate.selector,
                "enter",
                address(spoke),
                otherReserveId
            )
        );
        vaultMock.enterAaveV4Collateral(
            AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: otherReserveId})
        );
    }

    function testShouldRevertEnterWhenSpokeNotGranted() public {
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();
        ungrantedSpoke.addReserve(RESERVE_ID, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4CollateralFuse.AaveV4CollateralFuseUnsupportedSubstrate.selector,
                "enter",
                address(ungrantedSpoke),
                RESERVE_ID
            )
        );
        vaultMock.enterAaveV4Collateral(
            AaveV4CollateralFuseEnterData({spoke: address(ungrantedSpoke), reserveId: RESERVE_ID})
        );
    }

    function testShouldEnableCollateralWhenGrantHasCollateralOnly() public {
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, true, false));

        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertTrue(usingAsCollateral);
    }

    // ============ Exit (disable collateral) Tests ============

    function testShouldDisableCollateral() public {
        // given
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        // when
        vaultMock.exitAaveV4Collateral(AaveV4CollateralFuseExitData({spoke: address(spoke), reserveId: RESERVE_ID}));

        // then
        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertFalse(usingAsCollateral, "Reserve should be disabled as collateral");
    }

    function testShouldEmitExitEvent() public {
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        vm.expectEmit(false, false, false, true);
        emit AaveV4CollateralFuse.AaveV4CollateralFuseExit(address(collateralFuse), address(spoke), RESERVE_ID);

        vaultMock.exitAaveV4Collateral(AaveV4CollateralFuseExitData({spoke: address(spoke), reserveId: RESERVE_ID}));
    }

    function testShouldDisableCollateralWhenGrantIsPlain() public {
        // given - enabled while collateral was allowed, then the atomist downgraded the grant
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));
        _grant(AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID, false, false));

        // when - disabling must still be possible
        vaultMock.exitAaveV4Collateral(AaveV4CollateralFuseExitData({spoke: address(spoke), reserveId: RESERVE_ID}));

        // then
        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertFalse(usingAsCollateral);
    }

    function testShouldRevertExitWhenReserveNotGranted() public {
        uint256 otherReserveId = 2;
        spoke.addReserve(otherReserveId, address(token));

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4CollateralFuse.AaveV4CollateralFuseUnsupportedSubstrate.selector,
                "exit",
                address(spoke),
                otherReserveId
            )
        );
        vaultMock.exitAaveV4Collateral(
            AaveV4CollateralFuseExitData({spoke: address(spoke), reserveId: otherReserveId})
        );
    }

    function testShouldRevertExitWhenSpokeNotGranted() public {
        MockAaveV4Spoke ungrantedSpoke = new MockAaveV4Spoke();

        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4CollateralFuse.AaveV4CollateralFuseUnsupportedSubstrate.selector,
                "exit",
                address(ungrantedSpoke),
                RESERVE_ID
            )
        );
        vaultMock.exitAaveV4Collateral(
            AaveV4CollateralFuseExitData({spoke: address(ungrantedSpoke), reserveId: RESERVE_ID})
        );
    }

    function testShouldRevertDisableCollateralWhileDebtOutstanding() public {
        // given - health factor gate on, supply + enable + borrow
        spoke.setRequireCollateralForBorrow(true);
        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(supplyAmount);
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));
        _borrow(100e18);

        // when/then - spoke rejects disabling the only collateral backing the debt
        vm.expectRevert(IAaveV4Spoke.HealthFactorBelowThreshold.selector);
        vaultMock.exitAaveV4Collateral(AaveV4CollateralFuseExitData({spoke: address(spoke), reserveId: RESERVE_ID}));
    }

    // ============ Borrow interplay (why this fuse exists) ============

    function testShouldRevertBorrowWhenCollateralNotEnabled() public {
        spoke.setRequireCollateralForBorrow(true);
        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(supplyAmount);

        vm.expectRevert(IAaveV4Spoke.HealthFactorBelowThreshold.selector);
        _borrow(100e18);
    }

    function testShouldBorrowAfterCollateralEnabled() public {
        spoke.setRequireCollateralForBorrow(true);
        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(supplyAmount);
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        _borrow(100e18);

        assertEq(spoke.getUserTotalDebt(RESERVE_ID, address(vaultMock)), 100e18);
        (bool usingAsCollateral, bool borrowing) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertTrue(usingAsCollateral);
        assertTrue(borrowing);
    }

    // ============ Transient Storage Tests ============

    function testShouldEnterTransient() public {
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(RESERVE_ID);
        vaultMock.setInputs(address(collateralFuse), inputs);

        vaultMock.enterAaveV4CollateralTransient();

        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertTrue(usingAsCollateral);

        bytes32[] memory outputs = vaultMock.getOutputs(address(collateralFuse));
        assertEq(outputs.length, 2);
        assertEq(address(uint160(uint256(outputs[0]))), address(spoke));
        assertEq(uint256(outputs[1]), RESERVE_ID);
    }

    function testShouldExitTransient() public {
        vaultMock.enterAaveV4Collateral(AaveV4CollateralFuseEnterData({spoke: address(spoke), reserveId: RESERVE_ID}));

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = bytes32(uint256(uint160(address(spoke))));
        inputs[1] = bytes32(RESERVE_ID);
        vaultMock.setInputs(address(collateralFuse), inputs);

        vaultMock.exitAaveV4CollateralTransient();

        (bool usingAsCollateral, ) = spoke.getUserReserveStatus(RESERVE_ID, address(vaultMock));
        assertFalse(usingAsCollateral);

        bytes32[] memory outputs = vaultMock.getOutputs(address(collateralFuse));
        assertEq(outputs.length, 2);
        assertEq(address(uint160(uint256(outputs[0]))), address(spoke));
        assertEq(uint256(outputs[1]), RESERVE_ID);
    }

    // ============ Helpers ============

    function _grant(bytes32 substrate_) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrate_;
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _supply(uint256 amount_) private {
        vaultMock.execute(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256))",
                AaveV4SupplyFuseEnterData({
                    spoke: address(spoke),
                    asset: address(token),
                    reserveId: RESERVE_ID,
                    amount: amount_,
                    minShares: 0
                })
            )
        );
    }

    function _borrow(uint256 amount_) private {
        vaultMock.execute(
            address(borrowFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256))",
                AaveV4BorrowFuseEnterData({
                    spoke: address(spoke),
                    asset: address(token),
                    reserveId: RESERVE_ID,
                    amount: amount_,
                    minShares: 0
                })
            )
        );
    }
}
