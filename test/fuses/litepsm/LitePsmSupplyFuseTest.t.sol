// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {LitePsmSupplyFuse, LitePsmSupplyFuseEnterData, LitePsmSupplyFuseExitData} from
    "../../../contracts/fuses/chains/ethereum/litepsm/LitePsmSupplyFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from
    "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title LitePsmSupplyFuseTest
/// @notice Tests for LitePsmSupplyFuse (USDC <-> USDS swap via LitePSM)
contract LitePsmSupplyFuseTest is Test {
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address private constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    address private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());
    }

    /// @notice Test entering: USDC -> USDS via sellGem
    function testShouldEnterLitePsm() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6; // 100 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceBefore = ERC20(USDS).balanceOf(address(vaultMock));

        // when
        vaultMock.enterLitePsmSupply(LitePsmSupplyFuseEnterData({amount: amount}));

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceBefore, 1_000e6, "USDC balance before should be 1_000e6");
        assertEq(usdcBalanceAfter, 900e6, "USDC balance after should be 900e6");
        assertEq(usdsBalanceBefore, 0, "USDS balance before should be 0");
        assertEq(usdsBalanceAfter, 100e18, "USDS balance after should be 100e18");
    }

    /// @notice Test exiting: USDS -> USDC via buyGem
    function testShouldExitLitePsm() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6; // 100 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        // Enter first: USDC -> USDS
        vaultMock.enterLitePsmSupply(LitePsmSupplyFuseEnterData({amount: amount}));

        uint256 usdcBalanceBefore = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceBefore = ERC20(USDS).balanceOf(address(vaultMock));

        // when - exit: USDS -> USDC (pass USDS amount, 18 decimals)
        vaultMock.exitLitePsmSupply(LitePsmSupplyFuseExitData({amount: 100e18}));

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceBefore, 900e6, "USDC balance before exit should be 900e6");
        assertEq(usdcBalanceAfter, 1_000e6, "USDC balance after exit should be 1_000e6");
        assertEq(usdsBalanceBefore, 100e18, "USDS balance before exit should be 100e18");
        assertEq(usdsBalanceAfter, 0, "USDS balance after exit should be 0");
    }

    /// @notice Test instant withdraw
    function testShouldInstantWithdraw() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6; // 100 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        // Enter first: USDC -> USDS
        vaultMock.enterLitePsmSupply(LitePsmSupplyFuseEnterData({amount: amount}));

        bytes32[] memory params = new bytes32[](1);
        params[0] = bytes32(uint256(100e18)); // USDS amount (18 decimals)

        // when
        vaultMock.instantWithdraw(params);

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceAfter, 1_000e6, "USDC balance after instant withdraw should be 1_000e6");
        assertEq(usdsBalanceAfter, 0, "USDS balance after instant withdraw should be 0");
    }

    /// @notice Test zero amount enter returns without changes
    function testShouldReturnWhenEnteringWithZeroAmount() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 100e6);
        uint256 balanceBefore = ERC20(USDC).balanceOf(address(vaultMock));

        // when
        vaultMock.enterLitePsmSupply(LitePsmSupplyFuseEnterData({amount: 0}));

        // then
        uint256 balanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        assertEq(balanceBefore, balanceAfter, "balance should not change");
    }

    /// @notice Test zero amount exit returns without changes
    function testShouldReturnWhenExitingWithZeroAmount() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 100e6);
        vaultMock.enterLitePsmSupply(LitePsmSupplyFuseEnterData({amount: 50e6}));

        uint256 usdsBalanceBefore = ERC20(USDS).balanceOf(address(vaultMock));

        // when
        vaultMock.exitLitePsmSupply(LitePsmSupplyFuseExitData({amount: 0}));

        // then
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));
        assertEq(usdsBalanceBefore, usdsBalanceAfter, "USDS balance should not change");
    }

    /// @notice Test entering via transient storage
    function testShouldEnterTransient() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        uint256 amount = 100e6;
        deal(USDC, address(vaultMock), 1_000e6);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(amount);

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
        vaultMock.enterLitePsmSupplyTransient();

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceAfter, 900e6, "USDC balance after should be 900e6");
        assertEq(usdsBalanceAfter, 100e18, "USDS balance after should be 100e18");
    }

    /// @notice Test exiting via transient storage
    function testShouldExitTransient() external {
        // given
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(1);
        LitePsmSupplyFuse fuse = new LitePsmSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(USDC, address(vaultMock), 1_000e6);

        vaultMock.enterLitePsmSupply(LitePsmSupplyFuseEnterData({amount: 100e6}));

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(uint256(100e18)); // USDS amount

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
        vaultMock.exitLitePsmSupplyTransient();

        // then
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));

        assertEq(usdcBalanceAfter, 1_000e6, "USDC balance after exit should be 1_000e6");
        assertEq(usdsBalanceAfter, 0, "USDS balance after exit should be 0");
    }

    /// @notice Test chained instant withdrawal: ERC4626 (sUSDS -> USDS) then LitePSM (USDS -> USDC)
    /// @dev Demonstrates the full withdrawal path when funds are deposited into sUSDS via LitePSM + ERC4626.
    ///      Two fuses are chained: first the ERC4626 fuse redeems sUSDS for USDS,
    ///      then the LitePSM fuse swaps USDS back to USDC.
    function testShouldChainErc4626AndLitePsmInstantWithdraw() external {
        // given - create both fuses
        uint256 marketId = 1;
        LitePsmSupplyFuse litePsmFuse = new LitePsmSupplyFuse(marketId);
        Erc4626SupplyFuse erc4626Fuse = new Erc4626SupplyFuse(marketId);
        ZeroBalanceFuse balanceFuse = new ZeroBalanceFuse(marketId);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(litePsmFuse), address(balanceFuse));

        // Grant sUSDS as substrate for the ERC4626 fuse
        address[] memory assets = new address[](1);
        assets[0] = SUSDS;
        vaultMock.updateMarketConfiguration(marketId, assets);

        // Fund vault with 1000 USDC
        deal(USDC, address(vaultMock), 1_000e6);

        // Step 1: USDC -> USDS via LitePSM enter
        vaultMock.execute(
            address(litePsmFuse),
            abi.encodeWithSignature("enter((uint256))", LitePsmSupplyFuseEnterData({amount: 100e6}))
        );

        // Step 2: USDS -> sUSDS via ERC4626 enter
        vaultMock.execute(
            address(erc4626Fuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                Erc4626SupplyFuseEnterData({vault: SUSDS, vaultAssetAmount: 100e18, minSharesOut: 0})
            )
        );

        // Verify state: 900 USDC + sUSDS shares, no USDS
        assertEq(ERC20(USDC).balanceOf(address(vaultMock)), 900e6, "should have 900 USDC");
        assertGt(IERC4626(SUSDS).balanceOf(address(vaultMock)), 0, "should have sUSDS shares");
        assertEq(ERC20(USDS).balanceOf(address(vaultMock)), 0, "should have 0 USDS");

        // when - chain instant withdraw: sUSDS -> USDS -> USDC

        // Step 3: sUSDS -> USDS via ERC4626 instantWithdraw
        // params[0] = USDS amount (underlying of sUSDS), params[1] = sUSDS vault address
        uint256 usdsValue = IERC4626(SUSDS).convertToAssets(IERC4626(SUSDS).balanceOf(address(vaultMock)));
        bytes32[] memory erc4626Params = new bytes32[](2);
        erc4626Params[0] = bytes32(usdsValue);
        erc4626Params[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDS);
        vaultMock.execute(
            address(erc4626Fuse),
            abi.encodeWithSignature("instantWithdraw(bytes32[])", erc4626Params)
        );

        // Step 4: USDS -> USDC via LitePSM instantWithdraw
        // params[0] = USDS amount (18 decimals)
        uint256 usdsBalance = ERC20(USDS).balanceOf(address(vaultMock));
        bytes32[] memory litePsmParams = new bytes32[](1);
        // use the double of the balance to make sure that all got converted
        litePsmParams[0] = bytes32(usdsBalance);
        vaultMock.execute(
            address(litePsmFuse),
            abi.encodeWithSignature("instantWithdraw(bytes32[])", litePsmParams)
        );

        // then - vault should have ~1000 USDC back, no sUSDS, no USDS
        uint256 usdcBalanceAfter = ERC20(USDC).balanceOf(address(vaultMock));
        uint256 susdsBalanceAfter = IERC4626(SUSDS).balanceOf(address(vaultMock));
        uint256 usdsBalanceAfter = ERC20(USDS).balanceOf(address(vaultMock));

        // There may be dust left due to rounding, but it should be negligible (1e12 = 0.000001 USDS)
        uint256 expectedUsdsUsed = 1e12;

        assertGe(usdcBalanceAfter, 999e6, "USDC should be restored to ~1000");
        assertEq(susdsBalanceAfter, 0, "sUSDS should be fully withdrawn");
        assertLe(usdsBalanceAfter, expectedUsdsUsed, "USDS left should be negligible");
    }
}
