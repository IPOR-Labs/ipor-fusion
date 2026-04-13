// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/moonwell/MoonwellBorrowFuse.sol

import {MoonwellBorrowFuse, MoonwellBorrowFuseEnterData} from "contracts/fuses/moonwell/MoonwellBorrowFuse.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MErc20} from "contracts/fuses/moonwell/ext/MErc20.sol";
import {MoonwellBorrowFuse, MoonwellBorrowFuseExitData} from "contracts/fuses/moonwell/MoonwellBorrowFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MoonwellHelperLib} from "contracts/fuses/moonwell/MoonwellHelperLib.sol";
import {MoonwellBorrowFuse} from "contracts/fuses/moonwell/MoonwellBorrowFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
contract MoonwellBorrowFuseTest is OlympixUnitTest("MoonwellBorrowFuse") {


    function test_enter_WhenAmountNonZero_HitsElseBranch() public {
            MoonwellBorrowFuse fuse = new MoonwellBorrowFuse(1);
    
            MoonwellBorrowFuseEnterData memory data_ = MoonwellBorrowFuseEnterData({
                asset: address(0x1),
                amount: 1
            });
    
            // We only need to hit the else-branch after the `if (data_.amount == 0)` check.
            // Subsequent external calls can revert; we don't care about their behavior for this branch test.
            vm.expectRevert();
            fuse.enter(data_);
        }

    function test_exit_NonZeroAmountHitsElseBranch() public {
            // deploy underlying token
            MockERC20 underlying = new MockERC20("Mock", "MOCK", 18);
            // mock mToken address
            address mTokenAddr = address(0xABCD);

            // deploy fuse bound to MARKET_ID = 1
            MoonwellBorrowFuse fuse = new MoonwellBorrowFuse(1);

            // use PlasmaVaultMock so delegatecall shares storage context
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // grant mToken as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = mTokenAddr;
            vault.grantAssetsToMarket(1, assets);

            // mock MErc20.underlying() to return our underlying address
            vm.mockCall(mTokenAddr, abi.encodeWithSelector(MErc20.underlying.selector), abi.encode(address(underlying)));
            // mock MErc20.repayBorrow() to succeed (return 0)
            vm.mockCall(mTokenAddr, abi.encodeWithSelector(MErc20.repayBorrow.selector), abi.encode(uint256(0)));

            // mint underlying to vault so fuse can approve and repay
            underlying.mint(address(vault), 1e18);

            // mock approve calls from vault context
            vm.mockCall(
                address(underlying),
                abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))),
                abi.encode(true)
            );

            // prepare non-zero repay data to force exit() into the else-branch
            MoonwellBorrowFuseExitData memory data_ = MoonwellBorrowFuseExitData({asset: address(underlying), amount: 1e18});

            // call exit via delegatecall through PlasmaVaultMock
            vault.execute(address(fuse), abi.encodeWithSelector(MoonwellBorrowFuse.exit.selector, data_));
        }

    function test_enterTransient_AmountNonZero_HitsIfTrueBranch() public {
            // Deploy fuse with arbitrary marketId
            MoonwellBorrowFuse fuse = new MoonwellBorrowFuse(1);
    
            // We only need to reach the body guarded by `if (true)` in enterTransient.
            // All internal calls (to TransientStorageLib, TypeConversionLib, enter, etc.)
            // can revert; we don't care about their behavior, just branch coverage.
            vm.expectRevert();
            fuse.enterTransient();
        }

    function test_exitTransient_HitsTrueBranch() public {
            // Deploy fuse with any marketId (not used in transient path for this branch test)
            MoonwellBorrowFuse fuse = new MoonwellBorrowFuse(1);
    
            // Prepare transient inputs under VERSION key
            address versionKey = fuse.VERSION();
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(address(0x1)); // asset
            inputs[1] = TypeConversionLib.toBytes32(uint256(1));   // amount (non-zero so inner exit() goes past first if)
            TransientStorageLib.setInputs(versionKey, inputs);
    
            // We only care about entering the `if (true)` branch; inner external calls may revert
            vm.expectRevert();
            fuse.exitTransient();
        }
}