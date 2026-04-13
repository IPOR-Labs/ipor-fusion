// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/midas/MidasSupplyFuse.sol

import {MidasSupplyFuse, MidasSupplyFuseEnterData} from "contracts/fuses/midas/MidasSupplyFuse.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {MidasPendingRequestsHelper} from "test/fuses/midas/MidasPendingRequestsHelper.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IMidasDepositVault} from "contracts/fuses/midas/ext/IMidasDepositVault.sol";
import {MidasSubstrateLib, MidasSubstrateType, MidasSubstrate} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {MidasSupplyFuse, MidasSupplyFuseExitData} from "contracts/fuses/midas/MidasSupplyFuse.sol";
contract MidasSupplyFuseTest is OlympixUnitTest("MidasSupplyFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_whenAmountNonZero_entersElseBranchAndRevertsOnUnsupportedSubstrate() public {
            // set up minimal environment: mock vault (as PlasmaVault) and fuse
            uint256 marketId = 1;
            MidasSupplyFuse fuse = new MidasSupplyFuse(marketId);
    
            // Use PlasmaVaultMock so delegatecall from fuse (when used) would have a context,
            // but here we call fuse directly just to trigger the branch in enter().
            // The market configuration is intentionally NOT granting required substrates
            // so that validateMTokenGranted / validateDepositVaultGranted will fail.
    
            // Create dummy token and mToken
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 6);
            MockERC20 mToken = new MockERC20("MToken", "MTK", 18);
    
            // Mint some balance to this test contract so balanceOf(address(this)) > 0
            tokenIn.mint(address(this), 1_000e6);
    
            // Prepare enter data with non‑zero amount to force `if (data_.amount == 0)` to be false
            MidasSupplyFuseEnterData memory data_ = MidasSupplyFuseEnterData({
                mToken: address(mToken),
                tokenIn: address(tokenIn),
                amount: 100e6,
                minMTokenAmountOut: 0,
                depositVault: address(0xDEAD)
            });
    
            // Since no substrates are configured for MARKET_ID, the first validate* call
            // inside enter() will revert with MidasSubstrateLib.MidasFuseUnsupportedSubstrate.
            vm.expectRevert(abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(MidasSubstrateType.M_TOKEN), address(mToken)));

            // This call will:
            // - hit the `else { assert(true); }` branch for `data_.amount == 0` (target branch 76 False)
            // - then attempt validation and revert as expected
            fuse.enter(data_);
        }

    function test_instantWithdraw_entersIfTrueBranchAndRevertsOnUnsupportedSubstrate() public {
            // Arrange: use non‑zero marketId so constructor does not revert
            uint256 marketId = 1;
            MidasSupplyFuse fuse = new MidasSupplyFuse(marketId);
    
            // Prepare params for instantWithdraw:
            // params[0] = amount (non‑zero so _exit() does not early‑return)
            // params[1] = mToken address
            // params[2] = tokenOut address
            // params[3] = instantRedemptionVault address
            // params[4] = minTokenOutAmount
            MockERC20 mToken = new MockERC20("MToken", "MTK", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TKN", 18);
    
            bytes32[] memory params = new bytes32[](5);
            params[0] = bytes32(uint256(100e18));
            params[1] = PlasmaVaultConfigLib.addressToBytes32(address(mToken));
            params[2] = PlasmaVaultConfigLib.addressToBytes32(address(tokenOut));
            params[3] = PlasmaVaultConfigLib.addressToBytes32(address(0xDEAD));
            params[4] = bytes32(uint256(0));
    
            // No substrates are configured in storage for this MARKET_ID, so the first
            // validation in _exit (validateMTokenGranted) will revert with
            // MidasSubstrateLib.MidasFuseUnsupportedSubstrate.
            vm.expectRevert(abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(MidasSubstrateType.M_TOKEN), address(mToken)));

            // Act: call instantWithdraw directly on the fuse. This will:
            // - take the `if (true)` branch in instantWithdraw (opix-target-branch-126-True)
            // - call _exit with catchExceptions_ == true
            // - hit the `else { assert(true); }` branches for both amount and finalAmount checks
            //   prior to substrate validation
            // - revert on unsupported substrate as expected
            fuse.instantWithdraw(params);
        }

    function test_exit_whenAmountZero_entersIfBranchAndReturns() public {
            // Arrange: create fuse with non-zero marketId
            uint256 marketId = 1;
            MidasSupplyFuse fuse = new MidasSupplyFuse(marketId);
    
            // Prepare exit data with amount == 0 to satisfy the opix-target-branch condition
            MidasSupplyFuseExitData memory data_ = MidasSupplyFuseExitData({
                mToken: address(0x1),
                amount: 0,
                minTokenOutAmount: 123,
                tokenOut: address(0x2),
                instantRedemptionVault: address(0x3)
            });
    
            // Act & Assert: exit should early-return and NOT revert, so we just call it
            fuse.exit(data_);
        }
}