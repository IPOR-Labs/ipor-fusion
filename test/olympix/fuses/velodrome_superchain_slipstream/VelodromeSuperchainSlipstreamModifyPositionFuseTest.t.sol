// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockSlipstreamNFPM} from "test/test_helpers/MockSlipstreamNFPM.sol";
import {
    VelodromeSuperchainSlipstreamModifyPositionFuse,
    VelodromeSuperchainSlipstreamModifyPositionFuseEnterData,
    VelodromeSuperchainSlipstreamModifyPositionFuseExitData
} from "contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamModifyPositionFuse.sol";
import {INonfungiblePositionManager} from "contracts/fuses/velodrome_superchain_slipstream/ext/INonfungiblePositionManager.sol";
import {ICLFactory} from "contracts/fuses/velodrome_superchain_slipstream/ext/ICLFactory.sol";
import {VelodromeSuperchainSlipstreamSubstrateLib, VelodromeSuperchainSlipstreamSubstrateType, VelodromeSuperchainSlipstreamSubstrate} from "contracts/fuses/velodrome_superchain_slipstream/VelodromeSuperchainSlipstreamSubstrateLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";

contract VelodromeSuperchainSlipstreamModifyPositionFuseTest is OlympixUnitTest("VelodromeSuperchainSlipstreamModifyPositionFuse") {
    VelodromeSuperchainSlipstreamModifyPositionFuse internal fuse;
    MockSlipstreamNFPM internal nfpm;
    address internal constant FACTORY = address(0xFAC);
    uint256 internal constant MARKET_ID = 99;

    function setUp() public override {
        nfpm = new MockSlipstreamNFPM(FACTORY);
        fuse = new VelodromeSuperchainSlipstreamModifyPositionFuse(MARKET_ID, address(nfpm));
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.NONFUNGIBLE_POSITION_MANAGER(), address(nfpm));
        assertEq(fuse.FACTORY(), FACTORY);
        assertEq(fuse.VERSION(), address(fuse));
    }

    function test_example_constructorRevertsOnZeroNFPM() public {
        vm.expectRevert(VelodromeSuperchainSlipstreamModifyPositionFuse.VelodromeSuperchainSlipstreamModifyPositionFuseInvalidAddress.selector);
        new VelodromeSuperchainSlipstreamModifyPositionFuse(MARKET_ID, address(0));
    }

    function test_example_enterRevertsWhenNFPMHasNoPositions() public {
        VelodromeSuperchainSlipstreamModifyPositionFuseEnterData memory data;
        data.tokenId = 1;
        data.amount0Desired = 100;
        data.deadline = type(uint256).max;
        // mock NFPM has no positions → positions() reverts → _getPositionInfo bubbles
        vm.expectRevert();
        fuse.enter(data);
    }

    function test_example_exitRevertsWhenNFPMHasNoPositions() public {
        VelodromeSuperchainSlipstreamModifyPositionFuseExitData memory data;
        data.tokenId = 1;
        data.liquidity = 100;
        data.deadline = type(uint256).max;
        vm.expectRevert();
        fuse.exit(data);
    }

    function test_enter_RevertsWhenPoolSubstrateNotGranted_opix_target_branch_140_True() public {
            // Arrange
            uint256 tokenId = 1;
            address token0 = address(0xA1);
            address token1 = address(0xB1);
            int24 tickSpacing = 60;
    
            // Prepare fake pool returned by factory
            address pool = address(0xDEADBEEF);
    
            // 1) Mock NFPM.positions to return our token0, token1, tickSpacing
            // Full return tuple:
            // (uint96 nonce, address operator, address token0, address token1,
            //  int24 tickSpacing, int24 tickLower, int24 tickUpper,
            //  uint128 liquidity, uint256 feeGrowthInside0LastX128,
            //  uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1)
            vm.mockCall(
                address(nfpm),
                abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId),
                abi.encode(
                    uint96(0),
                    address(this),
                    token0,
                    token1,
                    tickSpacing,
                    int24(-100),
                    int24(100),
                    uint128(0),
                    uint256(0),
                    uint256(0),
                    uint128(0),
                    uint128(0)
                )
            );
    
            // 2) Mock factory.getPool to return non‑zero pool address
            vm.mockCall(
                FACTORY,
                abi.encodeWithSelector(ICLFactory.getPool.selector, token0 < token1 ? token0 : token1, token0 < token1 ? token1 : token0, tickSpacing),
                abi.encode(pool)
            );
    
            // 3) Ensure pool has code so getPoolAddress does not revert with PoolHasNoCode
            // We deploy a tiny contract to use its code at `pool` via vm.etch
            address codeHolder = address(new MockSlipstreamNFPM(FACTORY));
            bytes memory code = address(codeHolder).code;
            vm.etch(pool, code);
    
            // 4) Ensure substrate is NOT granted so the isMarketSubstrateGranted check returns false.
            // Substrate encoding must match the production code
            VelodromeSuperchainSlipstreamSubstrate memory substrate = VelodromeSuperchainSlipstreamSubstrate({
                substrateType: VelodromeSuperchainSlipstreamSubstrateType.Pool,
                substrateAddress: pool
            });
            bytes32 substrateKey = VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(substrate);
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[MARKET_ID];
            marketSubstrates.substrateAllowances[substrateKey] = 0; // explicitly not granted
    
    //        // Act & Assert: enter must revert with unsupported pool error, hitting the True side of the branch condition
            VelodromeSuperchainSlipstreamModifyPositionFuseEnterData memory data_;
            data_.token0 = token0;
            data_.token1 = token1;
            data_.tokenId = tokenId;
            data_.amount0Desired = 1e18;
            data_.amount1Desired = 1e18;
            data_.amount0Min = 0;
            data_.amount1Min = 0;
            data_.deadline = type(uint256).max;
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    VelodromeSuperchainSlipstreamModifyPositionFuse
                        .VelodromeSuperchainSlipstreamModifyPositionFuseUnsupportedPool
                        .selector,
                    pool
                )
            );
            fuse.enter(data_);
        }
    
}