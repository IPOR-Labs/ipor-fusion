// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AguaSupplyFuse, AguaSupplyFuseEnterData} from "../../../contracts/fuses/agua/AguaSupplyFuse.sol";
import {AguaRequestRedemptionFuse, AguaRequestRedemptionFuseEnterData} from "../../../contracts/fuses/agua/AguaRequestRedemptionFuse.sol";
import {AguaBalanceFuse} from "../../../contracts/fuses/agua/AguaBalanceFuse.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "../../../contracts/fuses/agua/lib/AguaSubstrateLib.sol";
import {IAguaGlobalCarryVault} from "../../../contracts/fuses/agua/ext/IAguaGlobalCarryVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {MockPriceOracleMiddlewareForBalance} from "../../unitTest/fuses/midas/mocks/MockPriceOracleMiddlewareForBalance.sol";

/// @title AguaBalanceFuseTest
/// @notice Fork integration tests for AguaBalanceFuse against the real Agua Global Carry Vault.
/// @dev USDC is priced via a mock price oracle middleware (price 1.0, 18 decimals) for a stable,
///      deterministic 18-decimal USD valuation. Real shares are minted via the supply fuse.
contract AguaBalanceFuseTest is Test {
    address public constant AGUA_VAULT = 0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 public constant USDC_DECIMALS = 6;

    // Mock price: 1 USDC = $1.00 with 18-decimal precision.
    uint256 public constant USDC_PRICE = 1e18;
    uint256 public constant PRICE_DECIMALS = 18;

    uint256 public constant MARKET_ID = IporFusionMarkets.AGUA_GLOBAL_CARRY;
    uint256 public constant FORK_BLOCK = 25393000;
    uint256 public constant DEPOSIT_AMOUNT = 500e6;

    AguaSupplyFuse public supplyFuse;
    AguaRequestRedemptionFuse public requestFuse;
    AguaBalanceFuse public balanceFuse;
    PlasmaVaultMock public vault;
    MockPriceOracleMiddlewareForBalance public oracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        supplyFuse = new AguaSupplyFuse(MARKET_ID);
        requestFuse = new AguaRequestRedemptionFuse(MARKET_ID);
        balanceFuse = new AguaBalanceFuse(MARKET_ID);
        vault = new PlasmaVaultMock(address(supplyFuse), address(balanceFuse));

        oracle = new MockPriceOracleMiddlewareForBalance();
        oracle.setAssetPrice(USDC, USDC_PRICE, PRICE_DECIMALS);
        vault.setPriceOracleMiddleware(address(oracle));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: AGUA_VAULT})
        );
        substrates[1] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.ASSET, substrateAddress: USDC})
        );
        vault.grantMarketSubstrates(MARKET_ID, substrates);

        vm.label(address(balanceFuse), "AguaBalanceFuse");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(AGUA_VAULT, "AguaGlobalCarryVault");
        vm.label(USDC, "USDC");
    }

    // ============ Helpers ============

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

    /// @dev Price a USDC (6-dec) amount to 18-dec USD the same way the fuse does.
    function _toWad(uint256 usdc_) internal pure returns (uint256) {
        return IporMath.convertToWad(usdc_ * USDC_PRICE, USDC_DECIMALS + PRICE_DECIMALS);
    }

    // ============ Constructor ============

    function testShouldReturnCorrectMarketId() public view {
        assertEq(balanceFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldReturnCorrectVersion() public view {
        assertEq(balanceFuse.VERSION(), address(balanceFuse));
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new AguaBalanceFuse(0);
    }

    // ============ Balance ============

    function testShouldReturnZeroWhenEmpty() public {
        assertEq(vault.balanceOf(), 0, "balance should be zero with no shares and no request");
    }

    function testShouldReturnZeroWhenNoSubstratesGranted() public {
        // Fresh vault with the balance fuse but no granted substrates -> len == 0 early return.
        AguaBalanceFuse freshBalance = new AguaBalanceFuse(MARKET_ID);
        PlasmaVaultMock freshVault = new PlasmaVaultMock(address(supplyFuse), address(freshBalance));
        freshVault.setPriceOracleMiddleware(address(oracle));

        assertEq(freshVault.balanceOf(), 0, "balance should be zero when no substrates are granted");
    }

    function testShouldReturnFreeSharesOnly() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);

        uint256 expectedUsdc = IAguaGlobalCarryVault(AGUA_VAULT).convertToAssets(shares);
        uint256 expected = _toWad(expectedUsdc);

        uint256 balance = vault.balanceOf();
        assertEq(balance, expected, "free leg should equal convertToAssets priced to WAD");
    }

    function testShouldIncludePendingLegWithoutDoubleCount() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        uint256 freeUsdcBefore = IAguaGlobalCarryVault(AGUA_VAULT).convertToAssets(shares);

        // Request half: those shares leave balanceOf and move to the frozen pending leg.
        uint256 requestShares = shares / 2;
        _request(requestShares);

        uint256 freeUsdc = IAguaGlobalCarryVault(AGUA_VAULT).convertToAssets(
            IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault))
        );
        uint256 pendingUsdc = IAguaGlobalCarryVault(AGUA_VAULT).previewCompleteRedemption(address(vault));
        assertGt(pendingUsdc, 0, "pending leg should be positive");

        uint256 expected = _toWad(freeUsdc + pendingUsdc);
        assertEq(vault.balanceOf(), expected, "balance = free + pending, no double-count");

        // Sanity: total (free + pending) ~ the pre-request free value (no value lost/duplicated).
        assertApproxEqAbs(freeUsdc + pendingUsdc, freeUsdcBefore, 2, "no double-count vs pre-request NAV");
    }

    function testShouldKeepPendingLegFrozenAcrossWarp() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);
        _request(shares);

        uint256 pendingSnapshot = IAguaGlobalCarryVault(AGUA_VAULT).previewCompleteRedemption(address(vault));
        uint256 balanceBefore = vault.balanceOf();

        // Warp forward; the pending leg is frozen at request time and must not move.
        vm.warp(block.timestamp + 10 days);

        uint256 pendingAfter = IAguaGlobalCarryVault(AGUA_VAULT).previewCompleteRedemption(address(vault));
        assertEq(pendingAfter, pendingSnapshot, "pending leg frozen across warp");
        assertEq(vault.balanceOf(), balanceBefore, "balance unchanged while only pending leg present");
        assertEq(vault.balanceOf(), _toWad(pendingSnapshot), "balance equals frozen pending leg priced to WAD");
    }

    function testShouldRevertWhenPriceOracleNotSet() public {
        // Fresh vault with shares but no price oracle middleware set.
        AguaBalanceFuse freshBalance = new AguaBalanceFuse(MARKET_ID);
        PlasmaVaultMock freshVault = new PlasmaVaultMock(address(supplyFuse), address(freshBalance));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.VAULT, substrateAddress: AGUA_VAULT})
        );
        substrates[1] = AguaSubstrateLib.substrateToBytes32(
            AguaSubstrate({substrateType: AguaSubstrateType.ASSET, substrateAddress: USDC})
        );
        freshVault.grantMarketSubstrates(MARKET_ID, substrates);

        // Give it real shares so usdc != 0 and the oracle branch is reached.
        deal(USDC, address(freshVault), DEPOSIT_AMOUNT);
        freshVault.execute(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AguaSupplyFuseEnterData({vault: AGUA_VAULT, assetAmount: DEPOSIT_AMOUNT, minSharesOut: 0})
            )
        );

        vm.expectRevert(AguaBalanceFuse.AguaBalanceFusePriceOracleNotSet.selector);
        freshVault.balanceOf();
    }
}
