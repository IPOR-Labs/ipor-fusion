// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/pendle/PendleSwapPTFuse.sol

import {PendleSwapPTFuse} from "contracts/fuses/pendle/PendleSwapPTFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPActionSwapPTV3} from "@pendle/core-v2/contracts/interfaces/IPActionSwapPTV3.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {PendleSwapPTFuse, PendleSwapPTFuseExitData} from "contracts/fuses/pendle/PendleSwapPTFuse.sol";
import {TokenOutput} from "@pendle/core-v2/contracts/interfaces/IPAllActionTypeV3.sol";
import {SwapData, SwapType} from "@pendle/core-v2/contracts/router/swap-aggregator/IPSwapAggregator.sol";
import {PendleSwapPTFuseExitData} from "contracts/fuses/pendle/PendleSwapPTFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract PendleSwapPTFuseTest is OlympixUnitTest("PendleSwapPTFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_exit_revertsOnInvalidMarketId_branchTrue() public {
            // Arrange: create fuse with valid non-zero MARKET_ID and non-zero router
            uint256 marketId = 1;
            IPActionSwapPTV3 dummyRouter = IPActionSwapPTV3(address(0x1234));
            PendleSwapPTFuse fuse = new PendleSwapPTFuse(marketId, address(dummyRouter));
    
            // Use a market address that is not granted as substrate so the if condition is true
            address fakeMarket = address(0x9999);
    
            PendleSwapPTFuseExitData memory data_ = PendleSwapPTFuseExitData({
                market: fakeMarket,
                exactPtIn: 1,
                output: TokenOutput({
                    tokenOut: address(0xDEAD),
                    minTokenOut: 0,
                    tokenRedeemSy: address(0),
                    pendleSwap: address(0),
                    swapData: SwapData({
                        swapType: SwapType(0),
                        extRouter: address(0),
                        extCalldata: "",
                        needScale: false
                    })
                })
            });
    
            // Expect revert from the MARKET_ID substrate validation branch
            vm.expectRevert(PendleSwapPTFuse.PendleSwapPTFuseInvalidMarketId.selector);
    
            // Act: call exit so that the `if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(...))` condition is true
            fuse.exit(data_);
        }

    function test_exitTransient_branchTrue_revertsOnInvalidMarketId() public {
            // Arrange: create fuse with valid non-zero MARKET_ID and non-zero router
            uint256 marketId = 1;
            IPActionSwapPTV3 dummyRouter = IPActionSwapPTV3(address(0x1234));
            PendleSwapPTFuse fuse = new PendleSwapPTFuse(marketId, address(dummyRouter));
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare inputs for exitTransient; use a market that is NOT granted as substrate
            bytes32[] memory inputs = new bytes32[](11);
            inputs[0] = bytes32(uint256(uint160(address(0x9999)))); // market
            inputs[1] = bytes32(uint256(1));                        // exactPtIn
            inputs[2] = bytes32(uint256(uint160(address(0xDEAD)))); // tokenOut
            inputs[3] = bytes32(uint256(0));                        // minTokenOut
            inputs[4] = bytes32(uint256(uint160(address(0))));      // tokenRedeemSy
            inputs[5] = bytes32(uint256(uint160(address(0))));      // pendleSwap
            inputs[6] = bytes32(uint256(0));                        // swapType
            inputs[7] = bytes32(uint256(uint160(address(0))));      // extRouter
            inputs[8] = bytes32(uint256(0));                        // extCalldataLength
            inputs[9] = bytes32(0);                                 // extCalldataFirst32Bytes
            inputs[10] = bytes32(uint256(0));                       // needScale = false

            // Store inputs in vault's transient storage
            vault.setInputs(address(fuse), inputs);

            // Expect revert from the MARKET_ID substrate validation inside exit()
            vm.expectRevert(PendleSwapPTFuse.PendleSwapPTFuseInvalidMarketId.selector);

            // Act: call exitTransient via vault (delegatecall) to share transient storage context
            PendleSwapPTFuse(address(vault)).exitTransient();
        }
}