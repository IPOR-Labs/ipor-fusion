// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";

/// @dev Target contract: contracts/fuses/chains/ethereum/spark/SparkBalanceFuse.sol

import {SparkBalanceFuse} from "contracts/fuses/chains/ethereum/spark/SparkBalanceFuse.sol";

import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {ISavingsDai} from "contracts/fuses/chains/ethereum/spark/ext/ISavingsDai.sol";
contract SparkBalanceFuseTest is OlympixUnitTest("SparkBalanceFuse") {
    SparkBalanceFuse public sparkBalanceFuse;

    function setUp() public override {
        sparkBalanceFuse = new SparkBalanceFuse(1);
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(sparkBalanceFuse) != address(0), "Contract should be deployed");
    }

    function test_example_marketId() public view {
        assertEq(sparkBalanceFuse.MARKET_ID(), 1);
    }

    function test_example_revertsOnZeroMarketId() public {
        vm.expectRevert(SparkBalanceFuse.SparkBalanceFuseInvalidMarketId.selector);
        new SparkBalanceFuse(0);
    }

    function test_balanceOf_ReturnsZeroWhenSdaiBalanceIsZero() public {
            // SDAI is hardcoded at 0x83F2...BEeA which has no code in unit tests.
            // Etch minimal bytecode and mock balanceOf to return 0 so _convertToUsd
            // takes its `amount == 0` early-return branch and returns 0.
            address sdai = sparkBalanceFuse.SDAI();
            vm.etch(sdai, hex"00");
            vm.mockCall(sdai, abi.encodeWithSelector(ISavingsDai.balanceOf.selector), abi.encode(uint256(0)));

            uint256 usdBalance = sparkBalanceFuse.balanceOf();
            assertEq(usdBalance, 0, "balanceOf should return 0 when sDAI balance is zero");
        }
}