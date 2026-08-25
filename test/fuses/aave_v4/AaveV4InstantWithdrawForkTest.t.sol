// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4SupplyFuse} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {AaveV4ForkTestBase} from "./AaveV4ForkTestBase.sol";

/// @title AaveV4InstantWithdrawForkTest
/// @notice User withdrawals pulling USDC liquidity from the live Bluechip spoke through
///         AaveV4SupplyFuse.instantWithdraw, and the collateral guard on that path.
contract AaveV4InstantWithdrawForkTest is AaveV4ForkTestBase {
    uint256 private constant USDC_SUPPLY = 50_000e6;

    /// @dev USDC (Prime hub) as plain supply -> instant-withdrawable; WETH as collateral
    function _defaultGrants() internal pure override returns (bytes32[] memory grants) {
        grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, false);
    }

    function testShouldPullLiquidityFromAaveV4OnUserWithdraw() public {
        // given - 50k USDC supplied, 50k USDC cash left in the vault
        _executeOne(_supplyAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_SUPPLY, 0));
        _configureInstantWithdraw(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME);

        uint256 withdrawAmount = 80_000e6;
        uint256 userBefore = IERC20(USDC).balanceOf(user);
        uint256 suppliedBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        uint256 vaultCashBefore = IERC20(USDC).balanceOf(address(plasmaVault));

        // when
        vm.prank(user);
        plasmaVault.withdraw(withdrawAmount, user, user);

        // then - the missing 30k (+ vault offset) came from Aave V4
        assertEq(IERC20(USDC).balanceOf(user) - userBefore, withdrawAmount, "user received USDC");
        uint256 pulled = suppliedBefore - _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);
        assertApproxEqAbs(pulled, withdrawAmount - vaultCashBefore, 1e3, "liquidity pulled from Aave");
    }

    function testShouldNotTouchAaveV4WhenVaultCashCoversWithdraw() public {
        // given
        _executeOne(_supplyAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_SUPPLY, 0));
        _configureInstantWithdraw(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME);
        uint256 suppliedBefore = _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME);

        // when - 20k out of 50k cash
        vm.prank(user);
        plasmaVault.withdraw(20_000e6, user, user);

        // then
        assertEq(_supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), suppliedBefore, "Aave position untouched");
    }

    function testShouldRevertUserWithdrawWhenReserveIsCollateralOnChainDespitePlainGrant() public {
        // given - USDC enabled as collateral while granted as collateral, then downgraded to plain
        bytes32[] memory collateralGrants = new bytes32[](2);
        collateralGrants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        collateralGrants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, true, false);
        _grantReserves(collateralGrants);
        _executeOne(_supplyAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_SUPPLY, 0));
        _executeOne(_enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME));
        _grantReserves(_defaultGrants());
        _configureInstantWithdraw(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME);

        // when/then - on-chain collateral status blocks the instant-withdraw path
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInstantWithdrawNotAllowed.selector,
                BLUECHIP_SPOKE,
                BLUECHIP_USDC_PRIME
            )
        );
        vm.prank(user);
        plasmaVault.withdraw(80_000e6, user, user);

        // and after the alpha disables collateral the same withdrawal succeeds
        _executeOne(_disableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME));
        vm.prank(user);
        plasmaVault.withdraw(80_000e6, user, user);
        assertLt(
            _supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME),
            USDC_SUPPLY,
            "liquidity pulled after collateral disabled"
        );
    }

    function testShouldRevertUserWithdrawWhenInstantWithdrawReserveMayBeCollateral() public {
        // given - supplied while plain, then the atomist flags the reserve as collateral
        _executeOne(_supplyAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, USDC_SUPPLY, 0));
        _configureInstantWithdraw(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME);

        bytes32[] memory grants = new bytes32[](2);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, true, false);
        _grantReserves(grants);

        // when/then - the instant-withdraw path refuses a collateral-capable reserve
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4SupplyFuse.AaveV4SupplyFuseInstantWithdrawNotAllowed.selector,
                BLUECHIP_SPOKE,
                BLUECHIP_USDC_PRIME
            )
        );
        vm.prank(user);
        plasmaVault.withdraw(80_000e6, user, user);

        // and the alpha can still unwind through the regular exit
        _executeOne(_withdrawAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, type(uint256).max, 0));
        assertLe(_supplied(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME), 1);
    }
}
