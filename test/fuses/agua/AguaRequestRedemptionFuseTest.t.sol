// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AguaSupplyFuse, AguaSupplyFuseEnterData} from "../../../contracts/fuses/agua/AguaSupplyFuse.sol";
import {AguaRequestRedemptionFuse, AguaRequestRedemptionFuseEnterData, AguaRequestRedemptionFuseExitData} from "../../../contracts/fuses/agua/AguaRequestRedemptionFuse.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "../../../contracts/fuses/agua/lib/AguaSubstrateLib.sol";
import {IAguaGlobalCarryVault} from "../../../contracts/fuses/agua/ext/IAguaGlobalCarryVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

/// @title AguaRequestRedemptionFuseTest
/// @notice Fork integration tests for AguaRequestRedemptionFuse (enter = request, exit = cancel).
/// @dev We deposit USDC via AguaSupplyFuse first so the PlasmaVault holds REAL backed shares.
contract AguaRequestRedemptionFuseTest is Test {
    address public constant AGUA_VAULT = 0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant MARKET_ID = IporFusionMarkets.AGUA_GLOBAL_CARRY;
    uint256 public constant FORK_BLOCK = 25393000;
    uint256 public constant DEPOSIT_AMOUNT = 500e6;

    AguaSupplyFuse public supplyFuse;
    AguaRequestRedemptionFuse public requestFuse;
    PlasmaVaultMock public vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        supplyFuse = new AguaSupplyFuse(MARKET_ID);
        requestFuse = new AguaRequestRedemptionFuse(MARKET_ID);
        // Primary fuse is the supply fuse; we drive the request fuse via execute().
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

    function _cancel() internal {
        vault.execute(
            address(requestFuse),
            abi.encodeWithSignature(
                "exit((address))",
                AguaRequestRedemptionFuseExitData({vault: AGUA_VAULT})
            )
        );
    }

    // ============ Constructor ============

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new AguaRequestRedemptionFuse(0);
    }

    // ============ Request (enter) ============

    function testShouldEscrowSharesOutOfVaultBalance() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        assertGt(shares, 0, "deposit should mint shares");

        _request(shares);

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), 0, "shares escrowed out of balance");

        (uint256 reqShares, , uint256 unlockTime, ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(
            address(vault)
        );
        assertEq(reqShares, shares, "request should hold the escrowed shares");
        assertGt(unlockTime, block.timestamp, "unlock time in the future");
    }

    function testShouldRevertWhenRequestAlreadyActive() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        _request(shares / 2);

        // Second request while one is active → typed revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                AguaRequestRedemptionFuse.AguaRequestRedemptionFuseRequestAlreadyActive.selector,
                AGUA_VAULT
            )
        );
        _request(shares / 4);
    }

    function testShouldClampRequestToBalance() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);

        // Request more than held → clamp to full balance.
        _request(shares * 10);

        (uint256 reqShares, , , ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(address(vault));
        assertEq(reqShares, shares, "request clamped to share balance");
    }

    function testShouldNoopRequestWhenZero() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 sharesBefore = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));

        _request(0);

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), sharesBefore, "no escrow on zero");
        (uint256 reqShares, , , ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(address(vault));
        assertEq(reqShares, 0, "no active request");
    }

    // ============ Cancel (exit) ============

    function testShouldCancelAndReturnShares() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        _request(shares);
        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), 0, "escrowed");

        _cancel();

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), shares, "shares returned");
        (uint256 reqShares, , , ) = IAguaGlobalCarryVault(AGUA_VAULT).getRedemptionRequest(address(vault));
        assertEq(reqShares, 0, "request cleared after cancel");
    }

    function testShouldRevertCancelWhenNoActiveRequest() public {
        _deposit(DEPOSIT_AMOUNT);

        // No active request → Agua reverts.
        vm.expectRevert();
        _cancel();
    }
}
