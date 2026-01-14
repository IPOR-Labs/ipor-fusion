// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapIn, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapIn.sol";
import {ERC4626ZapInAllowance} from "../../contracts/zaps/ERC4626ZapInAllowance.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface CreditEnforcer {
    function mintStablecoin(uint256 amount) external returns (uint256);
}

/// @title ERC4626ZapInMinSharesOutTest
/// @notice Tests for minSharesOut slippage protection in ERC4626ZapIn
contract ERC4626ZapInMinSharesOutTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 21729380;
    PlasmaVault internal plasmaVaultRUsdc = PlasmaVault(0x2D71CC054AA096a1b3739D67303f88C75b1D59dC);
    address internal usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal rUsd = 0x09D4214C03D01F49544C0448DBE3A27f768F2b34;

    address internal creditEnforcer = 0x04716DB62C085D9e08050fcF6F7D775A03d07720;
    address internal pegStabilityModule = 0x4809010926aec940b550D34a46A52739f996D75D;

    ERC4626ZapIn internal zapIn;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK_NUMBER);
        zapIn = new ERC4626ZapIn();
    }

    /// @notice Test successful zap when shares meet minimum
    function testShouldZapInSuccessfullyWhenSharesMeetMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 expectedShares = minAmountToDeposit * 100; // Based on vault exchange rate
        uint256 minSharesOut = expectedShares - 1e18; // Slightly less than expected
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = _createZapInData(user, usdcAmount, minAmountToDeposit, minSharesOut);

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        // when
        zapIn.zapIn(zapInData);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultRUsdc.balanceOf(user);
        assertGe(userShares, minSharesOut, "User should have at least minSharesOut shares");
        assertEq(userShares, expectedShares, "User should have expected shares");
    }

    /// @notice Test revert when shares below minimum
    function testShouldRevertWhenSharesBelowMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 expectedShares = minAmountToDeposit * 100;
        uint256 impossibleMinShares = expectedShares + 1e18; // More than what will be minted
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = _createZapInData(user, usdcAmount, minAmountToDeposit, impossibleMinShares);

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        // when/then
        vm.expectRevert(
            abi.encodeWithSignature(
                "InsufficientSharesOut(uint256,uint256)",
                expectedShares,
                impossibleMinShares
            )
        );
        zapIn.zapIn(zapInData);
        vm.stopPrank();
    }

    /// @notice Test zero minSharesOut (backward compatibility)
    function testShouldAcceptZeroMinSharesOut() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 minSharesOut = 0; // No slippage protection
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = _createZapInData(user, usdcAmount, minAmountToDeposit, minSharesOut);

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        // when
        zapIn.zapIn(zapInData);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultRUsdc.balanceOf(user);
        assertGt(userShares, 0, "User should have shares");
    }

    /// @notice Test edge case: exact minimum shares
    function testShouldPassWhenSharesExactlyEqualMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 expectedShares = minAmountToDeposit * 100;
        uint256 minSharesOut = expectedShares; // Exactly what will be minted
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = _createZapInData(user, usdcAmount, minAmountToDeposit, minSharesOut);

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        // when
        zapIn.zapIn(zapInData);
        vm.stopPrank();

        // then
        uint256 userShares = plasmaVaultRUsdc.balanceOf(user);
        assertEq(userShares, expectedShares, "User should have exact shares");
    }

    /// @notice Test revert when shares slightly below minimum
    function testShouldRevertWhenSharesSlightlyBelowMinimum() public {
        // given
        address user = makeAddr("User");
        uint256 usdcAmount = 10_000e6;
        uint256 minAmountToDeposit = 10_000e18;
        uint256 expectedShares = minAmountToDeposit * 100;
        uint256 minSharesOut = expectedShares + 1; // Just 1 wei more than expected
        deal(usdc, user, usdcAmount);

        ZapInData memory zapInData = _createZapInData(user, usdcAmount, minAmountToDeposit, minSharesOut);

        vm.startPrank(user);
        IERC20(usdc).approve(zapIn.ZAP_IN_ALLOWANCE_CONTRACT(), usdcAmount);

        // when/then
        vm.expectRevert(
            abi.encodeWithSignature(
                "InsufficientSharesOut(uint256,uint256)",
                expectedShares,
                minSharesOut
            )
        );
        zapIn.zapIn(zapInData);
        vm.stopPrank();
    }

    /// @notice Helper function to create ZapInData with proper calls
    function _createZapInData(
        address user,
        uint256 usdcAmount,
        uint256 minAmountToDeposit,
        uint256 minSharesOut
    ) internal view returns (ZapInData memory) {
        Call[] memory calls = new Call[](4);
        calls[0] = Call({
            target: usdc,
            data: abi.encodeWithSelector(IERC20.approve.selector, pegStabilityModule, usdcAmount)
        });
        calls[1] = Call({
            target: zapIn.ZAP_IN_ALLOWANCE_CONTRACT(),
            data: abi.encodeWithSelector(ERC4626ZapInAllowance.transferApprovedAssets.selector, usdc, usdcAmount)
        });
        calls[2] = Call({
            target: address(creditEnforcer),
            data: abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount)
        });
        calls[3] = Call({
            target: address(rUsd),
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultRUsdc), minAmountToDeposit)
        });

        return ZapInData({
            vault: address(plasmaVaultRUsdc),
            receiver: user,
            minAmountToDeposit: usdcAmount,
            minSharesOut: minSharesOut,
            assetsToRefundToSender: new address[](0),
            calls: calls
        });
    }
}
