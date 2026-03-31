// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../test/OlympixUnitTest.sol";
import {ERC4626ZapInAllowance} from "../../../contracts/zaps/ERC4626ZapInAllowance.sol";

import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IERC4626ZapIn} from "contracts/zaps/ERC4626ZapInAllowance.sol";
import {ERC4626ZapInAllowance} from "contracts/zaps/ERC4626ZapInAllowance.sol";
contract ERC4626ZapInAllowanceTest is OlympixUnitTest("ERC4626ZapInAllowance") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_transferApprovedAssets_RevertWhenNotCalledByZapIn() public {
            // deploy allowance helper with some dummy zap-in address
            address zapIn = address(0x1234);
            ERC4626ZapInAllowance allowance = new ERC4626ZapInAllowance(zapIn);
    
            // call from a non-zap-in address should revert and hit the `if (msg.sender != ERC4626_ZAP_IN)` branch
            vm.expectRevert(ERC4626ZapInAllowance.NotERC4626ZapIn.selector);
            allowance.transferApprovedAssets(address(0x1), 1);
        }

    function test_transferApprovedAssets_SuccessPathAndValidations() public {
            // Set up a mock ERC4626ZapIn caller that returns a non-zero zap sender
            address zapIn = address(this);
            ERC4626ZapInAllowance allowance = new ERC4626ZapInAllowance(zapIn);
    
            // Create mock ERC20 asset and mint to currentZapSender
            MockERC20 asset = new MockERC20("Mock", "MOCK", 18);
            address currentZapSender = address(0xABCD);
            asset.mint(currentZapSender, 1_000 ether);
    
            // Mock IERC4626ZapIn.currentZapSender() on this test contract so that
            // IERC4626ZapIn(zapIn).currentZapSender() returns currentZapSender
            // Foundry vm.mockCall is available via OlympixUnitTest/Test
            bytes memory ret = abi.encode(currentZapSender);
            vm.mockCall(
                zapIn,
                abi.encodeWithSelector(IERC4626ZapIn.currentZapSender.selector),
                ret
            );
    
            // Approve allowance helper (which will pull from currentZapSender to zapIn)
            vm.startPrank(currentZapSender);
            asset.approve(address(allowance), 500 ether);
            vm.stopPrank();
    
            // Expect event emission
            vm.expectEmit(true, true, false, true);
            emit ERC4626ZapInAllowance.AssetsTransferred(currentZapSender, address(asset), 500 ether);
    
            // Call from the zapIn address so msg.sender == ERC4626_ZAP_IN and we hit the else branch
            vm.prank(zapIn);
            allowance.transferApprovedAssets(address(asset), 500 ether);
    
            // Validate balances: 500 moved from currentZapSender to zapIn
            assertEq(asset.balanceOf(currentZapSender), 500 ether, "sender balance after transfer");
            assertEq(asset.balanceOf(zapIn), 500 ether, "zapIn balance after transfer");
        }

    function test_transferApprovedAssets_AmountZero_RevertsAmountIsZero() public {
            // set ERC4626_ZAP_IN to this test contract so we can prank from it
            address zapIn = address(this);
            ERC4626ZapInAllowance allowance = new ERC4626ZapInAllowance(zapIn);
    
            // call from the zapIn address so the initial NotERC4626ZapIn check passes
            vm.prank(zapIn);
            vm.expectRevert(ERC4626ZapInAllowance.AmountIsZero.selector);
            allowance.transferApprovedAssets(address(0x1), 0);
        }

    function test_transferApprovedAssets_AssetIsZero_RevertsAssetIsZero() public {
            // Arrange: set ERC4626_ZAP_IN to this test contract so we can prank from it
            address zapIn = address(this);
            ERC4626ZapInAllowance allowance = new ERC4626ZapInAllowance(zapIn);
    
            // Mock IERC4626ZapIn.currentZapSender() to return non-zero so we pass previous checks
            address currentZapSender = address(0xABCD);
            bytes memory ret = abi.encode(currentZapSender);
            vm.mockCall(
                zapIn,
                abi.encodeWithSelector(IERC4626ZapIn.currentZapSender.selector),
                ret
            );
    
            // Act & Assert: call with asset_ == address(0) and non-zero amount, expect AssetIsZero revert
            vm.prank(zapIn);
            vm.expectRevert(ERC4626ZapInAllowance.AssetIsZero.selector);
            allowance.transferApprovedAssets(address(0), 1 ether);
        }

    function test_transferApprovedAssets_CurrentZapSenderZero_Reverts() public {
            // Arrange: set ERC4626_ZAP_IN to this test contract so we can prank from it
            address zapIn = address(this);
            ERC4626ZapInAllowance allowance = new ERC4626ZapInAllowance(zapIn);
    
            // Use a non-zero asset and amount to pass previous checks
            MockERC20 asset = new MockERC20("Mock", "MOCK", 18);
    
            // Mock IERC4626ZapIn.currentZapSender() to return address(0)
            bytes memory ret = abi.encode(address(0));
            vm.mockCall(
                zapIn,
                abi.encodeWithSelector(IERC4626ZapIn.currentZapSender.selector),
                ret
            );
    
            // Act & Assert: call from zapIn so msg.sender == ERC4626_ZAP_IN, expect CurrentZapSenderIsZero revert
            vm.prank(zapIn);
            vm.expectRevert(ERC4626ZapInAllowance.CurrentZapSenderIsZero.selector);
            allowance.transferApprovedAssets(address(asset), 1 ether);
        }
}