// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/erc20/Erc20BalanceFuse.sol

import {ERC20BalanceFuse} from "contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
contract Erc20BalanceFuseTest is OlympixUnitTest("ERC20BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_returnsZeroWhenNoSubstratesConfigured() public {
            // Deploy dummy ERC4626 to satisfy underlyingAsset() call; use MockERC20 as asset
            MockERC20 underlying = new MockERC20("Underlying", "UND", 18);
            IERC4626 erc4626 = IERC4626(address(underlying));
    
            // Set price oracle in PlasmaVault storage to a mock
            PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 18, address(0));
            PlasmaVaultLib.setPriceOracleMiddleware(address(oracle));
            assertEq(PlasmaVaultLib.getPriceOracleMiddleware(), address(oracle), "oracle set");
    
            // Configure ERC4626Storage so that asset() does not revert when called via this address
            PlasmaVaultStorageLib.getERC4626Storage().asset = address(erc4626);
    
            // Deploy fuse with some non-zero market id
            ERC20BalanceFuse fuse = new ERC20BalanceFuse(1);
    
            // Ensure no substrates are configured for marketId 1, then balanceOf should return 0 and hit len == 0 branch
            uint256 bal = fuse.balanceOf();
            assertEq(bal, 0, "expected zero balance when no substrates configured");
        }
}