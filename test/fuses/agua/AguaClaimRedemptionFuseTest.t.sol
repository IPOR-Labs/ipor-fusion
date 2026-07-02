// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AguaSupplyFuse, AguaSupplyFuseEnterData} from "../../../contracts/fuses/agua/AguaSupplyFuse.sol";
import {AguaRequestRedemptionFuse, AguaRequestRedemptionFuseEnterData} from "../../../contracts/fuses/agua/AguaRequestRedemptionFuse.sol";
import {AguaClaimRedemptionFuse, AguaClaimRedemptionFuseEnterData} from "../../../contracts/fuses/agua/AguaClaimRedemptionFuse.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "../../../contracts/fuses/agua/lib/AguaSubstrateLib.sol";
import {IAguaGlobalCarryVault} from "../../../contracts/fuses/agua/ext/IAguaGlobalCarryVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

/// @title AguaClaimRedemptionFuseTest
/// @notice Fork integration tests for AguaClaimRedemptionFuse (enter = completeRedemption).
/// @dev We deposit USDC via AguaSupplyFuse and open a request via AguaRequestRedemptionFuse first, so
///      the PlasmaVault has a real, escrowed request and the vault holds the USDC needed to pay it.
contract AguaClaimRedemptionFuseTest is Test {
    address public constant AGUA_VAULT = 0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant MARKET_ID = IporFusionMarkets.AGUA_GLOBAL_CARRY;
    uint256 public constant FORK_BLOCK = 25393000;
    uint256 public constant DEPOSIT_AMOUNT = 500e6;

    AguaSupplyFuse public supplyFuse;
    AguaRequestRedemptionFuse public requestFuse;
    AguaClaimRedemptionFuse public claimFuse;
    PlasmaVaultMock public vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        supplyFuse = new AguaSupplyFuse(MARKET_ID);
        requestFuse = new AguaRequestRedemptionFuse(MARKET_ID);
        claimFuse = new AguaClaimRedemptionFuse(MARKET_ID);
        // Primary fuse is the supply fuse; we drive the request/claim fuses via execute().
        vault = new PlasmaVaultMock(address(supplyFuse), address(0));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: AGUA_VAULT})
        );
        substrates[1] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.ASSET, substrateAddress: USDC})
        );
        vault.grantMarketSubstrates(MARKET_ID, substrates);

        vm.label(address(supplyFuse), "AguaSupplyFuse");
        vm.label(address(requestFuse), "AguaRequestRedemptionFuse");
        vm.label(address(claimFuse), "AguaClaimRedemptionFuse");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(AGUA_VAULT, "AguaGlobalCarryVault");
        vm.label(USDC, "USDC");
    }

    // ============ Helpers ============

    /// @dev Deposit USDC into Agua via the supply fuse, returns the shares minted to the PlasmaVault.
    function _deposit(uint256 amount_) internal returns (uint256 shares) {
        deal(USDC, address(vault), amount_);
        vault.execute(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: amount_, minSharesOut: 0})
            )
        );
        shares = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));
    }

    function _request(uint256 shares_) internal {
        vault.execute(
            address(requestFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                AguaRequestRedemptionFuseEnterData({vault: AGUA_VAULT, shares: shares_})
            )
        );
    }

    function _complete() internal {
        vault.execute(
            address(claimFuse),
            abi.encodeWithSignature(
                "enter((address))",
                AguaClaimRedemptionFuseEnterData({vault: AGUA_VAULT})
            )
        );
    }

    // ============ Constructor ============

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new AguaClaimRedemptionFuse(0);
    }

    // ============ Complete (enter) ============

    function testShouldCompleteAfterLockupAndPayUsdc() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        _request(shares);

        (, , uint256 unlockTime, ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(address(vault));
        uint256 expectedPayout = IAguaGlobalCarryVault(AGUA_VAULT).previewCompleteRedemption(address(vault));
        assertGt(expectedPayout, 0, "preview payout should be positive");

        vm.warp(unlockTime + 1);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        _complete();
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(vault));

        assertApproxEqAbs(usdcAfter - usdcBefore, expectedPayout, 2, "USDC payout should match preview");

        (uint256 reqShares, , , ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(address(vault));
        assertEq(reqShares, 0, "request cleared after complete");
    }

    function testShouldRevertCompleteBeforeUnlock() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        _request(shares);

        // Still inside the 5-day lockup → Agua reverts.
        vm.expectRevert();
        _complete();
    }

    function testShouldRevertCompleteWhenNoActiveRequest() public {
        _deposit(DEPOSIT_AMOUNT);

        // No active request → Agua reverts.
        vm.expectRevert();
        _complete();
    }

    // ============ Full Lifecycle ============

    function testShouldRunFullLifecycle() public {
        // deposit -> request -> warp -> complete. NAV roughly conserved minus rounding.
        deal(USDC, address(vault), DEPOSIT_AMOUNT);
        uint256 usdcStart = IERC20(USDC).balanceOf(address(vault));

        vault.execute(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: DEPOSIT_AMOUNT, minSharesOut: 0})
            )
        );
        uint256 shares = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));

        _request(shares);
        (, , uint256 unlockTime, ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(address(vault));
        vm.warp(unlockTime + 1);
        _complete();

        uint256 usdcEnd = IERC20(USDC).balanceOf(address(vault));
        // Standard (non-early) redemption: no fee, so we recover ~the deposit (small rounding only).
        assertApproxEqRel(usdcEnd, usdcStart, 0.001e18, "NAV roughly conserved through the lifecycle");
    }
}
