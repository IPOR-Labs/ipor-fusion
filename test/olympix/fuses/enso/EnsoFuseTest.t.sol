// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/enso/EnsoFuse.sol

import {EnsoFuse} from "contracts/fuses/enso/EnsoFuse.sol";
import {EnsoFuseEnterData} from "contracts/fuses/enso/EnsoFuse.sol";
import {EnsoSubstrateLib, EnsoSubstrate} from "contracts/fuses/enso/lib/EnsoSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
contract EnsoFuseTest is OlympixUnitTest("EnsoFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertWhenTokenOutZeroAddress() public {
            // Deploy EnsoFuse with valid constructor params
            uint256 marketId = 1;
            address weth = address(0x1);
            address delegateEnsoShortcuts = address(0x2);
            EnsoFuse ensoFuse = new EnsoFuse(marketId, weth, delegateEnsoShortcuts);
    
            // Prepare enter data with tokenOut set to zero address to trigger the branch
            EnsoFuseEnterData memory data_ = EnsoFuseEnterData({
                tokenOut: address(0),
                amountOut: 0,
                wEthAmount: 0,
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: new bytes32[](0),
                state: new bytes[](0),
                tokensToReturn: new address[](0)
            });
    
            // Expect revert due to invalid tokenOut (opix-target-branch-109-True)
            vm.expectRevert(EnsoFuse.EnsoFuseInvalidTokenOut.selector);
            ensoFuse.enter(data_);
        }

    function test_enter_TokenOutNonZeroHitsElseBranchAndRevertsOnUnsupportedAsset() public {
            // Arrange: deploy EnsoFuse with valid constructor params
            uint256 marketId = 1;
            address weth = address(0x1);
            address delegateEnsoShortcuts = address(0x2);
            EnsoFuse ensoFuse = new EnsoFuse(marketId, weth, delegateEnsoShortcuts);
    
            // Configure storage so that no substrates are granted for this market,
            // which will make _validateEnterSubstrates revert with EnsoFuseUnsupportedAsset
            PlasmaVaultStorageLib.MarketSubstrates storage marketSubstrates = PlasmaVaultStorageLib.getMarketSubstrates();
            PlasmaVaultStorageLib.MarketSubstratesStruct storage ms = marketSubstrates.value[marketId];
            // explicitly clear any existing substrates (defensive, though in a fresh test it's empty)
            uint256 len = ms.substrates.length;
            for (uint256 i; i < len; ++i) {
                ms.substrateAllowances[ms.substrates[i]] = 0;
            }
            delete ms.substrates;
    
            // Prepare enter data with non‑zero tokenOut so the top-level if is false
            // and the function enters the `else` branch (opix-target-branch-111-Else)
            EnsoFuseEnterData memory data_ = EnsoFuseEnterData({
                tokenOut: address(0xAA),
                amountOut: 0,
                wEthAmount: 0,
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: new bytes32[](0),
                state: new bytes[](0),
                tokensToReturn: new address[](0)
            });
    
            // Act & Assert: since tokenOut is non‑zero, we pass the first require
            // and then fail substrate validation with EnsoFuseUnsupportedAsset
            vm.expectRevert(abi.encodeWithSelector(EnsoFuse.EnsoFuseUnsupportedAsset.selector, address(0xAA)));
            ensoFuse.enter(data_);
        }
}