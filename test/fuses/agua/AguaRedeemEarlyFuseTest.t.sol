// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AguaSupplyFuse, AguaSupplyFuseEnterData} from "../../../contracts/fuses/agua/AguaSupplyFuse.sol";
import {AguaRedeemEarlyFuse, AguaRedeemEarlyFuseEnterData} from "../../../contracts/fuses/agua/AguaRedeemEarlyFuse.sol";
import {AguaSubstrateLib, AguaSubstrate, AguaSubstrateType} from "../../../contracts/fuses/agua/lib/AguaSubstrateLib.sol";
import {IAguaGlobalCarryVault} from "../../../contracts/fuses/agua/ext/IAguaGlobalCarryVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

/// @title AguaRedeemEarlyFuseTest
/// @notice Fork integration tests for AguaRedeemEarlyFuse (enter = redeemEarly, charging the fee).
/// @dev We deposit USDC via AguaSupplyFuse first so the PlasmaVault holds REAL backed shares and the
///      vault holds the USDC needed to pay redeemEarly.
contract AguaRedeemEarlyFuseTest is Test {
    address public constant AGUA_VAULT = 0xa98b4A70E17e55045CDE4972B95Bc2E8CEC22a0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant MARKET_ID = IporFusionMarkets.AGUA_GLOBAL_CARRY;
    uint256 public constant FORK_BLOCK = 25393000;
    uint256 public constant DEPOSIT_AMOUNT = 500e6;

    AguaSupplyFuse public supplyFuse;
    AguaRedeemEarlyFuse public redeemEarlyFuse;
    PlasmaVaultMock public vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        supplyFuse = new AguaSupplyFuse(MARKET_ID);
        redeemEarlyFuse = new AguaRedeemEarlyFuse(MARKET_ID);
        // Primary fuse is the supply fuse; we drive the redeem-early fuse via execute().
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
        vm.label(address(redeemEarlyFuse), "AguaRedeemEarlyFuse");
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

    function _redeemEarly(uint256 shares_, uint256 minAssetsOut_) internal {
        vault.execute(
            address(redeemEarlyFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AguaRedeemEarlyFuseEnterData({vault: AGUA_VAULT, shares: shares_, minAssetsOut: minAssetsOut_})
            )
        );
    }

    // ============ Constructor ============

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new AguaRedeemEarlyFuse(0);
    }

    // ============ Redeem Early (enter) ============

    function testShouldRedeemEarlyPayingUsdcMinusFee() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);

        uint256 fullValue = IAguaGlobalCarryVault(AGUA_VAULT).convertToAssets(shares);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        _redeemEarly(shares, 1);
        uint256 received = IERC20(USDC).balanceOf(address(vault)) - usdcBefore;

        assertGt(received, 0, "should receive USDC");
        // ~5% early-redemption fee → received well below full live value.
        assertLt(received, fullValue, "should be net of the early-redemption fee");
        assertApproxEqRel(received, (fullValue * 95) / 100, 0.01e18, "approx 5% fee applied");

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), 0, "shares burned");
    }

    function testShouldRevertRedeemEarlyOnSlippage() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);

        // Demand far more USDC than the post-fee payout → Agua reverts on minAssetsOut.
        uint256 minAssetsOut = DEPOSIT_AMOUNT * 2;
        vm.expectRevert();
        _redeemEarly(shares, minAssetsOut);
    }

    function testShouldClampRedeemEarlyToBalance() public {
        uint256 shares = _deposit(DEPOSIT_AMOUNT);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        // Redeem more than held → clamp to full balance.
        _redeemEarly(shares * 10, 1);

        assertGt(IERC20(USDC).balanceOf(address(vault)) - usdcBefore, 0, "should receive USDC for clamped shares");
        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), 0, "all held shares burned");
    }

    function testShouldNoopRedeemEarlyWhenZero() public {
        _deposit(DEPOSIT_AMOUNT);
        uint256 sharesBefore = IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));

        // Shares are held, but a zero share request is a no-op (clamped to 0 -> early return).
        _redeemEarly(0, 0);

        assertEq(IAguaGlobalCarryVault(AGUA_VAULT).balanceOf(address(vault)), sharesBefore, "no shares burned");
        assertEq(IERC20(USDC).balanceOf(address(vault)), usdcBefore, "no USDC received");
    }
}
