// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol

import {CompoundV2SupplyFuse, CompoundV2SupplyFuseEnterData} from "contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {CErc20} from "contracts/fuses/compound_v2/ext/CErc20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {CompoundV2SupplyFuse, CompoundV2SupplyFuseExitData} from "contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
contract CompoundV2SupplyFuseTest is OlympixUnitTest("CompoundV2SupplyFuse") {


    function test_enter_zeroAmount_hitsEarlyReturnBranch() public {
            CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
    
            CompoundV2SupplyFuseEnterData memory data_ = CompoundV2SupplyFuseEnterData({
                asset: address(0x1234),
                amount: 0
            });
    
            (address assetRet, address cTokenRet, uint256 amountRet) = fuse.enter(data_);
    
            assertEq(assetRet, address(0x1234));
            assertEq(cTokenRet, address(0));
            assertEq(amountRet, 0);
        }

    function test_enter_WhenAmountNonZero_UsesCTokenAndEmitsEvent() public {
            // Deploy underlying ERC20
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);

            // Deploy fuse with MARKET_ID = 1
            CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Use a mock address as cToken and mock its underlying() call
            address cToken = address(0xC0FFEE);
            vm.mockCall(cToken, abi.encodeWithSelector(CErc20.underlying.selector), abi.encode(address(underlying)));
            vm.mockCall(cToken, abi.encodeWithSelector(CErc20.mint.selector), abi.encode(uint256(0)));

            // Grant cToken as substrate in vault's storage
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = PlasmaVaultConfigLib.addressToBytes32(cToken);
            vault.grantMarketSubstrates(1, substrates);

            // Mint tokens to vault so fuse can use them during delegatecall
            underlying.mint(address(vault), 1_000 ether);

            // Mock approve calls from vault
            vm.mockCall(
                address(underlying),
                abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))),
                abi.encode(true)
            );

            CompoundV2SupplyFuseEnterData memory data_ = CompoundV2SupplyFuseEnterData({asset: address(underlying), amount: 100 ether});

            // Call via vault's fallback
            vault.enterCompoundV2Supply(data_);
        }

    function test_exitTransient_trueBranch_writesOutputs_zeroAmountEarlyReturn() public {
            // Arrange: deploy fuse with MARKET_ID = 1
            CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);

            // Use PlasmaVaultMock for delegatecall so transient storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient storage inputs under key VERSION
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(address(underlying));
            inputs[1] = TypeConversionLib.toBytes32(uint256(0));
            vault.setInputs(fuse.VERSION(), inputs);

            // Act: call exitTransient via vault delegatecall
            vault.exitCompoundV2SupplyTransient();

            // Assert: outputs are written with early-return values from _exit
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 3, "outputs length");

            address outAsset = TypeConversionLib.toAddress(outputs[0]);
            address outCToken = TypeConversionLib.toAddress(outputs[1]);
            uint256 outAmount = TypeConversionLib.toUint256(outputs[2]);

            assertEq(outAsset, address(underlying), "asset output");
            assertEq(outCToken, address(0), "cToken output");
            assertEq(outAmount, 0, "amount output");
        }

    function test_instantWithdraw_hitsBranchAndUsesExitLogic() public {
            uint256 marketId = 1;

            // Deploy fuse
            CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(marketId);

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Configure a dummy cToken as substrate in vault's storage
            address dummyCToken = address(0xC0FFEE);
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = PlasmaVaultConfigLib.addressToBytes32(dummyCToken);
            vault.grantMarketSubstrates(marketId, substrates);

            // Mock CErc20.underlying() on dummyCToken to return the asset
            address asset = address(0xBEEF);
            vm.mockCall(dummyCToken, abi.encodeWithSelector(CErc20.underlying.selector), abi.encode(asset));
            // Mock CErc20.balanceOfUnderlying() to return 0 so _exit early-returns
            vm.mockCall(dummyCToken, abi.encodeWithSelector(CErc20.balanceOfUnderlying.selector, address(vault)), abi.encode(uint256(0)));

            // Encode params: [amount, assetAsBytes32]
            uint256 amount = 123;
            bytes32[] memory params = new bytes32[](2);
            params[0] = TypeConversionLib.toBytes32(amount);
            params[1] = PlasmaVaultConfigLib.addressToBytes32(asset);

            // Call via vault's instantWithdraw
            vault.instantWithdraw(params);
        }

    function test_exit_zeroAmount_hitsEarlyReturnBranch() public {
            // Configure market substrates empty so _getCToken would revert if reached
            bytes32[] memory emptySubstrates = new bytes32[](0);
            PlasmaVaultConfigLib.grantMarketSubstrates(1, emptySubstrates);
    
            // Deploy fuse with MARKET_ID = 1
            CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
    
            // Prepare exit data with zero amount to trigger early return branch
            CompoundV2SupplyFuseExitData memory data_ = CompoundV2SupplyFuseExitData({
                asset: address(0x1234),
                amount: 0
            });
    
            // When amount == 0, _exit should hit the early return branch and not call _getCToken
            (address assetRet, address cTokenRet, uint256 amountRet) = fuse.exit(data_);
    
            assertEq(assetRet, address(0x1234));
            assertEq(cTokenRet, address(0));
            assertEq(amountRet, 0);
        }
}