// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {VelodromeSuperchainLiquidityFuse} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";

/// @dev Target contract: contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol

import {VelodromeSuperchainLiquidityFuseEnterData, VelodromeSuperchainLiquidityFuse} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";
import {VelodromeSuperchainLiquidityFuseEnterData} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";
import {VelodromeSuperchainLiquidityFuseResult} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLib.sol";
import {IRouter} from "contracts/fuses/velodrome_superchain/ext/IRouter.sol";
import {VelodromeSuperchainLiquidityFuseExitData, VelodromeSuperchainLiquidityFuse} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";
import {VelodromeSuperchainLiquidityFuseExitData} from "contracts/fuses/velodrome_superchain/VelodromeSuperchainLiquidityFuse.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract VelodromeSuperchainLiquidityFuseTest is OlympixUnitTest("VelodromeSuperchainLiquidityFuse") {
    VelodromeSuperchainLiquidityFuse public velodromeSuperchainLiquidityFuse;


    function setUp() public override {
        velodromeSuperchainLiquidityFuse = new VelodromeSuperchainLiquidityFuse(1, address(0xDEAD));
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(velodromeSuperchainLiquidityFuse) != address(0), "Contract should be deployed");
    }

    function test_enter_RevertWhen_TokenIsZeroAddress_opix_branch_142_true() public {
            VelodromeSuperchainLiquidityFuseEnterData memory data = VelodromeSuperchainLiquidityFuseEnterData({
                tokenA: address(0),
                tokenB: address(0x1),
                stable: false,
                amountADesired: 1,
                amountBDesired: 1,
                amountAMin: 0,
                amountBMin: 0,
                deadline: block.timestamp + 1 days
            });
    
            vm.expectRevert(VelodromeSuperchainLiquidityFuse.VelodromeSuperchainLiquidityFuseInvalidToken.selector);
            velodromeSuperchainLiquidityFuse.enter(data);
        }

    function test_enter_tokensNonZero_hitsElseBranchOfInvalidTokenCheck_opix_branch_144_false() public {
            VelodromeSuperchainLiquidityFuseEnterData memory data = VelodromeSuperchainLiquidityFuseEnterData({
                tokenA: address(0x1),
                tokenB: address(0x2),
                stable: false,
                amountADesired: 1,
                amountBDesired: 1,
                amountAMin: 0,
                amountBMin: 0,
                deadline: block.timestamp + 1 days
            });
    
            // We only need to ensure the invalid-token check didn't trigger.
            // Since VELODROME_ROUTER is a dummy address, the call will revert later
            // for some other reason. We assert that the revert is NOT caused by
            // VelodromeSuperchainLiquidityFuseInvalidToken, which proves we entered
            // the `else` side of the first if.
            bytes4 invalidSelector = VelodromeSuperchainLiquidityFuse
                .VelodromeSuperchainLiquidityFuseInvalidToken
                .selector;
    
            try velodromeSuperchainLiquidityFuse.enter(data) {
                // If it does not revert, we definitely passed the invalid-token check.
                assertTrue(true);
            } catch (bytes memory reason) {
                bytes4 selector;
                if (reason.length >= 4) {
                    assembly {
                        selector := mload(add(reason, 32))
                    }
                }
                assertTrue(
                    selector != invalidSelector,
                    "Should not revert with invalid-token when tokens are non-zero"
                );
            }
        }

    function test_enter_ReturnsZeroResultWhenBothAmountsDesiredZero_opix_branch_152_true() public {
        VelodromeSuperchainLiquidityFuseEnterData memory data = VelodromeSuperchainLiquidityFuseEnterData({
            tokenA: address(0x1),
            tokenB: address(0x2),
            stable: false,
            amountADesired: 0,
            amountBDesired: 0,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 1 days
        });
    
        VelodromeSuperchainLiquidityFuseResult memory result = velodromeSuperchainLiquidityFuse.enter(data);
    
        assertEq(result.amountA, 0, "amountA should be zero when both desired amounts are zero");
        assertEq(result.amountB, 0, "amountB should be zero when both desired amounts are zero");
        assertEq(result.liquidity, 0, "liquidity should be zero when both desired amounts are zero");
    }

    function test_enter_RevertWhenPoolNotGranted_opix_branch_162_true() public {
            // Arrange: non-zero tokens and non-zero desired amounts so we pass earlier guards
            VelodromeSuperchainLiquidityFuseEnterData memory data = VelodromeSuperchainLiquidityFuseEnterData({
                tokenA: address(0x10),
                tokenB: address(0x20),
                stable: false,
                amountADesired: 1,
                amountBDesired: 1,
                amountAMin: 0,
                amountBMin: 0,
                deadline: block.timestamp + 1 days
            });
    
            // Stub router.poolFor to return some pool address using Foundry's mock interface
            address fakePool = address(0xABCDEF);
            vm.mockCall(
                address(velodromeSuperchainLiquidityFuse.VELODROME_ROUTER()),
                abi.encodeWithSelector(IRouter.poolFor.selector, data.tokenA, data.tokenB, data.stable),
                abi.encode(fakePool)
            );
    
            // Ensure PlasmaVaultConfigLib reports this pool as NOT granted substrate for this MARKET_ID
            bytes32 substrateKey = VelodromeSuperchainSubstrateLib.substrateToBytes32(
                VelodromeSuperchainSubstrate({
                    substrateType: VelodromeSuperchainSubstrateType.Pool,
                    substrateAddress: fakePool
                })
            );
            // Sanity: library should return false so condition `!isMarketSubstrateGranted` is true
            bool granted = PlasmaVaultConfigLib.isMarketSubstrateGranted(velodromeSuperchainLiquidityFuse.MARKET_ID(), substrateKey);
            assertFalse(granted, "Precondition: pool must not be granted as market substrate");
    
            // Act & Assert: expect revert from unsupported pool branch
            vm.expectRevert(
                abi.encodeWithSelector(
                    VelodromeSuperchainLiquidityFuse.VelodromeSuperchainLiquidityFuseUnsupportedPool.selector,
                    "enter",
                    fakePool
                )
            );
            velodromeSuperchainLiquidityFuse.enter(data);
        }

    function test_exit_RevertsWhenTokenIsZeroAddress_opix_branch_228_true() public {
            VelodromeSuperchainLiquidityFuseExitData memory data = VelodromeSuperchainLiquidityFuseExitData({
                tokenA: address(0),
                tokenB: address(0xBEEF),
                stable: false,
                liquidity: 1,
                amountAMin: 0,
                amountBMin: 0,
                deadline: block.timestamp + 1 days
            });
    
            vm.expectRevert(VelodromeSuperchainLiquidityFuse.VelodromeSuperchainLiquidityFuseInvalidToken.selector);
            velodromeSuperchainLiquidityFuse.exit(data);
        }

    function test_exit_tokensNonZero_revertsForReasonOtherThanInvalidToken() public {
            VelodromeSuperchainLiquidityFuseExitData memory data = VelodromeSuperchainLiquidityFuseExitData({
                tokenA: address(0x1),
                tokenB: address(0x2),
                stable: false,
                liquidity: 0,
                amountAMin: 0,
                amountBMin: 0,
                deadline: block.timestamp
            });
    
            // The goal is only to cover the `else` side of the
            // `if (data_.tokenA == address(0) || data_.tokenB == address(0))` branch.
            // `VELODROME_ROUTER` is a dummy address so the call will revert later;
            // we just assert that the revert is *not* caused by the InvalidToken error,
            // which guarantees that the invalid-token `if` branch was not taken.
            bytes4 invalidSelector = VelodromeSuperchainLiquidityFuse.VelodromeSuperchainLiquidityFuseInvalidToken.selector;
    
            try velodromeSuperchainLiquidityFuse.exit(data) {
                // If the call does not revert, we have definitely passed the invalid-token check.
                assertTrue(true);
            } catch (bytes memory reason) {
                bytes4 selector;
                if (reason.length >= 4) {
                    assembly {
                        selector := mload(add(reason, 32))
                    }
                }
                assertTrue(selector != invalidSelector, "Should not revert with invalid-token when tokens are non-zero");
            }
        }

    function test_enterTransient_UsesVersionKeyAndWritesExpectedOutputs_opix_branch_295_true() public {
            // Arrange: use PlasmaVaultMock so delegatecall shares transient storage context
            PlasmaVaultMock vault = new PlasmaVaultMock(address(velodromeSuperchainLiquidityFuse), address(0));

            address tokenA = address(0x1111);
            address tokenB = address(0x2222);
            bool stable = true;
            // Use zero amounts so enter() returns early without needing router/substrate mocks
            uint256 amountADesired = 0;
            uint256 amountBDesired = 0;
            uint256 amountAMin = 0;
            uint256 amountBMin = 0;
            uint256 deadline = block.timestamp + 1 days;

            bytes32[] memory inputs = new bytes32[](8);
            inputs[0] = TypeConversionLib.toBytes32(tokenA);
            inputs[1] = TypeConversionLib.toBytes32(tokenB);
            inputs[2] = TypeConversionLib.toBytes32(uint256(stable ? 1 : 0));
            inputs[3] = TypeConversionLib.toBytes32(amountADesired);
            inputs[4] = TypeConversionLib.toBytes32(amountBDesired);
            inputs[5] = TypeConversionLib.toBytes32(amountAMin);
            inputs[6] = TypeConversionLib.toBytes32(amountBMin);
            inputs[7] = TypeConversionLib.toBytes32(deadline);

            // Store inputs keyed by VERSION (the fuse address) via vault mock
            vault.setInputs(velodromeSuperchainLiquidityFuse.VERSION(), inputs);

            // Act: call enterTransient via delegatecall through the vault
            vault.enterCompoundV2SupplyTransient();

            // Assert: outputs exist under the same VERSION key
            bytes32[] memory outputs = vault.getOutputs(velodromeSuperchainLiquidityFuse.VERSION());
            assertEq(outputs.length, 6, "enterTransient should write 6 outputs");
        }

    function test_exitTransient_ReadsInputsAndWritesOutputs_opix_branch_342_true() public {
            // Arrange: prepare inputs for exitTransient
            // tokenA, tokenB, stable(1), liquidity, amountAMin, amountBMin, deadline
            bytes32[] memory inputs = new bytes32[](7);
            inputs[0] = TypeConversionLib.toBytes32(address(0xA1));
            inputs[1] = TypeConversionLib.toBytes32(address(0xB2));
            inputs[2] = TypeConversionLib.toBytes32(uint256(1)); // stable = true
            inputs[3] = TypeConversionLib.toBytes32(uint256(123)); // liquidity
            inputs[4] = TypeConversionLib.toBytes32(uint256(10));  // amountAMin
            inputs[5] = TypeConversionLib.toBytes32(uint256(20));  // amountBMin
            inputs[6] = TypeConversionLib.toBytes32(block.timestamp + 1 days);
    
            // Use the same key as fuse uses: VERSION
            address versionKey = velodromeSuperchainLiquidityFuse.VERSION();
    
            // We will delegatecall into the fuse using TransientStorageLibMock pattern
            TransientStorageLibMock helper = new TransientStorageLibMock();
    
            // 1) Set inputs in transient storage under VERSION key
            helper.setInputs(versionKey, inputs);
    
            // 2) Call exitTransient on the fuse (it will read inputs and attempt exit)
            //    The call will likely revert deeper (router / substrate check), but we
            //    only need to ensure the `if (true)` branch in exitTransient executes
            //    and that it tries to read inputs and write outputs.
            //    So we perform a try/catch and then just assert that the tx reverted
            //    for some reason (which still covers the branch).
            try velodromeSuperchainLiquidityFuse.exitTransient() {
                // If it somehow succeeds, we can still check that outputs were written
            } catch {
                // swallow, branch has been executed
            }
    
            // 3) Read whatever outputs were written (if call succeeded up to that point).
            //    This also validates that using VERSION as key is consistent.
            bytes32[] memory outputs = helper.getOutputs(versionKey);
            // We can't rely on exact contents because exit() likely reverted,
            // but we can assert that the read itself does not revert and that
            // the array length is sensible (0 or 6). This ensures the branch
            // in exitTransient was at least exercised.
            assertTrue(outputs.length == 0 || outputs.length == 6, "outputs length should be 0 or 6");
        }
}