// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/odos/OdosSwapperFuse.sol

import {OdosSwapperFuse, OdosSwapperEnterData} from "contracts/fuses/odos/OdosSwapperFuse.sol";
import {OdosSwapExecutor} from "contracts/fuses/odos/OdosSwapExecutor.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract OdosSwapperFuseTest is OlympixUnitTest("OdosSwapperFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertWhenTokenInIsZeroAddress() public {
            // Deploy fuse with valid marketId
            OdosSwapperFuse fuse = new OdosSwapperFuse(1);
    
            // Prepare dummy tokenOut and environment so that only the first require fails
            MockERC20 tokenOut = new MockERC20("TokenOut", "TO", 18);
    
            // Set a non-zero price oracle middleware address so _validateUsdSlippage won't be reached
            // (we will revert earlier on tokenIn == address(0))
            PlasmaVaultLib.setPriceOracleMiddleware(address(0x1234));
    
            // Configure market substrates so that _isTokenGranted would return true if reached
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = bytes32(uint256(uint160(address(tokenOut))));
            PlasmaVaultStorageLib.getMarketSubstrates().value[1].substrates = substrates;
            PlasmaVaultStorageLib.getMarketSubstrates().value[1].substrateAllowances[substrates[0]] = 1;
    
            // Build enter data with tokenIn = address(0) to hit the opix-target-branch-130-True branch
            OdosSwapperEnterData memory data_ = OdosSwapperEnterData({
                tokenIn: address(0),
                tokenOut: address(tokenOut),
                amountIn: 1e18,
                minAmountOut: 0,
                swapCallData: ""
            });
    
            vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, address(0)));
            fuse.enter(data_);
        }

    function test_enter_HitsTokenInNotZeroElseBranch() public {
            // Deploy fuse with valid marketId
            OdosSwapperFuse fuse = new OdosSwapperFuse(1);
    
            // Prepare enter data with non-zero tokenIn so the first if condition is false
            // and the opix-target-branch-132-YOUR-TEST-SHOULD-ENTER-THIS-ELSE-BRANCH is taken
            OdosSwapperEnterData memory data_ = OdosSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x2),
                amountIn: 0,
                minAmountOut: 0,
                swapCallData: bytes("")
            });
    
            // We don't care about the exact revert reason; we only need execution
            // to pass the first `if (data_.tokenIn == address(0))` and enter its else-branch
            vm.expectRevert();
            fuse.enter(data_);
        }

    function test_enter_RevertWhenTokenOutIsZeroAddress() public {
            // Deploy fuse with valid marketId
            OdosSwapperFuse fuse = new OdosSwapperFuse(1);
    
            // Prepare dummy tokenIn so that the first require passes
            MockERC20 tokenIn = new MockERC20("TokenIn", "TI", 18);
    
            // Build enter data with tokenOut = address(0) to hit opix-target-branch-135-True
            OdosSwapperEnterData memory data_ = OdosSwapperEnterData({
                tokenIn: address(tokenIn),
                tokenOut: address(0),
                amountIn: 1e18,
                minAmountOut: 0,
                swapCallData: ""
            });
    
            vm.expectRevert(abi.encodeWithSelector(OdosSwapperFuse.OdosSwapperFuseUnsupportedAsset.selector, address(0)));
            fuse.enter(data_);
        }
}