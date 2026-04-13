// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/aave_v3/AaveV3BorrowFuse.sol

import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData} from "contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {IPoolAddressesProvider} from "contracts/fuses/aave_v3/ext/IPoolAddressesProvider.sol";
import {IPool} from "contracts/fuses/aave_v3/ext/IPool.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3BorrowFuse} from "contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {FusesLibMock} from "test/connectorsLib/FusesLibMock.sol";
import {AaveV3BorrowFuseExitData} from "contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
contract AaveV3BorrowFuseTest is OlympixUnitTest("AaveV3BorrowFuse") {


    function test_enter_WhenAmountNonZeroAndAssetGranted_BorrowsFromAaveV3() public {
            // setUp: deploy mocks and fuse
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);

            // mock Aave pool and provider
            address provider = address(0x2222);
            address pool = address(0x3333);
            vm.mockCall(
                provider,
                abi.encodeWithSelector(IPoolAddressesProvider.getPool.selector),
                abi.encode(pool)
            );

            uint256 marketId = 1;
            AaveV3BorrowFuse fuse = new AaveV3BorrowFuse(marketId, provider);

            // Use PlasmaVaultMock to delegatecall into fuse so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // grant asset as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = address(underlying);
            vault.grantAssetsToMarket(marketId, assets);

            // mock borrow call on pool targeting vault (delegatecall makes address(this) = vault)
            vm.mockCall(
                pool,
                abi.encodeWithSelector(IPool.borrow.selector, address(underlying), 1e18, 2, 0, address(vault)),
                abi.encode()
            );

            // prepare enter data with non-zero amount so branch `amount == 0` is false
            AaveV3BorrowFuseEnterData memory data = AaveV3BorrowFuseEnterData({asset: address(underlying), amount: 1e18});

            // act: call via vault's fallback which delegatecalls to fuse
            (address assetReturned, uint256 amountReturned) = AaveV3BorrowFuse(address(vault)).enter(data);

            // assert: we hit the non-zero branch and propagate values back
            assertEq(assetReturned, address(underlying), "asset should match input");
            assertEq(amountReturned, 1e18, "amount should match input when non-zero");
        }

    function test_exit_WhenAmountZero_DoesNotTouchPoolAndReturnsZero() public {
            uint256 marketId = 1;
    
            // set up ERC4626 storage decimals to avoid any layout issues
            FusesLibMock fuseStorageInitializer = new FusesLibMock();
            fuseStorageInitializer.setUnderlyingDecimals(18);
    
            // create a dummy ERC20 asset and grant it as allowed substrate for marketId
            MockERC20 asset = new MockERC20("Token","TKN",18);
            PlasmaVaultMock vaultStorage = new PlasmaVaultMock(address(0), address(0));
            address[] memory assets = new address[](1);
            assets[0] = address(asset);
            vaultStorage.grantAssetsToMarket(marketId, assets);
    
            // deploy a dummy addresses provider and mock getPool so we know if it's ever called
            address providerAddr = address(0x1111);
            bytes memory getPoolSelector = abi.encodeWithSelector(IPoolAddressesProvider.getPool.selector);
            // if exit() ever calls getPool when amount == 0, this revert will surface
            vm.mockCallRevert(providerAddr, getPoolSelector, "getPool should not be called");
    
            // deploy fuse under test with non‑zero marketId and non‑zero provider
            AaveV3BorrowFuse fuse = new AaveV3BorrowFuse(marketId, providerAddr);
    
            // call exit with amount = 0 to hit the opix-target-branch-149-True early return
            (address returnedAsset, uint256 returnedAmount) = fuse.exit(
                AaveV3BorrowFuseExitData({asset: address(asset), amount: 0})
            );
    
            // verify early‑return behavior
            assertEq(returnedAsset, address(asset), "asset should be passed through");
            assertEq(returnedAmount, 0, "amount should be zero when input amount is zero");
        }

    function test_exitTransient_TrueBranch_UsesInputsAndWritesOutputs() public {
            uint256 marketId = 1;
            address provider = address(0x2222);

            AaveV3BorrowFuse fuse = new AaveV3BorrowFuse(marketId, provider);

            // Use PlasmaVaultMock for delegatecall so transient + regular storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // mock pool address returned by provider
            address pool = address(0x3333);
            vm.mockCall(
                provider,
                abi.encodeWithSelector(IPoolAddressesProvider.getPool.selector),
                abi.encode(pool)
            );

            // deploy and grant supported asset in vault's storage
            MockERC20 asset = new MockERC20("Token", "TKN", 18);
            address[] memory assets = new address[](1);
            assets[0] = address(asset);
            vault.grantAssetsToMarket(marketId, assets);

            // mock ERC20 approve (forceApprove) on asset for vault
            vm.mockCall(
                address(asset),
                abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))),
                abi.encode(true)
            );

            // mock Aave pool repay to return full amount when called from vault (delegatecall context)
            vm.mockCall(
                pool,
                abi.encodeWithSelector(IPool.repay.selector, address(asset), 1e18, 2, address(vault)),
                abi.encode(1e18)
            );

            // set transient inputs via vault (delegatecall context)
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
            inputs[1] = TypeConversionLib.toBytes32(uint256(1e18));
            vault.setInputs(fuse.VERSION(), inputs);

            // act: call exitTransient via vault's delegatecall wrapper
            vault.exitCompoundV2SupplyTransient();

            // assert: outputs written and decoded correctly
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "two outputs expected");
            address outAsset = PlasmaVaultConfigLib.bytes32ToAddress(outputs[0]);
            uint256 outAmount = TypeConversionLib.toUint256(outputs[1]);
            assertEq(outAsset, address(asset), "returned asset mismatch");
            assertEq(outAmount, 1e18, "returned amount mismatch");
        }
}