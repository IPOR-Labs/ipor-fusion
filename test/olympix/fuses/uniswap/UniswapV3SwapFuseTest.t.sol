// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/uniswap/UniswapV3SwapFuse.sol

import {UniswapV3SwapFuse, UniswapV3SwapFuseEnterData} from "contracts/fuses/uniswap/UniswapV3SwapFuse.sol";
import {IUniversalRouter} from "contracts/fuses/uniswap/ext/IUniversalRouter.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract UniswapV3SwapFuseTest is OlympixUnitTest("UniswapV3SwapFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_MultiplePoolsPath_triggersHasMultiplePoolsBranchAndUnsupportedTokenRevert() public {
            // set up three dummy token addresses to construct a multi‑pool path
            address tokenIn = address(0x1001);
            address middle = address(0x1002);
            address tokenOut = address(0x1003);
    
            // Build a multi‑pool path: tokenIn -> middle -> tokenOut (address,fee,address,fee,address)
            bytes memory path = abi.encodePacked(
                tokenIn,
                uint24(3000),
                middle,
                uint24(3000),
                tokenOut
            );
    
            // tokenInAmount > 0 so enter() does not take the early return‑0 branch
            UniswapV3SwapFuseEnterData memory data_ = UniswapV3SwapFuseEnterData({
                tokenInAmount: 1,
                minOutAmount: 1,
                path: path
            });
    
            // Deploy fuse with arbitrary marketId and universal router; external router calls are never reached
            UniswapV3SwapFuse fuse = new UniswapV3SwapFuse(1, address(0xDEAD));
    
            // No substrates are granted in PlasmaVaultConfigLib for these tokens, so the first
            // PlasmaVaultConfigLib.isSubstrateAsAssetGranted() check inside the multiple‑pools
            // branch will fail and revert with UniswapV3SwapFuseUnsupportedToken.
            // This drives execution through the `if (_hasMultiplePools(pathCalldata))` branch.
            vm.expectRevert();
            fuse.enter(data_);
        }

    function test_enter_singlePoolPath_usesElseBranchAndSwaps() public {
            // Deploy mock token
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            address tokenOut = address(0xBEEF);
            uint256 marketId = 1;

            // Deploy the fuse with our marketId and use this test contract as UNIVERSAL_ROUTER
            UniswapV3SwapFuse fuse = new UniswapV3SwapFuse(marketId, address(this));

            // Use PlasmaVaultMock so substrate storage and fuse execution share the same context
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant both tokenIn and tokenOut as substrates in vault's storage
            address[] memory assets = new address[](2);
            assets[0] = address(tokenIn);
            assets[1] = tokenOut;
            vault.grantAssetsToMarket(marketId, assets);

            // Mint tokens to the vault (delegatecall context) so it has balance to swap
            tokenIn.mint(address(vault), 100 ether);

            // Build a single-pool path: tokenIn -> tokenOut with one fee
            bytes memory path = abi.encodePacked(address(tokenIn), bytes3(uint24(3000)), tokenOut);
            assertLt(path.length, 43 + 23, "Path should be treated as single pool");

            UniswapV3SwapFuseEnterData memory data_ = UniswapV3SwapFuseEnterData({
                tokenInAmount: 50 ether,
                minOutAmount: 1,
                path: path
            });

            // Mock the IUniversalRouter.execute() call on the test contract (used as UNIVERSAL_ROUTER)
            vm.mockCall(
                address(this),
                abi.encodeWithSelector(IUniversalRouter.execute.selector),
                abi.encode()
            );

            // Calling enter via vault (delegatecall) should go through the else branch
            // of _hasMultiplePools, decode two tokens, verify substrates, transfer tokenIn
            // to router and call IUniversalRouter.execute.
            UniswapV3SwapFuse(address(vault)).enter(data_);

            // Assert tokens were moved from vault to router (this test contract)
            assertEq(tokenIn.balanceOf(address(vault)), 50 ether, "Vault should keep remaining balance");
            assertEq(tokenIn.balanceOf(address(this)), 50 ether, "Router (test) should receive swapped tokens");
        }

    function test_toAddress_RevertsWhenBytesTooShort() public {
            // Build a path shorter than ADDR_SIZE (20 bytes) so _toAddress must revert with SliceOutOfBounds
            bytes memory shortPath = hex"0102030405"; // 5 bytes only
    
            // Prepare minimal valid data for other fields so enter() progresses to _toAddress
            UniswapV3SwapFuse fuse = new UniswapV3SwapFuse(1, address(this));
    
            UniswapV3SwapFuseEnterData memory data_ = UniswapV3SwapFuseEnterData({
                tokenInAmount: 1,
                minOutAmount: 1,
                path: shortPath
            });
    
            // Expect the custom SliceOutOfBounds error defined in UniswapV3SwapFuse
            vm.expectRevert(UniswapV3SwapFuse.SliceOutOfBounds.selector);
            fuse.enter(data_);
        }
}