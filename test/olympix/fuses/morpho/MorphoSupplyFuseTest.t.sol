// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/morpho/MorphoSupplyFuse.sol

import {MorphoSupplyFuse, MorphoSupplyFuseEnterData} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MorphoSupplyFuse} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoSupplyFuseExitData} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoSupplyFuse, MorphoSupplyFuseExitData} from "contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract MorphoSupplyFuseTest is OlympixUnitTest("MorphoSupplyFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_zeroAmount_hitsEarlyReturnBranch() public {
            // Arrange: create a fuse with a dummy IMorpho instance. The early-return
            // for amount == 0 happens before any MORPHO calls, so this address is never used.
            IMorpho morpho = IMorpho(address(0x1234));
            uint256 marketId = 1;
            MorphoSupplyFuse fuse = new MorphoSupplyFuse(marketId, address(morpho));
    
            // Prepare enter data with amount == 0 to trigger the opix-target-branch-98-True path
            MorphoSupplyFuseEnterData memory data_ = MorphoSupplyFuseEnterData({
                morphoMarketId: bytes32("ANY_MARKET"),
                amount: 0
            });
    
            // Act
            (address asset, bytes32 market, uint256 amount) = fuse.enter(data_);
    
            // Assert: early return should give all zeros
            assertEq(asset, address(0), "asset should be zero when amount == 0");
            assertEq(market, bytes32(0), "market should be zero when amount == 0");
            assertEq(amount, 0, "amount should be zero when amount == 0");
        }

    function test_enter_NonZeroAmount_HitsElseBranchAndRevertsOnUnsupportedMarket() public {
        // set up a dummy Morpho instance and fuse; MARKET_ID is 0 and no substrates are granted,
        // so PlasmaVaultConfigLib.isMarketSubstrateGranted will return false and trigger the revert
        IMorpho morpho = IMorpho(address(0x1234));
        MorphoSupplyFuse fuse = new MorphoSupplyFuse(0, address(morpho));
    
        MorphoSupplyFuseEnterData memory data_ = MorphoSupplyFuseEnterData({
            morphoMarketId: bytes32("UNSUPPORTED_MARKET"),
            amount: 1
        });
    
        // amount != 0 -> first `if (data_.amount == 0)` is false, so the function
        // executes the `else` branch (hitting opix-target-branch-100-...)
        //
        // Since we never configured this market as a granted substrate for MARKET_ID 0,
        // isMarketSubstrateGranted will be false and the call must revert with
        // MorphoSupplyFuseUnsupportedMarket("enter", morphoMarketId).
        bytes memory expectedRevertData = abi.encodeWithSelector(
            MorphoSupplyFuse.MorphoSupplyFuseUnsupportedMarket.selector,
            "enter",
            data_.morphoMarketId
        );
    
        vm.expectRevert(expectedRevertData);
        fuse.enter(data_);
    }

    function test_instantWithdraw_calls_exit_with_catchExceptions_true() public {
        // Arrange: create fuse with dummy Morpho instance
        IMorpho morpho = IMorpho(address(0x1234));
        uint256 marketId = 1;
        MorphoSupplyFuse fuse = new MorphoSupplyFuse(marketId, address(morpho));

        // params[0] = amount (0 for early return in _exit), params[1] = morphoMarketId
        bytes32[] memory params_ = new bytes32[](2);
        params_[0] = bytes32(uint256(0));
        params_[1] = bytes32("ANY_MARKET");

        // Act: this must execute the `if (true)` body in instantWithdraw and
        // therefore call `_exit(..., true)`. With amount=0, _exit returns early.
        fuse.instantWithdraw(params_);

        // Assert: reaching here without revert is enough to prove the branch
        // `if (true) { ... }` in instantWithdraw (opix-target-branch-139-True)
        // has been executed successfully.
    }

    function test_exit_zeroAmount_hitsEarlyReturnBranch_opix_target_branch_152_True() public {
        // Arrange: create fuse with dummy Morpho instance; exit(0) returns before any MORPHO calls
        IMorpho morpho = IMorpho(address(0x1234));
        uint256 marketId = 1;
        MorphoSupplyFuse fuse = new MorphoSupplyFuse(marketId, address(morpho));
    
        // Prepare exit data with amount == 0 to trigger opix-target-branch-152-True path in _exit
        MorphoSupplyFuseExitData memory data_ = MorphoSupplyFuseExitData({
            morphoMarketId: bytes32("ANY_MARKET"),
            amount: 0
        });
    
        // Act
        (address asset, bytes32 market, uint256 amount) = fuse.exit(data_);
    
        // Assert: early return should give all zeros
        assertEq(asset, address(0), "asset should be zero when amount == 0");
        assertEq(market, bytes32(0), "market should be zero when amount == 0");
        assertEq(amount, 0, "amount should be zero when amount == 0");
    }

    function test_exit_nonZeroAmount_hitsElseBranchAndRevertsOnUnsupportedMarket_opix_target_branch_154_False() public {
            // Arrange: create fuse with dummy Morpho instance; _exit is reached via exit(),
            // and the amount check happens before any MORPHO calls, so this address is never used.
            IMorpho morpho = IMorpho(address(0x1234));
            uint256 marketId = 1;
            MorphoSupplyFuse fuse = new MorphoSupplyFuse(marketId, address(morpho));
    
            // amount != 0 -> first `if (data_.amount == 0)` in _exit is false, so the function
            // executes the `else` branch (hitting opix-target-branch-154-False's else path)
            // and then proceeds to the substrate check where it reverts because the market
            // is not granted in PlasmaVaultConfigLib for this MARKET_ID.
            MorphoSupplyFuseExitData memory data_ = MorphoSupplyFuseExitData({
                morphoMarketId: bytes32("UNSUPPORTED_MARKET"),
                amount: 1
            });
    
            bytes memory expectedRevertData = abi.encodeWithSelector(
                MorphoSupplyFuse.MorphoSupplyFuseUnsupportedMarket.selector,
                "exit",
                data_.morphoMarketId
            );
    
            vm.expectRevert(expectedRevertData);
            fuse.exit(data_);
        }

    function test_enterTransient_readsInputsAndRevertsOnUnsupportedMarket_opix_target_branch_233_True() public {
        // Arrange: create fuse with dummy Morpho and set VERSION-based inputs in transient storage
        IMorpho morpho = IMorpho(address(0x1234));
        uint256 marketId = 1;
        MorphoSupplyFuse fuse = new MorphoSupplyFuse(marketId, address(morpho));
        PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

        // Prepare inputs: morphoMarketId and amount (non-zero to avoid early return)
        bytes32 morphoMarketId = bytes32("MARKET_ID_EXAMPLE");
        uint256 amount = 42;

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = morphoMarketId;
        inputs[1] = bytes32(uint256(amount));

        // Write inputs under key VERSION in vault's transient storage
        vault.setInputs(address(fuse), inputs);

        // Expect revert from inner enter() on unsupported market
        bytes memory expectedRevertData = abi.encodeWithSelector(
            MorphoSupplyFuse.MorphoSupplyFuseUnsupportedMarket.selector,
            "enter",
            morphoMarketId
        );

        vm.expectRevert(expectedRevertData);

        // Act: this must execute the `if (true)` body in enterTransient (opix-target-branch-233-True)
        // and then bubble up the unsupported-market revert from enter()
        MorphoSupplyFuse(address(vault)).enterTransient();
    }

    function test_exitTransient_hitsOpixTargetBranch255True() public {
            // Arrange: create fuse with dummy Morpho instance
            IMorpho morpho = IMorpho(address(0x1234));
            uint256 marketId = 1;
            MorphoSupplyFuse fuse = new MorphoSupplyFuse(marketId, address(morpho));
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient storage inputs
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = bytes32("ANY_MARKET"); // morphoMarketId
            inputs[1] = bytes32(uint256(0));    // amount = 0 to trigger early return in _exit

            vault.setInputs(address(fuse), inputs);

            // Act: exitTransient reads inputs and writes zeroed outputs when amount == 0
            MorphoSupplyFuse(address(vault)).exitTransient();

            // Assert: outputs stored under VERSION should be all zeros
            bytes32[] memory outputs = vault.getOutputs(address(fuse));
            assertEq(outputs.length, 3, "outputs length");
            assertEq(outputs[0], bytes32(0), "asset should be zero");
            assertEq(outputs[1], bytes32(0), "market should be zero");
            assertEq(outputs[2], bytes32(0), "amount should be zero");
        }
}