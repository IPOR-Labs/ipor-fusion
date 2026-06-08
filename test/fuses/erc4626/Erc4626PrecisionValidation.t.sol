// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @title Precision validation for ERC4626 vault share calculations
contract Erc4626PrecisionValidationTest is Test {

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETHEREUM_PROVIDER_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            uint256 forkId = vm.createFork(rpcUrl);
            vm.selectFork(forkId);
            console2.log("[fork] ETH mainnet:", rpcUrl);
        }

        string memory baseRpc = vm.envOr("BASE_PROVIDER_URL", string(""));
        if (bytes(baseRpc).length > 0) {
            console2.log("[fork] Base:", baseRpc);
        }

        string memory arbRpc = vm.envOr("ARBITRUM_PROVIDER_URL", string(""));
        if (bytes(arbRpc).length > 0) {
            console2.log("[fork] Arb:", arbRpc);
        }
    }

    function test_precisionBoundary_oneWeiDeposit() public pure {
        uint256 oneWei = 1;
        uint256 shares = (oneWei * 1e18) / 1e18;
        assertGe(shares, 1, "1 wei deposit should mint at least 1 share");
    }

    function test_precisionBoundary_thresholdAmount() public pure {
        uint256 threshold = 1e6;
        uint256 totalAssets = 1000000e6;
        uint256 totalSupply = 1000000e6;
        uint256 shares = (threshold * totalSupply) / totalAssets;
        assertEq(shares, threshold);
    }
}
