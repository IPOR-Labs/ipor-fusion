// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AguaSupplyFuse, AguaSupplyFuseEnterData} from "../../../contracts/fuses/agua/AguaSupplyFuse.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "../../../contracts/fuses/agua/lib/AguaSubstrateLib.sol";
import {IAguaGlobalCarryVault} from "../../../contracts/fuses/agua/ext/IAguaGlobalCarryVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

/// @title AguaSupplyFuseTest
/// @notice Fork integration tests for AguaSupplyFuse against the real Agua Global Carry Vault.
contract AguaSupplyFuseTest is Test {
    address public constant AGUA_VAULT = 0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant MARKET_ID = IporFusionMarkets.AGUA_GLOBAL_CARRY;
    uint256 public constant FORK_BLOCK = 25393000;

    AguaSupplyFuse public fuse;
    PlasmaVaultMock public vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        fuse = new AguaSupplyFuse(MARKET_ID);
        vault = new PlasmaVaultMock(address(fuse), address(0));

        _grantSubstrates(vault);

        vm.label(address(fuse), "AguaSupplyFuse");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(AGUA_VAULT, "AguaGlobalCarryVault");
        vm.label(USDC, "USDC");
    }

    function _grantSubstrates(PlasmaVaultMock vault_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: AGUA_VAULT})
        );
        substrates[1] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.ASSET, substrateAddress: USDC})
        );
        vault_.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _enter(PlasmaVaultMock vault_, AguaSupplyFuseEnterData memory data_) internal {
        vault_.execute(address(fuse), abi.encodeWithSignature("enter((address,uint256,uint256))", data_));
    }

    // ============ Constructor Tests ============

    function testShouldReturnCorrectVersion() public view {
        assertEq(fuse.VERSION(), address(fuse));
    }

    function testShouldReturnCorrectMarketId() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new AguaSupplyFuse(0);
    }

    // ============ Enter Tests ============

    function testShouldDepositAndReceiveShares() public {
        uint256 amount = 500e6;
        deal(USDC, address(vault), amount);

        uint256 sharesBefore = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));

        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: amount, minSharesOut: 1}));

        uint256 sharesAfter = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(vault));

        assertGt(sharesAfter, sharesBefore, "shares should increase");
        assertEq(usdcBefore - usdcAfter, amount, "USDC should decrease by deposit amount");
        assertEq(ERC20(USDC).allowance(address(vault), AGUA_VAULT), 0, "approval should be cleaned up");
    }

    function testShouldClampToMaxDeposit() public {
        // Request way above the deposit cap (~973 USDC headroom). Should not revert; deposits <= cap.
        uint256 cap = IAguaGlobalCarryVault(AGUA_VAULT).maxDeposit(address(vault));
        uint256 amount = cap + 10_000e6;
        deal(USDC, address(vault), amount);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));

        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: amount, minSharesOut: 0}));

        uint256 spent = usdcBefore - IERC20(USDC).balanceOf(address(vault));
        assertLe(spent, cap, "should never deposit more than maxDeposit");
        assertGt(spent, 0, "should deposit up to the cap");
        assertGt(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), 0, "shares received");
    }

    function testShouldClampToBalance() public {
        // Vault holds only 200 USDC but the request asks for 500.
        uint256 balance = 200e6;
        deal(USDC, address(vault), balance);

        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: 500e6, minSharesOut: 0}));

        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "all available USDC deposited (clamped to balance)");
        assertGt(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), 0, "shares received");
    }

    function testShouldNoopWhenZeroAmount() public {
        deal(USDC, address(vault), 500e6);
        uint256 sharesBefore = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));

        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: 0, minSharesOut: 0}));

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), sharesBefore, "no shares minted");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 500e6, "no USDC spent");
    }

    function testShouldNoopWhenClampedToZero() public {
        // assetAmount > 0 but the vault holds no USDC -> clamp to 0 -> finalAmount == 0 early return.
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "precondition: no USDC held");
        uint256 sharesBefore = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));

        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: 500e6, minSharesOut: 0}));

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), sharesBefore, "no shares minted");
    }

    function testShouldRevertOnBadSlippage() public {
        uint256 amount = 500e6;
        deal(USDC, address(vault), amount);

        // 500 USDC mints ~499 shares (< 1e18 per USDC); demanding 1000e18 is impossible.
        uint256 minSharesOut = 1000e18;
        vm.expectRevert(); // AguaSupplyFuseInsufficientShares(shares, minSharesOut)
        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: amount, minSharesOut: minSharesOut}));
    }

    function testShouldRevertWhenVaultSubstrateNotGranted() public {
        AguaSupplyFuse freshFuse = new AguaSupplyFuse(MARKET_ID);
        PlasmaVaultMock freshVault = new PlasmaVaultMock(address(freshFuse), address(0));
        deal(USDC, address(freshVault), 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                AguaSubstrateLib.AguaFuseUnsupportedSubstrate.selector,
                uint8(AguaSubstrateType.VAULT),
                AGUA_VAULT
            )
        );
        freshVault.execute(
            address(freshFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: 500e6, minSharesOut: 0})
            )
        );
    }

    function testShouldRevertWhenAssetSubstrateNotGranted() public {
        AguaSupplyFuse freshFuse = new AguaSupplyFuse(MARKET_ID);
        PlasmaVaultMock freshVault = new PlasmaVaultMock(address(freshFuse), address(0));

        // Grant only the VAULT substrate, not the ASSET (USDC) substrate.
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: AGUA_VAULT})
        );
        freshVault.grantMarketSubstrates(MARKET_ID, substrates);
        deal(USDC, address(freshVault), 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(
                AguaSubstrateLib.AguaFuseUnsupportedSubstrate.selector,
                uint8(AguaSubstrateType.ASSET),
                USDC
            )
        );
        freshVault.execute(
            address(freshFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: 500e6, minSharesOut: 0})
            )
        );
    }

    function testShouldRevertOnExit() public {
        vm.expectRevert(AguaSupplyFuse.AguaSupplyFuseExitNotSupported.selector);
        vault.execute(address(fuse), abi.encodeWithSignature("exit(bytes)", bytes("")));
    }

    function testShouldEmitEnterEvent() public {
        uint256 amount = 500e6;
        deal(USDC, address(vault), amount);

        // The event has no indexed params; the 4th `false` skips data comparison, so we only
        // assert the AguaSupplyFuseEnter signature is emitted (shares value is not checked here).
        vm.expectEmit(true, true, true, false, address(vault));
        emit AguaSupplyFuse.AguaSupplyFuseEnter(fuse.VERSION(), AGUA_VAULT, amount, 0);

        _enter(vault, AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: amount, minSharesOut: 0}));
    }
}
