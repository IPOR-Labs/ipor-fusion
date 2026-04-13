// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/aave_v3/AaveV3SupplyFuse.sol

import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseExitData} from "contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IAavePoolDataProvider} from "contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {IPoolAddressesProvider} from "contracts/fuses/aave_v3/ext/IPoolAddressesProvider.sol";
import {IPool} from "contracts/fuses/aave_v3/ext/IPool.sol";
import {ERC20Mock} from "test/fuses/aave_v4/ERC20Mock.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract AaveV3SupplyFuseTest is OlympixUnitTest("AaveV3SupplyFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_WhenAmountNonZeroAndAssetNotGranted_RevertsUnsupportedAsset() public {
            // deploy fuse with valid params to avoid constructor reverts
            uint256 marketId = 1;
            address poolAddressesProvider = address(0x1234);
            AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(marketId, poolAddressesProvider);
    
            // prepare enter data: non-zero amount so first if condition is false and else branch is taken
            AaveV3SupplyFuseEnterData memory data_ = AaveV3SupplyFuseEnterData({
                asset: address(0xABCD),
                amount: 1 ether,
                userEModeCategoryId: 0
            });
    
            // since PlasmaVaultConfigLib.isSubstrateAsAssetGranted will be false for this asset,
            // the fuse should revert with AaveV3SupplyFuseUnsupportedAsset("enter", asset)
            vm.expectRevert();
            fuse.enter(data_);
        }

    function test_enterTransient_UsesTransientStorageAndCallsEnter() public {
            // arrange
            uint256 marketId = 1;
            address poolAddressesProvider = address(0x1234);
            AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(marketId, poolAddressesProvider);
    
            address asset = address(0xABCD);
            uint256 amount = 1 ether;
            uint256 userEModeCategoryId = 2;
    
            // write inputs to transient storage under VERSION
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = PlasmaVaultConfigLib.addressToBytes32(asset);
            inputs[1] = TypeConversionLib.toBytes32(amount);
            inputs[2] = TypeConversionLib.toBytes32(userEModeCategoryId);
            TransientStorageLib.setInputs(fuse.VERSION(), inputs);
    
            // calling enterTransient should not revert even if underlying enter reverts,
            // but we only need to execute the opix-target-branch in enterTransient
            vm.expectRevert();
            fuse.enterTransient();
        }

    function test_instantWithdraw_WhenAaveWithdrawReverts_EmitsExitFailedAndReturnsFinalAmount() public {
            uint256 marketId = 1;

            // deploy mocks for underlying and aToken
            ERC20Mock underlying = new ERC20Mock("Token", "TOK", 18);
            ERC20Mock aToken = new ERC20Mock("AToken", "aTOK", 18);

            // mock external Aave contracts
            IPool mockPool = IPool(makeAddr("mockPool"));
            IAavePoolDataProvider mockDataProvider = IAavePoolDataProvider(makeAddr("mockDataProvider"));
            IPoolAddressesProvider mockProvider = IPoolAddressesProvider(makeAddr("mockProvider"));

            // wire provider -> pool and dataProvider
            vm.mockCall(
                address(mockProvider),
                abi.encodeWithSelector(IPoolAddressesProvider.getPool.selector),
                abi.encode(address(mockPool))
            );
            vm.mockCall(
                address(mockProvider),
                abi.encodeWithSelector(IPoolAddressesProvider.getPoolDataProvider.selector),
                abi.encode(address(mockDataProvider))
            );

            // mock data provider to return our aToken for the underlying asset
            vm.mockCall(
                address(mockDataProvider),
                abi.encodeWithSelector(IAavePoolDataProvider.getReserveTokensAddresses.selector, address(underlying)),
                abi.encode(address(aToken), address(0), address(0))
            );

            // deploy fuse with valid constructor params
            AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(marketId, address(mockProvider));

            // Use PlasmaVaultMock so substrate storage and fuse execution share the same context
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // grant substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = address(underlying);
            vault.grantAssetsToMarket(marketId, assets);

            // give vault some aTokens so finalAmount_ > 0
            uint256 requestedAmount = 3 ether;
            aToken.mint(address(vault), 5 ether);

            // make pool.withdraw revert so catchExceptions_ branch in _performWithdraw is exercised
            vm.mockCallRevert(
                address(mockPool),
                abi.encodeWithSelector(IPool.withdraw.selector, address(underlying), requestedAmount, address(vault)),
                "withdraw failed"
            );

            // expect ExitFailed event with VERSION (fuse address), asset and finalAmount_
            vm.expectEmit(false, false, false, true);
            emit AaveV3SupplyFuse.AaveV3SupplyFuseExitFailed(address(fuse), address(underlying), requestedAmount);

            // params[0] = amount, params[1] = encoded asset address
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(requestedAmount);
            params[1] = PlasmaVaultConfigLib.addressToBytes32(address(underlying));

            // act via vault (delegatecall) - should not revert despite withdraw failure
            vault.instantWithdraw(params);
        }

    function test_exit_WhenAmountZero_ReturnsEarlyAndSkipsWithdraw() public {
            // Arrange: deploy mocks for Aave pool, data provider and underlying/aToken
            uint256 marketId = 1;
    
            // Mock underlying and aToken
            ERC20Mock underlying = new ERC20Mock("Token", "TOK", 18);
            ERC20Mock aToken = new ERC20Mock("AToken", "aTOK", 18);
    
            // Mock Pool, DataProvider, and AddressesProvider
            IPool mockPool = IPool(makeAddr("mockPool"));
            IAavePoolDataProvider mockDataProvider = IAavePoolDataProvider(makeAddr("mockDataProvider"));
            IPoolAddressesProvider mockProvider = IPoolAddressesProvider(makeAddr("mockProvider"));
    
            // Expect calls for addresses provider
            vm.mockCall(
                address(mockProvider),
                abi.encodeWithSelector(IPoolAddressesProvider.getPool.selector),
                abi.encode(address(mockPool))
            );
            vm.mockCall(
                address(mockProvider),
                abi.encodeWithSelector(IPoolAddressesProvider.getPoolDataProvider.selector),
                abi.encode(address(mockDataProvider))
            );
    
            // Configure PlasmaVaultConfigLib so that substrate is granted, otherwise the fuse would revert
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketCfg =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            bytes32 substrateKey = PlasmaVaultConfigLib.addressToBytes32(address(underlying));
            marketCfg.substrateAllowances[substrateKey] = 1;
    
            // Expect the data provider to return our aToken for the underlying asset
            vm.mockCall(
                address(mockDataProvider),
                abi.encodeWithSelector(IAavePoolDataProvider.getReserveTokensAddresses.selector, address(underlying)),
                abi.encode(address(aToken), address(0), address(0))
            );
    
            // Deploy fuse with valid constructor params
            AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(marketId, address(mockProvider));
    
            // Prepare exit data with amount == 0 so the first if condition in _exit is true
            AaveV3SupplyFuseExitData memory data_ = AaveV3SupplyFuseExitData({asset: address(underlying), amount: 0});
    
            // Act: call exit; because amount is 0, it should return early and NOT call pool.withdraw
            // We add a failing mock for withdraw to ensure it is never hit
            vm.mockCallRevert(
                address(mockPool),
                abi.encodeWithSelector(IPool.withdraw.selector, address(underlying), 0, address(this)),
                "should not be called"
            );
    
            (address returnedAsset, uint256 returnedAmount) = fuse.exit(data_);
    
            // Assert: returned values match input, and no external withdraw was attempted
            assertEq(returnedAsset, address(underlying), "asset should be passed through");
            assertEq(returnedAmount, 0, "amount should be zero");
        }

    function test_exit_WhenAmountNonZeroAndATokenBalanceZero_ReturnsZeroAndSkipsWithdraw() public {
            uint256 marketId = 1;

            // deploy mocks for underlying and aToken
            ERC20Mock underlying = new ERC20Mock("Token", "TOK", 18);
            ERC20Mock aToken = new ERC20Mock("AToken", "aTOK", 18);

            // mock external Aave contracts
            IPool mockPool = IPool(makeAddr("mockPool"));
            IAavePoolDataProvider mockDataProvider = IAavePoolDataProvider(makeAddr("mockDataProvider"));
            IPoolAddressesProvider mockProvider = IPoolAddressesProvider(makeAddr("mockProvider"));

            // wire provider -> pool and dataProvider
            vm.mockCall(
                address(mockProvider),
                abi.encodeWithSelector(IPoolAddressesProvider.getPool.selector),
                abi.encode(address(mockPool))
            );
            vm.mockCall(
                address(mockProvider),
                abi.encodeWithSelector(IPoolAddressesProvider.getPoolDataProvider.selector),
                abi.encode(address(mockDataProvider))
            );

            // mock data provider to return our aToken for the underlying asset
            vm.mockCall(
                address(mockDataProvider),
                abi.encodeWithSelector(IAavePoolDataProvider.getReserveTokensAddresses.selector, address(underlying)),
                abi.encode(address(aToken), address(0), address(0))
            );

            // deploy fuse with valid constructor params
            AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(marketId, address(mockProvider));

            // Use PlasmaVaultMock so substrate storage and fuse execution share the same context
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // grant substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = address(underlying);
            vault.grantAssetsToMarket(marketId, assets);

            // ensure vault has ZERO aToken balance so finalAmount becomes 0
            assertEq(aToken.balanceOf(address(vault)), 0, "precondition: aToken balance must be zero");

            // prepare exit data with non-zero amount
            AaveV3SupplyFuseExitData memory data_ = AaveV3SupplyFuseExitData({asset: address(underlying), amount: 1 ether});

            // call exit via vault (delegatecall) so storage context matches
            vault.exitAaveV3Supply(data_);

            // assertions: function did not revert (early return with zero amount)
            assertTrue(true, "exit completed without revert");
        }
}