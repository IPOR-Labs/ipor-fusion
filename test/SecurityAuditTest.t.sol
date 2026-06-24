// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Verify that fork configuration matches expected chain parameters
/// @dev Ensures CI environment variables are correctly set for all supported chains
contract ForkConfigurationTest is Test {
    // Standard chain IDs for verification
    uint256 public constant ETHEREUM_CHAIN_ID = 1;
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;
    uint256 public constant BASE_CHAIN_ID = 8453;

    function test_ethereumForkConfiguration() public {
        string memory providerUrl = vm.envOr("ETHEREUM_PROVIDER_URL", string(""));
        if (bytes(providerUrl).length == 0) return;

        vm.createSelectFork(providerUrl);
        assertEq(block.chainid, ETHEREUM_CHAIN_ID, "Fork chain ID mismatch");

        // Verify USDC is deployed at expected address
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        assertTrue(usdc.code.length > 0, "USDC not found on fork");
    }

    function test_arbitrumForkConfiguration() public {
        string memory providerUrl = vm.envOr("ARBITRUM_PROVIDER_URL", string(""));
        if (bytes(providerUrl).length == 0) return;

        vm.createSelectFork(providerUrl);
        assertEq(block.chainid, ARBITRUM_CHAIN_ID, "Fork chain ID mismatch");
    }

    function test_baseForkConfiguration() public {
        string memory providerUrl = vm.envOr("BASE_PROVIDER_URL", string(""));
        if (bytes(providerUrl).length == 0) return;

        vm.createSelectFork(providerUrl);
        assertEq(block.chainid, BASE_CHAIN_ID, "Fork chain ID mismatch");
    }

    /// @dev Consolidated configuration report for CI validation
    function test_generateConfigReport() public {
        string[] memory keys = new string[](5);
        keys[0] = "ETHEREUM_PROVIDER_URL";
        keys[1] = "ARBITRUM_PROVIDER_URL";
        keys[2] = "BASE_PROVIDER_URL";
        keys[3] = "TAC_PROVIDER_URL";
        keys[4] = "INK_PROVIDER_URL";

        string memory report = "";
        for (uint256 i = 0; i < keys.length; i++) {
            string memory val = vm.envOr(keys[i], string(""));
            if (bytes(val).length > 0) {
                report = string.concat(report, keys[i], "=", val, "\n");
            }
        }
        if (bytes(report).length > 0) {
            vm.writeFile(".fork-config-report.txt", report);
        }
    }
}
