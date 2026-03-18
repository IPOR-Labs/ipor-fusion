// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {LitePSMSupplyFuse, LitePSMSupplyFuseEnterData, LitePSMSupplyFuseExitData, LitePSMSupplyFuseFeeExceeded} from
    "../../../contracts/fuses/chains/ethereum/litepsm/LitePSMSupplyFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from
    "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title LitePSMSupplyFuseTest
/// @notice Tests for LitePSMSupplyFuse (USDC <-> sUSDS via LitePSM + ERC4626)
contract LitePSMSupplyFuseTest is Test {
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address private constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address private constant LITE_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    address private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());
    }

    /// @notice Test entering: USDC -> USDS -> sUSDS
    function testShouldEnterLitePsm() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6; // 100 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(address(vaultMock));

        // when
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: amount, allowedTin: type(uint256).max}));

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        // 100 USDC = 100 USDS (1:1 PSM), compute expected sUSDS shares from price per share
        uint256 sharesPerUsds = IERC4626(SUSDS).previewWithdraw(1e18);
        uint256 expectedShares = 100e18 * sharesPerUsds / 1e18;

        assertEq(usdcBalanceBefore, 1_000e6, "USDC balance before should be 1_000e6");
        assertEq(usdcBalanceAfter, 900e6, "USDC balance after should be 900e6");
        assertEq(usdsBalanceAfter, 0, "USDS balance after should be 0 (deposited into sUSDS)");
        assertApproxEqAbs(susdsBalanceAfter, expectedShares, 10000, "sUSDS shares should match expected for 100 USDC");
    }

    /// @notice Test exiting: sUSDS -> USDS -> USDC (exit takes USDC amount, 6 decimals)
    function testShouldExitLitePsm() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6; // 100 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        // Enter first: USDC -> USDS -> sUSDS
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: amount, allowedTin: type(uint256).max}));

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(address(vaultMock));

        // when - exit: sUSDS -> USDS -> USDC (pass USDC amount, 6 decimals)
        vaultMock.exitLitePSMSupply(LitePSMSupplyFuseExitData({amount: 100e6, allowedTout: type(uint256).max}));

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceBefore, 900e6, "USDC balance before exit should be 900e6");
        assertApproxEqAbs(usdcBalanceAfter, 1_000e6, 1, "USDC balance after exit should be ~1_000e6");
        assertEq(usdsBalanceAfter, 0, "USDS dust after exit should be negligible");
        assertLe(susdsBalanceAfter, 1e12, "sUSDS dust after exit should be negligible");
    }

    /// @notice Test instant withdraw (takes USDC amount, 6 decimals)
    function testShouldInstantWithdraw() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6; // 100 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        // Enter first: USDC -> USDS -> sUSDS
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: amount, allowedTin: type(uint256).max}));

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(100e6)); // USDC amount (6 decimals)
        params[1] = bytes32(type(uint256).max); // allowedTout

        // when
        vaultMock.instantWithdraw(params);

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        assertApproxEqAbs(usdcBalanceAfter, 1_000e6, 1, "USDC balance after instant withdraw should be ~1_000e6");
        assertEq(usdsBalanceAfter, 0, "USDS dust after instant withdraw should be negligible");
        assertLe(susdsBalanceAfter, 1e12, "sUSDS dust after instant withdraw should be negligible");
    }

    /// @notice Test zero amount enter returns without changes
    function testShouldReturnWhenEnteringWithZeroAmount() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 100e6);
        uint256 balanceBefore = ERC20(USDC).balanceOf(address(vaultMock));

        // when
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 0, allowedTin: type(uint256).max}));

        // then
        uint256 balanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        assertEq(balanceBefore, balanceAfter, "balance should not change");
    }

    /// @notice Test zero amount exit returns without changes
    function testShouldReturnWhenExitingWithZeroAmount() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 100e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 50e6, allowedTin: type(uint256).max}));

        uint256 susdsBalanceBefore = IERC4626(SUSDS).balanceOf(address(vaultMock));

        // when
        vaultMock.exitLitePSMSupply(LitePSMSupplyFuseExitData({amount: 0, allowedTout: type(uint256).max}));

        // then
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));
        assertEq(susdsBalanceBefore, susdsBalanceAfter, "sUSDS balance should not change");
    }

    /// @notice Test entering via transient storage
    function testShouldEnterTransient() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6;
        deal(USDC, address(vaultMock), 1_000e6);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(amount);
        inputs[1] = TypeConversionLib.toBytes32(type(uint256).max); // allowedTin

        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        bytes memory setInputsData = abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData);

        // when
        vaultMock.execute(address(_transientStorageSetInputsFuse), setInputsData);
        vaultMock.enterLitePSMSupplyTransient();

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        // 100 USDC = 100 USDS (1:1 PSM), compute expected sUSDS shares
        uint256 sharesPerUsds = IERC4626(SUSDS).previewWithdraw(1e18);
        uint256 expectedShares = 100e18 * sharesPerUsds / 1e18;

        assertEq(usdcBalanceAfter, 900e6, "USDC balance after should be 900e6");
        assertEq(usdsBalanceAfter, 0, "USDS balance after should be 0");
        assertApproxEqAbs(susdsBalanceAfter, expectedShares, 10000, "sUSDS shares should match expected for 100 USDC");
    }

    /// @notice Test exiting via transient storage (USDC amount, 6 decimals)
    function testShouldExitTransient() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);

        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: type(uint256).max}));

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(uint256(100e6)); // USDC amount
        inputs[1] = TypeConversionLib.toBytes32(type(uint256).max); // allowedTout

        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        bytes memory setInputsData = abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData);

        // when
        vaultMock.execute(address(_transientStorageSetInputsFuse), setInputsData);
        vaultMock.exitLitePSMSupplyTransient();

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        assertApproxEqAbs(usdcBalanceAfter, 1_000e6, 1, "USDC balance after exit should be ~1_000e6");
        assertEq(usdsBalanceAfter, 0, "USDS dust after exit should be negligible");
        assertLe(susdsBalanceAfter, 1e12, "sUSDS dust after exit should be negligible");
    }

    /// @notice Test enter reverts when actual tin exceeds allowedTin
    function testShouldRevertEnterWhenTinExceedsAllowed() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);

        // Mock tin to 1% (0.01e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tin()"), abi.encode(0.01e18));

        // when/then - allowedTin is 0, but actual tin is 1%
        vm.expectRevert();
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: 0}));
    }

    /// @notice Test exit reverts when actual tout exceeds allowedTout
    function testShouldRevertExitWhenToutExceedsAllowed() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: type(uint256).max}));

        // Mock tout to 10% (0.1e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tout()"), abi.encode(0.1e18));

        // when/then - allowedTout is 0, but actual tout is 10%
        vm.expectRevert();
        vaultMock.exitLitePSMSupply(LitePSMSupplyFuseExitData({amount: 100e6, allowedTout: 0}));
    }

    /// @notice Test exit with 10% tout: USDC received is reduced by the fee deducted as extra USDS
    function testShouldExitWithTout10Percent() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 1_000e6, allowedTin: type(uint256).max}));

        // Mock tout to 10% (0.1e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tout()"), abi.encode(0.1e18));

        // when - request 100 USDC; with 10% tout, exit needs 110 USDS from sUSDS
        vaultMock.exitLitePSMSupply(LitePSMSupplyFuseExitData({amount: 100e6, allowedTout: type(uint256).max}));

        // then - should receive exactly 100 USDC (tout is paid from extra USDS, not deducted from USDC output)
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        assertEq(usdcBalanceAfter, 100e6, "should receive exactly 100 USDC");
    }

    /// @notice Test exit with 10% tout caps to sUSDS availability when requesting more than available
    function testShouldExitWithTout10PercentCappedToAvailable() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 100e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: type(uint256).max}));

        uint256 maxUsdsWithdraw = IERC4626(SUSDS).maxWithdraw(address(vaultMock));

        // Mock tout to 10% (0.1e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tout()"), abi.encode(0.1e18));

        // when - request 200 USDC (more than available with 10% tout)
        vaultMock.exitLitePSMSupply(LitePSMSupplyFuseExitData({amount: 200e6, allowedTout: type(uint256).max}));

        // then - should receive less than 100 USDC due to 10% tout eating into the available USDS
        // maxUSDC = maxUsdsWithdraw / (1.1 * 1e12), rounded down to USDC precision
        uint256 expectedUsdc = maxUsdsWithdraw * 1e18 / (1.1e18 * 1e12);
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        assertEq(usdcBalanceAfter, expectedUsdc, "USDC should be capped based on available sUSDS minus tout");
    }

    /// @notice Test instant withdraw with 10% tout
    function testShouldInstantWithdrawWithTout10Percent() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 500e6, allowedTin: type(uint256).max}));

        // Mock tout to 10% (0.1e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tout()"), abi.encode(0.1e18));

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(100e6));
        params[1] = bytes32(type(uint256).max); // allowedTout

        // when
        vaultMock.instantWithdraw(params);

        // then - should receive exactly 100 USDC
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        assertEq(usdcBalanceAfter, 600e6, "should have 500 remaining + 100 withdrawn = 600 USDC");
    }

    /// @notice Test instantWithdraw does not revert when tout exceeds allowedTout (graceful fail)
    function testShouldNotRevertInstantWithdrawWhenToutExceedsAllowed() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: type(uint256).max}));

        uint256 susdsBalanceBefore = IERC4626(SUSDS).balanceOf(address(vaultMock));
        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(address(vaultMock));

        // Mock tout to 10% (0.1e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tout()"), abi.encode(0.1e18));

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(100e6));
        params[1] = bytes32(uint256(0)); // allowedTout = 0, actual tout = 10%

        // when - should NOT revert, just gracefully fail
        vaultMock.instantWithdraw(params);

        // then - balances unchanged (no withdrawal happened)
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceAfter, usdcBalanceBefore, "USDC balance should not change");
        assertEq(susdsBalanceAfter, susdsBalanceBefore, "sUSDS balance should not change");
    }

    /// @notice Test enter caps to available USDC balance when amount exceeds balance
    function testShouldEnterCappedToAvailableBalance() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 50e6); // only 50 USDC

        // when - request 100 USDC but only 50 available
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: type(uint256).max}));

        // then - should use all 50 USDC
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));

        // 50 USDC = 50 USDS (1:1 PSM), compute expected sUSDS shares
        uint256 sharesPerUsds = IERC4626(SUSDS).previewWithdraw(1e18);
        uint256 expectedShares = 50e18 * sharesPerUsds / 1e18;

        assertEq(usdcBalanceAfter, 0, "all USDC should be consumed");
        assertApproxEqAbs(susdsBalanceAfter, expectedShares, 10000, "sUSDS shares should match expected for 50 USDC");
    }

    /// @notice Test exit with 10% tout reverts when allowedTout is below actual tout
    function testShouldRevertExitWithTout10PercentWhenToutExceedsAllowed() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePSMSupplyFuse fuse = new LitePSMSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 100e6);
        vaultMock.enterLitePSMSupply(LitePSMSupplyFuseEnterData({amount: 100e6, allowedTin: type(uint256).max}));

        // Mock tout to 10% (0.1e18)
        vm.mockCall(LITE_PSM, abi.encodeWithSignature("tout()"), abi.encode(0.1e18));

        // when/then - allowedTout is 5% but actual tout is 10%
        vm.expectRevert();
        vaultMock.exitLitePSMSupply(LitePSMSupplyFuseExitData({amount: 100e6, allowedTout: 0.05e18}));
    }
}
