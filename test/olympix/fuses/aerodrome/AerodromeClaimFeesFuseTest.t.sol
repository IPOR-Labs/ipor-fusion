// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {AerodromeClaimFeesFuse} from "../../../../contracts/fuses/aerodrome/AerodromeClaimFeesFuse.sol";

import {AerodromeClaimFeesFuseEnterData} from "contracts/fuses/aerodrome/AerodromeClaimFeesFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {IPool} from "contracts/fuses/aerodrome/ext/IPool.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";

import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "contracts/fuses/aerodrome/AreodromeLib.sol";
contract AerodromeClaimFeesFuseTest is OlympixUnitTest("AerodromeClaimFeesFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertsOnZeroAddressPool() public {
            // given: fuse with any market id
            AerodromeClaimFeesFuse fuse = new AerodromeClaimFeesFuse(1);
    
            // prepare pools array where first entry is zero to trigger the True branch
            address[] memory pools = new address[](2);
            pools[0] = address(0);
            pools[1] = address(0x1234);
    
            AerodromeClaimFeesFuseEnterData memory data_ = AerodromeClaimFeesFuseEnterData({pools: pools});
    
            // expect custom error AerodromeClaimFeesFuseZeroAddressPool(0)
            vm.expectRevert(
                abi.encodeWithSelector(
                    AerodromeClaimFeesFuse.AerodromeClaimFeesFuseZeroAddressPool.selector,
                    uint256(0)
                )
            );
    
            // when: calling enter should revert due to zero-address pool, thus hitting the
            // opix-target-branch-78-True branch
            fuse.enter(data_);
        }

    function test_enter_NonZeroPoolHitsElseBranchAndRevertsUnsupported() public {
            // given a fuse with arbitrary market id
            uint256 marketId = 1;
            AerodromeClaimFeesFuse fuse = new AerodromeClaimFeesFuse(marketId);
    
            // prepare data with a single non‑zero pool so `poolAddress == address(0)` is false
            address[] memory pools = new address[](1);
            address pool = address(0x1234);
            pools[0] = pool;
    
            AerodromeClaimFeesFuseEnterData memory data_ = AerodromeClaimFeesFuseEnterData({pools: pools});
    
            // PlasmaVaultConfigLib.isMarketSubstrateGranted will be false by default, so we expect
            // AerodromeClaimFeesFuseUnsupportedPool("enter", pool) revert while still
            // having taken the non‑zero ("else") branch of the zero‑address check.
            vm.expectRevert(
                abi.encodeWithSelector(
                    AerodromeClaimFeesFuse.AerodromeClaimFeesFuseUnsupportedPool.selector,
                    "enter",
                    pool
                )
            );
    
            fuse.enter(data_);
        }

    function test_enterTransient_HitsTrueBranchAndPropagatesRevert() public {
            // given: deploy fuse and mock vault that will act as delegatecall context
            uint256 marketId = 1;
            AerodromeClaimFeesFuse fuse = new AerodromeClaimFeesFuse(marketId);
            PlasmaVaultMock plasmaVaultMock = new PlasmaVaultMock(address(fuse), address(0));
    
            // prepare transient storage inputs under VERSION key in vault context
            // VERSION is fuse address, so use that as account key
            address version = address(fuse);
    
            // inputs layout:
            // inputs[0] = poolsLength (=1)
            // inputs[1] = pool address (non‑zero, but not granted as substrate)
            address pool = address(0x1234);
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(uint256(1));
            inputs[1] = TypeConversionLib.toBytes32(pool);
    
            // set inputs in transient storage in vault context (delegatecall)
            bytes memory setInputsCalldata = abi.encodeWithSignature("setInputs(address,bytes32[])", version, inputs);
            plasmaVaultMock.execute(address(plasmaVaultMock), setInputsCalldata);
    
            // expect revert from unsupported pool inside enter(), propagated through enterTransient()
            vm.expectRevert(
                abi.encodeWithSelector(
                    AerodromeClaimFeesFuse.AerodromeClaimFeesFuseUnsupportedPool.selector,
                    "enter",
                    pool
                )
            );
    
            // when: call enterTransient via delegatecall on vault so that TransientStorageLib
            // reads the previously stored inputs and hits the true branch guard
            bytes memory enterTransientCalldata = abi.encodeWithSignature("enterTransient()");
            plasmaVaultMock.execute(address(fuse), enterTransientCalldata);
        }

    function test_enter_SupportedPool_HitsIsMarketSubstrateGrantedElseBranch() public {
            uint256 marketId = 1;
            AerodromeClaimFeesFuse fuse = new AerodromeClaimFeesFuse(marketId);
            PlasmaVaultMock plasmaVaultMock = new PlasmaVaultMock(address(fuse), address(0));
    
            // prepare a single non-zero pool address
            address pool = address(0x1234);
    
            // grant this pool as a substrate for the given market so that
            // PlasmaVaultConfigLib.isMarketSubstrateGranted(...) returns true
            AerodromeSubstrate memory substrate = AerodromeSubstrate({
                substrateType: AerodromeSubstrateType.Pool,
                substrateAddress: pool
            });
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = AerodromeSubstrateLib.substrateToBytes32(substrate);
            plasmaVaultMock.grantMarketSubstrates(marketId, substrates);
    
            // stub claimFees on pool so external call succeeds inside enter()
            vm.mockCall(
                pool,
                abi.encodeWithSelector(IPool.claimFees.selector),
                abi.encode(uint256(1), uint256(2))
            );
    
            // when: call enter via delegatecall context of PlasmaVaultMock so that
            // the storage used by PlasmaVaultConfigLib matches where we configured substrates
            address[] memory pools = new address[](1);
            pools[0] = pool;
            AerodromeClaimFeesFuseEnterData memory data_ = AerodromeClaimFeesFuseEnterData({pools: pools});
    
            bytes memory callData = abi.encodeWithSelector(AerodromeClaimFeesFuse.enter.selector, data_);
            plasmaVaultMock.execute(address(fuse), callData);
        }
}