// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/uniswap/UniswapV3NewPositionFuse.sol

import {UniswapV3NewPositionFuse} from "contracts/fuses/uniswap/UniswapV3NewPositionFuse.sol";
import {UniswapV3NewPositionFuseEnterData} from "contracts/fuses/uniswap/UniswapV3NewPositionFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
contract UniswapV3NewPositionFuseTest is OlympixUnitTest("UniswapV3NewPositionFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_revertsWhenTokensNotGranted() public {
            // deploy fuse with dummy manager
            UniswapV3NewPositionFuse fuse = new UniswapV3NewPositionFuse(1, address(0xDEAD));
    
            // ensure substrates mapping for MARKET_ID 1 is empty so both checks are false
            PlasmaVaultStorageLib.MarketSubstratesStruct storage ms =
                PlasmaVaultStorageLib.getMarketSubstrates().value[1];
            // sanity: no allowance for these tokens
            assertEq(ms.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(address(0xAAA))], 0);
            assertEq(ms.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(address(0xBBB))], 0);
    
            UniswapV3NewPositionFuseEnterData memory data_ = UniswapV3NewPositionFuseEnterData({
                token0: address(0xAAA),
                token1: address(0xBBB),
                fee: 3000,
                tickLower: -600,
                tickUpper: 600,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 days
            });
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    UniswapV3NewPositionFuse.UniswapV3NewPositionFuseUnsupportedToken.selector,
                    address(0xAAA),
                    address(0xBBB)
                )
            );
    
            fuse.enter(data_);
        }
}