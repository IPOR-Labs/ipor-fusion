// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/moonwell/MoonwellSupplyFuse.sol

import {MoonwellSupplyFuse, MoonwellSupplyFuseEnterData} from "contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MErc20} from "contracts/fuses/moonwell/ext/MErc20.sol";
import {MoonwellSupplyFuseExitData} from "contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {MoonwellHelperLib} from "contracts/fuses/moonwell/MoonwellHelperLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {DustBalanceFuseMock} from "test/connectorsLib/DustBalanceFuseMock.sol";
import {Test} from "forge-std/Test.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
contract MoonwellSupplyFuseTest is OlympixUnitTest("MoonwellSupplyFuse") {


    function test_enter_WhenAmountZero_ShouldReturnEarlyAndNotMint() public {
            uint256 marketId = 1;
            MoonwellSupplyFuse fuse = new MoonwellSupplyFuse(marketId);
    
            MoonwellSupplyFuseEnterData memory data_ = MoonwellSupplyFuseEnterData({asset: address(0x1234), amount: 0});
    
            (address returnedAsset, address returnedMarket, uint256 returnedAmount) = fuse.enter(data_);
    
            assertEq(returnedAsset, address(0x1234));
            assertEq(returnedMarket, address(0));
            assertEq(returnedAmount, 0);
        }

    function test_enter_WhenAmountNonZero_ShouldMintToMoonwellMarket() public {
            // setup
            uint256 marketId = 1;
            MoonwellSupplyFuse fuse = new MoonwellSupplyFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // create underlying ERC20 and mock mToken
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            address mToken = address(0xABCD);

            // Grant mToken as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = mToken;
            vault.grantAssetsToMarket(marketId, assets);

            // Mock MErc20.underlying() and MErc20.mint()
            vm.mockCall(mToken, abi.encodeWithSelector(MErc20.underlying.selector), abi.encode(address(underlying)));
            vm.mockCall(mToken, abi.encodeWithSelector(MErc20.mint.selector), abi.encode(uint256(0)));

            // Mock approve calls
            vm.mockCall(address(underlying), abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

            // mint underlying to vault
            underlying.mint(address(vault), 100 ether);

            MoonwellSupplyFuseEnterData memory data_ = MoonwellSupplyFuseEnterData({asset: address(underlying), amount: 10 ether});

            // Call via vault's fallback (delegatecall)
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(MoonwellSupplyFuse.enter.selector, data_)
            );
            assertTrue(success, "enter should not revert");
            (address returnedAsset, address returnedMarket, uint256 returnedAmount) = abi.decode(result, (address, address, uint256));

            assertEq(returnedAsset, address(underlying));
            assertEq(returnedMarket, mToken);
            assertEq(returnedAmount, 10 ether);
        }

    function test_instantWithdraw_TakesTrueBranchAndCallsExitWithCatch() public {
            uint256 marketId = 1;
            MoonwellSupplyFuse fuse = new MoonwellSupplyFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Set up mock mToken
            address mToken = address(0xC0FFEE);
            address asset = address(0xBEEF);

            // Grant mToken as substrate
            address[] memory assets = new address[](1);
            assets[0] = mToken;
            vault.grantAssetsToMarket(marketId, assets);

            // Mock MErc20 calls
            vm.mockCall(mToken, abi.encodeWithSelector(MErc20.underlying.selector), abi.encode(asset));
            vm.mockCall(mToken, abi.encodeWithSelector(MErc20.balanceOfUnderlying.selector, address(vault)), abi.encode(uint256(0)));

            // prepare params: amount = 123, asset = address(0xBEEF)
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(uint256(123));
            params[1] = bytes32(uint256(uint160(asset)));

            // call instantWithdraw via vault
            vault.instantWithdraw(params);
        }

    function test_exit_WhenAmountZero_ShouldReturnEarlyAndNotCallRedeem() public {
            uint256 marketId = 1;
            MoonwellSupplyFuse fuse = new MoonwellSupplyFuse(marketId);
    
            // prepare dummy substrate so getMarketSubstrates(marketId) is non-empty
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = bytes32(uint256(uint160(address(0xABCD))));
            PlasmaVaultStorageLib.getMarketSubstrates().value[marketId].substrates = substrates;
            PlasmaVaultStorageLib.getMarketSubstrates().value[marketId].substrateAllowances[substrates[0]] = 1;
    
            address asset = address(new MockERC20("Token", "TKN", 18));
            MoonwellSupplyFuseExitData memory data_ = MoonwellSupplyFuseExitData({asset: asset, amount: 0});
    
            (address returnedAsset, address returnedMarket, uint256 returnedAmount) = fuse.exit(data_);
    
            // Branch opix-target-branch-154-True: should take early return
            assertEq(returnedAsset, asset);
            assertEq(returnedMarket, address(0));
            assertEq(returnedAmount, 0);
        }

    function test_exit_WhenAmountNonZero_ShouldEnterElseBranchAndClampToZero() public {
            // Arrange: set up a MoonwellSupplyFuse to be used via delegatecall from PlasmaVaultMock
            uint256 marketId = 1;
            MoonwellSupplyFuse fuseImpl = new MoonwellSupplyFuse(marketId);

            // PlasmaVaultMock delegates calls to fuseImpl
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuseImpl), address(0));

            // Underlying asset
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);

            // Mock mToken address
            address mToken = address(0xABCD);

            // Grant mToken as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = mToken;
            vault.grantAssetsToMarket(marketId, assets);

            // Mock MErc20 calls
            vm.mockCall(mToken, abi.encodeWithSelector(MErc20.underlying.selector), abi.encode(address(underlying)));
            vm.mockCall(mToken, abi.encodeWithSelector(MErc20.balanceOfUnderlying.selector, address(vault)), abi.encode(uint256(0)));

            // Prepare non-zero exit data
            MoonwellSupplyFuseExitData memory data_ = MoonwellSupplyFuseExitData({
                asset: address(underlying),
                amount: 1e18
            });

            // Act: call exit via vault's fallback (delegatecall)
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(MoonwellSupplyFuse.exit.selector, data_)
            );
            assertTrue(success, "exit should not revert");
            (address returnedAsset, address returnedMarket, uint256 returnedAmount) = abi.decode(result, (address, address, uint256));

            // Assert: non-zero branch taken, amount clamped to zero since balance is 0
            assertEq(returnedAsset, address(underlying));
            assertEq(returnedMarket, mToken);
            assertEq(returnedAmount, 0);
        }

    function test_enterTransient_UsesVersionKeyAndWritesOutputs() public {
            // Arrange: deploy fuse with any marketId
            uint256 marketId = 1;
            MoonwellSupplyFuse fuse = new MoonwellSupplyFuse(marketId);

            // Use PlasmaVaultMock for delegatecall so transient storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient storage inputs: use amount=0 so enter() early-returns
            address asset = address(0x1234);
            uint256 amount = 0;

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(asset);
            inputs[1] = TypeConversionLib.toBytes32(amount);

            vault.setInputs(fuse.VERSION(), inputs);

            // Act: call enterTransient via vault delegatecall
            vault.execute(address(fuse), abi.encodeWithSignature("enterTransient()"));

            // Assert: outputs are written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 3, "outputs length");

            address outAsset = TypeConversionLib.toAddress(outputs[0]);
            address outMarket = TypeConversionLib.toAddress(outputs[1]);
            uint256 outAmount = TypeConversionLib.toUint256(outputs[2]);

            assertEq(outAsset, asset, "asset mismatch");
            assertEq(outMarket, address(0), "market should be zero when amount is zero");
            assertEq(outAmount, 0, "amount should be zero");
        }
}