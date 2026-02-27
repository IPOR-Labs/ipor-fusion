// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapInWithNativeToken, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../fuses/erc4626/IWETH9.sol";

/// @title ERC4626ZapInMevProtectionTest
/// @notice Fork integration tests simulating MEV donation attacks and slippage protection
contract ERC4626ZapInMevProtectionTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 32275361;
    PlasmaVault internal plasmaVaultWeth = PlasmaVault(0x7872893e528Fe2c0829e405960db5B742112aa97);
    address internal weth = 0x4200000000000000000000000000000000000006;

    ERC4626ZapInWithNativeToken internal zapIn;
    address internal attacker;
    address internal user;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK_NUMBER);
        zapIn = new ERC4626ZapInWithNativeToken();
        attacker = makeAddr("Attacker");
        user = makeAddr("User");
    }

    /// @notice Simulate MEV donation attack and verify protection works
    function testShouldProtectAgainstMevDonationAttack() public {
        // given
        uint256 userDepositAmount = 100e18;
        deal(user, userDepositAmount);

        // Calculate expected shares BEFORE any manipulation
        uint256 sharesBeforeAttack = plasmaVaultWeth.previewDeposit(userDepositAmount);

        // User sets minSharesOut with 0.5% slippage tolerance
        uint256 minSharesWithSlippage = (sharesBeforeAttack * 9950) / 10000;

        // Attacker donates WETH directly to vault to manipulate exchange rate
        uint256 donationAmount = 1000e18;
        deal(weth, attacker, donationAmount);

        vm.prank(attacker);
        IERC20(weth).transfer(address(plasmaVaultWeth), donationAmount);

        // After donation, shares will be worth more, user gets fewer shares
        uint256 sharesAfterAttack = plasmaVaultWeth.previewDeposit(userDepositAmount);

        // Verify attack changed the exchange rate
        assertLt(sharesAfterAttack, sharesBeforeAttack, "Shares should decrease after MEV donation");

        ZapInData memory zapInData = _createZapInData(user, userDepositAmount, minSharesWithSlippage);

        // when - transaction should revert because slippage exceeds tolerance
        vm.startPrank(user);

        // If sharesAfterAttack < minSharesWithSlippage, it should revert
        if (sharesAfterAttack < minSharesWithSlippage) {
            vm.expectRevert(); // Generic revert - shares mismatch due to rounding
        }
        zapIn.zapIn{value: userDepositAmount}(zapInData);
        vm.stopPrank();
    }

    /// @notice Show vulnerability without minSharesOut protection
    function testShouldShowVulnerabilityWithoutMinSharesOut() public {
        // given
        uint256 userDepositAmount = 100e18;
        deal(user, userDepositAmount);

        // Calculate expected shares BEFORE attack
        uint256 sharesBeforeAttack = plasmaVaultWeth.previewDeposit(userDepositAmount);

        // Attacker performs MEV donation
        uint256 donationAmount = 1000e18;
        deal(weth, attacker, donationAmount);

        vm.prank(attacker);
        IERC20(weth).transfer(address(plasmaVaultWeth), donationAmount);

        uint256 sharesAfterAttack = plasmaVaultWeth.previewDeposit(userDepositAmount);

        // User has NO protection (minSharesOut = 0)
        ZapInData memory zapInData = _createZapInData(user, userDepositAmount, 0);

        // when - transaction proceeds despite MEV attack
        vm.startPrank(user);
        zapIn.zapIn{value: userDepositAmount}(zapInData);
        vm.stopPrank();

        // then - user received fewer shares than expected
        uint256 actualShares = plasmaVaultWeth.balanceOf(user);

        assertLt(sharesAfterAttack, sharesBeforeAttack, "Attack should reduce share value");
        // Allow small rounding difference (< 0.001%)
        assertApproxEqRel(actualShares, sharesAfterAttack, 1e14, "User receives post-attack share amount");
        assertLt(actualShares, sharesBeforeAttack, "User is vulnerable without protection");
    }

    /// @notice Calculate correct minShares using previewDeposit
    function testShouldCalculateCorrectMinSharesFromPreview() public {
        // given
        uint256 userDepositAmount = 50e18;
        deal(user, userDepositAmount);

        // Frontend calculates minSharesOut using previewDeposit with 0.5% slippage
        uint256 expectedShares = plasmaVaultWeth.previewDeposit(userDepositAmount);
        uint256 minSharesWithSlippage = (expectedShares * 9950) / 10000;

        ZapInData memory zapInData = _createZapInData(user, userDepositAmount, minSharesWithSlippage);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: userDepositAmount}(zapInData);
        vm.stopPrank();

        // then
        uint256 actualShares = plasmaVaultWeth.balanceOf(user);
        assertGe(actualShares, minSharesWithSlippage, "Actual shares should meet minimum");
        // Allow small rounding difference (< 0.001%)
        assertApproxEqRel(actualShares, expectedShares, 1e14, "Actual shares should equal preview");
    }

    /// @notice Test protection against large exchange rate manipulation
    function testShouldHandleExchangeRateManipulation() public {
        // given
        uint256 userDepositAmount = 10e18;
        deal(user, userDepositAmount);

        uint256 sharesBeforeManipulation = plasmaVaultWeth.previewDeposit(userDepositAmount);

        // Conservative 1% slippage tolerance
        uint256 minSharesConservative = (sharesBeforeManipulation * 9900) / 10000;

        // Large donation - significant rate manipulation
        uint256 largeDonation = 10000e18;
        deal(weth, attacker, largeDonation);

        vm.prank(attacker);
        IERC20(weth).transfer(address(plasmaVaultWeth), largeDonation);

        uint256 sharesAfterManipulation = plasmaVaultWeth.previewDeposit(userDepositAmount);

        ZapInData memory zapInData = _createZapInData(user, userDepositAmount, minSharesConservative);

        // when - large manipulation should trigger revert
        vm.startPrank(user);

        if (sharesAfterManipulation < minSharesConservative) {
            vm.expectRevert(); // Generic revert - shares below minimum
        }
        zapIn.zapIn{value: userDepositAmount}(zapInData);
        vm.stopPrank();
    }

    /// @notice Test with various slippage tolerances
    function testShouldWorkWithVariousSlippageTolerances() public {
        uint256 userDepositAmount = 100e18;

        // Test different slippage tolerances
        uint256[] memory slippages = new uint256[](3);
        slippages[0] = 50; // 0.5%
        slippages[1] = 100; // 1%
        slippages[2] = 300; // 3%

        for (uint256 i = 0; i < slippages.length; i++) {
            // Reset state for each test
            vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK_NUMBER);
            zapIn = new ERC4626ZapInWithNativeToken();

            address testUser = makeAddr(string(abi.encodePacked("User", i)));
            deal(testUser, userDepositAmount);

            uint256 expectedShares = plasmaVaultWeth.previewDeposit(userDepositAmount);
            uint256 minSharesOut = (expectedShares * (10000 - slippages[i])) / 10000;

            ZapInData memory zapInData = _createZapInData(testUser, userDepositAmount, minSharesOut);

            vm.startPrank(testUser);
            zapIn.zapIn{value: userDepositAmount}(zapInData);
            vm.stopPrank();

            uint256 actualShares = plasmaVaultWeth.balanceOf(testUser);
            assertGe(actualShares, minSharesOut, "Should meet minimum for each slippage level");
        }
    }

    /// @notice Helper function to create ZapInData
    function _createZapInData(
        address receiver,
        uint256 ethAmount,
        uint256 minSharesOut
    ) internal view returns (ZapInData memory) {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: weth,
            data: abi.encodeWithSelector(IWETH9.deposit.selector),
            nativeTokenAmount: ethAmount
        });
        calls[1] = Call({
            target: weth,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultWeth), ethAmount),
            nativeTokenAmount: 0
        });

        return
            ZapInData({
                vault: address(plasmaVaultWeth),
                receiver: receiver,
                minAmountToDeposit: ethAmount,
                minSharesOut: minSharesOut,
                assetsToRefundToSender: new address[](0),
                calls: calls
            });
    }
}
