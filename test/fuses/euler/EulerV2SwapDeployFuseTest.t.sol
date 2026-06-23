// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {EulerV2SwapDeployFuse, EulerV2SwapDeployFuseEnterData, EulerV2SwapDeployFuseExitData} from "../../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

import {EulerV2SwapTestVault} from "./mocks/EulerV2SwapTestVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockEulerV2SwapFactory} from "./mocks/MockEulerV2SwapFactory.sol";
import {MockEulerV2SwapPool} from "./mocks/MockEulerV2SwapPool.sol";

/// @title EulerV2SwapDeployFuse Unit Tests
/// @notice Tests the deploy/exit lifecycle of the EulerV2SwapDeployFuse executed via delegatecall
///         from a PlasmaVault-like harness.
contract EulerV2SwapDeployFuseTest is Test {
    uint256 public constant MARKET_ID = 11; // EULER_V2
    bytes1 public constant SUB_ACCOUNT = 0x01;

    EulerV2SwapDeployFuse public fuse;
    EulerV2SwapTestVault public harness;
    MockEVC public evc;
    MockEulerV2SwapFactory public factory;
    MockEulerV2SwapPool public pool;

    address public eulerAccount;
    address public predictedPool;

    address public asset0 = address(0xA0);
    address public asset1 = address(0xA1);

    address public supplyVault0 = address(0x5010);
    address public supplyVault1 = address(0x5011);
    address public borrowVault0 = address(0xB010);
    address public borrowVault1 = address(0xB011);

    event EulerV2SwapDeployFuseEnter(
        address version,
        address pool,
        address eulerAccount,
        bytes1 subAccount,
        address asset0,
        address asset1
    );

    event EulerV2SwapDeployFuseExit(address version, address pool, address eulerAccount, bytes1 subAccount);

    function setUp() public {
        evc = new MockEVC();
        factory = new MockEulerV2SwapFactory();
        harness = new EulerV2SwapTestVault();
        fuse = new EulerV2SwapDeployFuse(MARKET_ID, address(evc), address(factory));

        // Under delegatecall, address(this) inside the fuse == harness.
        eulerAccount = EulerFuseLib.generateSubAccountAddress(address(harness), SUB_ACCOUNT);

        // Deploy a pool mock and use its address as the predicted/computed/deployed pool address.
        pool = new MockEulerV2SwapPool();
        pool.setAssets(asset0, asset1);
        predictedPool = address(pool);

        _grantAllSubstrates();

        factory.setComputeResult(predictedPool);
    }

    // ============================================
    // Helpers
    // ============================================

    function _grantAllSubstrates() internal {
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _grantSubstrates(bytes32[] memory substrates) internal {
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _buildEnterData() internal view returns (EulerV2SwapDeployFuseEnterData memory data) {
        IEulerV2Swap.StaticParams memory sp;
        sp.supplyVault0 = supplyVault0;
        sp.supplyVault1 = supplyVault1;
        sp.borrowVault0 = borrowVault0;
        sp.borrowVault1 = borrowVault1;
        sp.eulerAccount = eulerAccount;
        sp.feeRecipient = address(0);

        IEulerV2Swap.DynamicParams memory dp;
        IEulerV2Swap.InitialState memory init;

        data = EulerV2SwapDeployFuseEnterData({
            staticParams: sp,
            dynamicParams: dp,
            initialState: init,
            salt: bytes32(uint256(1)),
            predictedPool: predictedPool,
            subAccount: SUB_ACCOUNT
        });
    }

    function _enter(EulerV2SwapDeployFuseEnterData memory data) internal returns (address deployed) {
        bytes memory ret = harness.delegateExecute(
            address(fuse),
            abi.encodeCall(EulerV2SwapDeployFuse.enter, (data))
        );
        deployed = abi.decode(ret, (address));
    }

    /// @dev Invokes enter via the harness without decoding the return value, so `vm.expectRevert`
    ///      cleanly wraps the single reverting external call.
    function _enterExpectRevert(EulerV2SwapDeployFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapDeployFuse.enter, (data)));
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructorRevertsWhenEVCIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapDeployFuse(MARKET_ID, address(0), address(factory));
    }

    function test_constructorRevertsWhenFactoryIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapDeployFuse(MARKET_ID, address(evc), address(0));
    }

    function test_constructorSetsImmutables() public view {
        assertEq(fuse.VERSION(), address(fuse), "VERSION");
        assertEq(fuse.MARKET_ID(), MARKET_ID, "MARKET_ID");
        assertEq(address(fuse.EVC()), address(evc), "EVC");
        assertEq(address(fuse.FACTORY()), address(factory), "FACTORY");
    }

    // ============================================
    // Enter - happy path
    // ============================================

    function test_enterHappyPath() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapDeployFuseEnter(address(fuse), predictedPool, eulerAccount, SUB_ACCOUNT, asset0, asset1);

        address deployed = _enter(data);

        assertEq(deployed, predictedPool, "returned pool should equal predictedPool");

        assertEq(evc.setOperatorCallCount(), 1, "setAccountOperator called once");
        assertEq(evc.lastAccount(), eulerAccount, "operator set for eulerAccount");
        assertEq(evc.lastOperator(), predictedPool, "operator is predictedPool");
        assertTrue(evc.lastAuthorized(), "operator authorized true");
        assertTrue(evc.isAccountOperatorAuthorized(eulerAccount, predictedPool), "authorization stored");

        assertEq(factory.deployCallCount(), 1, "deployPool called once");
        assertEq(factory.lastEulerAccount(), eulerAccount, "deployPool eulerAccount");
    }

    function test_enterHappyPathSupplyOnlyZeroBorrowVaults() public {
        // EulerSwap allows borrowVault0/1 == address(0) (supply-only / non-JIT pool). The deploy fuse must
        // accept it WITHOUT any borrow substrate granted, while still requiring the supply substrates.
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        _grantSubstrates(substrates);

        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        data.staticParams.borrowVault0 = address(0);
        data.staticParams.borrowVault1 = address(0);

        address deployed = _enter(data);

        assertEq(deployed, predictedPool, "supply-only pool deploys");
        assertEq(factory.deployCallCount(), 1, "deployPool called once");
        assertTrue(evc.isAccountOperatorAuthorized(eulerAccount, predictedPool), "operator authorized");
    }

    // ============================================
    // Enter - reverts
    // ============================================

    function test_enterRevertsInvalidEulerAccount() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        address wrong = address(0xDEAD);
        data.staticParams.eulerAccount = wrong;

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapDeployFuse.EulerV2SwapDeployFuseInvalidEulerAccount.selector,
                eulerAccount,
                wrong
            )
        );
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidFeeRecipient() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        address feeRecipient = address(0xFEE);
        data.staticParams.feeRecipient = feeRecipient;

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapDeployFuse.EulerV2SwapDeployFuseInvalidFeeRecipient.selector,
                feeRecipient
            )
        );
        _enterExpectRevert(data);
    }

    function test_enterRevertsUnsupportedSupplyVault() public {
        // Grant everything except supplyVault0.
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        _grantSubstrates(substrates);

        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapDeployFuse.EulerV2SwapDeployFuseUnsupportedVault.selector,
                supplyVault0,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    function test_enterRevertsUnsupportedBorrowVault() public {
        // Grant borrowVault0 WITHOUT the canBorrow flag, proving the borrow branch.
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: true, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault0, isCollateral: false, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: borrowVault1, isCollateral: false, canBorrow: true, subAccounts: SUB_ACCOUNT})
        );
        _grantSubstrates(substrates);

        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapDeployFuse.EulerV2SwapDeployFuseUnsupportedVault.selector,
                borrowVault0,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsFeeTooHigh() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.fee0 = uint64(1e18); // >= MAX_FEE

        vm.expectRevert(EulerV2SwapDeployFuse.EulerV2SwapDeployFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsExpirationInPast() public {
        vm.warp(1_000_000);
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.expiration = uint40(block.timestamp - 1);

        vm.expectRevert(EulerV2SwapDeployFuse.EulerV2SwapDeployFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsSwapHookSet() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.swapHook = address(0xBEEF);

        vm.expectRevert(EulerV2SwapDeployFuse.EulerV2SwapDeployFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsSwapHookedOperationsSet() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.swapHookedOperations = 1;

        vm.expectRevert(EulerV2SwapDeployFuse.EulerV2SwapDeployFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsPoolAddressMismatchOnCompute() public {
        address other = address(0xC0FFEE);
        factory.setComputeResult(other);

        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapDeployFuse.EulerV2SwapDeployFusePoolAddressMismatch.selector,
                predictedPool,
                other
            )
        );
        _enterExpectRevert(data);
    }

    function test_enterRevertsPoolAddressMismatchOnDeploy() public {
        address other = address(0xBADBAD);
        factory.setComputeResult(predictedPool);
        factory.setDeployResult(other);

        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapDeployFuse.EulerV2SwapDeployFusePoolAddressMismatch.selector,
                predictedPool,
                other
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Exit
    // ============================================

    // ============================================
    // Transient entry points
    // ============================================

    /// @dev Split ABI-encoded bytes into 32-byte chunks for transient storage.
    function _toChunks(bytes memory enc) internal pure returns (bytes32[] memory chunks) {
        uint256 n = (enc.length + 31) / 32;
        chunks = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 c;
            assembly {
                c := mload(add(enc, add(32, mul(i, 32))))
            }
            chunks[i] = c;
        }
    }

    function test_enterTransient() public {
        EulerV2SwapDeployFuseEnterData memory data = _buildEnterData();

        bytes32[] memory chunks = _toChunks(abi.encode(data));
        harness.setTransientInputs(address(fuse), chunks);

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapDeployFuseEnter(address(fuse), predictedPool, eulerAccount, SUB_ACCOUNT, asset0, asset1);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapDeployFuse.enterTransient, ()));

        assertEq(evc.setOperatorCallCount(), 1, "setAccountOperator called once");
        assertTrue(evc.isAccountOperatorAuthorized(eulerAccount, predictedPool), "authorization stored");
        assertEq(factory.deployCallCount(), 1, "deployPool called once");

        bytes32[] memory outputs = harness.getTransientOutputs(address(fuse));
        assertEq(outputs.length, 1, "one output");
        assertEq(address(uint160(uint256(outputs[0]))), predictedPool, "output[0] == predictedPool");
    }

    function test_exitTransient() public {
        EulerV2SwapDeployFuseExitData memory data = EulerV2SwapDeployFuseExitData({
            pool: predictedPool,
            subAccount: SUB_ACCOUNT
        });

        bytes32[] memory chunks = _toChunks(abi.encode(data));
        harness.setTransientInputs(address(fuse), chunks);

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapDeployFuseExit(address(fuse), predictedPool, eulerAccount, SUB_ACCOUNT);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapDeployFuse.exitTransient, ()));

        assertEq(evc.setOperatorCallCount(), 1, "setAccountOperator called once");
        assertEq(evc.lastOperator(), predictedPool, "operator is pool");
        assertFalse(evc.lastAuthorized(), "operator authorized false");
        assertFalse(evc.isAccountOperatorAuthorized(eulerAccount, predictedPool), "authorization cleared");
    }

    function test_exit() public {
        EulerV2SwapDeployFuseExitData memory data = EulerV2SwapDeployFuseExitData({
            pool: predictedPool,
            subAccount: SUB_ACCOUNT
        });

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapDeployFuseExit(address(fuse), predictedPool, eulerAccount, SUB_ACCOUNT);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapDeployFuse.exit, (data)));

        assertEq(evc.setOperatorCallCount(), 1, "setAccountOperator called once");
        assertEq(evc.lastAccount(), eulerAccount, "operator removed for eulerAccount");
        assertEq(evc.lastOperator(), predictedPool, "operator is pool");
        assertFalse(evc.lastAuthorized(), "operator authorized false");
        assertFalse(evc.isAccountOperatorAuthorized(eulerAccount, predictedPool), "authorization cleared");
    }
}
