// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    EulerV2SwapReconfigureFuse,
    EulerV2SwapReconfigureFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2SwapReconfigureFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

import {EulerV2SwapTestVault} from "./mocks/EulerV2SwapTestVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockEulerV2SwapFactory} from "./mocks/MockEulerV2SwapFactory.sol";
import {MockEulerV2SwapPool} from "./mocks/MockEulerV2SwapPool.sol";

/// @title EulerV2SwapReconfigureFuse Unit Tests
/// @notice Tests the reconfigure flow of the EulerV2SwapReconfigureFuse executed via delegatecall
///         from a PlasmaVault-like harness, routing the reconfigure call through the EVC.
contract EulerV2SwapReconfigureFuseTest is Test {
    uint256 public constant MARKET_ID = 11; // EULER_V2
    bytes1 public constant SUB_ACCOUNT = 0x01;

    EulerV2SwapReconfigureFuse public fuse;
    EulerV2SwapTestVault public harness;
    MockEVC public evc;
    MockEulerV2SwapFactory public factory;
    MockEulerV2SwapPool public pool;

    address public eulerAccount;

    address public supplyVault0 = address(0x5010);
    address public supplyVault1 = address(0x5011);
    address public borrowVault0 = address(0xB010);
    address public borrowVault1 = address(0xB011);

    event EulerV2SwapReconfigureFuseEnter(address version, address pool, address eulerAccount);

    function setUp() public {
        evc = new MockEVC();
        factory = new MockEulerV2SwapFactory();
        harness = new EulerV2SwapTestVault();
        fuse = new EulerV2SwapReconfigureFuse(MARKET_ID, address(evc), address(factory));

        // Under delegatecall, address(this) inside the fuse == harness.
        eulerAccount = EulerFuseLib.generateSubAccountAddress(address(harness), SUB_ACCOUNT);

        pool = new MockEulerV2SwapPool();
        _setPoolStaticParams(eulerAccount);

        _grantAllSubstrates();
    }

    // ============================================
    // Helpers
    // ============================================

    function _setPoolStaticParams(address eulerAccount_) internal {
        IEulerV2Swap.StaticParams memory sp;
        sp.supplyVault0 = supplyVault0;
        sp.supplyVault1 = supplyVault1;
        sp.borrowVault0 = borrowVault0;
        sp.borrowVault1 = borrowVault1;
        sp.eulerAccount = eulerAccount_;
        sp.feeRecipient = address(0);
        pool.setStaticParams(sp);
    }

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

    function _buildDynamicParams() internal pure returns (IEulerV2Swap.DynamicParams memory dp) {
        dp.equilibriumReserve0 = 1_000;
        dp.equilibriumReserve1 = 2_000;
        dp.minReserve0 = 10;
        dp.minReserve1 = 20;
        dp.priceX = 1e18;
        dp.priceY = 1e18;
        dp.concentrationX = 5e17;
        dp.concentrationY = 5e17;
        dp.fee0 = 1e15; // 0.1%, < 1e18
        dp.fee1 = 2e15; // 0.2%, < 1e18
        dp.expiration = 0; // no expiry
        dp.swapHookedOperations = 0;
        dp.swapHook = address(0);
    }

    function _buildEnterData() internal view returns (EulerV2SwapReconfigureFuseEnterData memory data) {
        IEulerV2Swap.InitialState memory init;
        init.reserve0 = 500;
        init.reserve1 = 600;

        data = EulerV2SwapReconfigureFuseEnterData({
            pool: address(pool),
            subAccount: SUB_ACCOUNT,
            dynamicParams: _buildDynamicParams(),
            initialState: init
        });
    }

    function _enter(EulerV2SwapReconfigureFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapReconfigureFuse.enter, (data)));
    }

    /// @dev Invokes enter via the harness without decoding the return value, so `vm.expectRevert`
    ///      cleanly wraps the single reverting external call.
    function _enterExpectRevert(EulerV2SwapReconfigureFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapReconfigureFuse.enter, (data)));
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructorRevertsWhenEVCIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapReconfigureFuse(MARKET_ID, address(0), address(factory));
    }

    function test_constructorRevertsWhenFactoryIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapReconfigureFuse(MARKET_ID, address(evc), address(0));
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
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapReconfigureFuseEnter(address(fuse), address(pool), eulerAccount);

        _enter(data);

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once");
        assertTrue(pool.reconfigured(), "reconfigured flag set");

        IEulerV2Swap.DynamicParams memory dp = pool.getDynamicParams();
        assertEq(dp.fee0, data.dynamicParams.fee0, "fee0 stored");
        assertEq(dp.fee1, data.dynamicParams.fee1, "fee1 stored");

        assertEq(evc.callCount(), 1, "EVC.call invoked once");
        assertEq(evc.lastOnBehalfOfAccount(), eulerAccount, "EVC onBehalfOf eulerAccount");
        assertEq(evc.lastCallTarget(), address(pool), "EVC target is pool");
        assertEq(evc.lastCallValue(), 0, "EVC call value zero");
    }

    /// @dev A future (non-zero) expiration must be accepted, not just expiration == 0.
    function test_enterAcceptsFutureExpiration() public {
        vm.warp(1_000_000);
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.expiration = uint40(block.timestamp + 1 days);

        _enter(data);

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once for future expiration");
    }

    // ============================================
    // Enter - reverts: unknown pool
    // ============================================

    function test_enterRevertsUnknownPool() public {
        factory.setDeployedPoolsResult(false);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnknownPool.selector,
                address(pool)
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: owner
    // ============================================

    function test_enterRevertsInvalidOwner() public {
        address wrong = address(0xDEAD);
        _setPoolStaticParams(wrong);

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidOwner.selector,
                address(pool),
                eulerAccount
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: unsupported vault
    // ============================================

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

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnsupportedVault.selector,
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

        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseUnsupportedVault.selector,
                borrowVault0,
                SUB_ACCOUNT
            )
        );
        _enterExpectRevert(data);
    }

    // ============================================
    // Enter - reverts: invalid params
    // ============================================

    function test_enterRevertsInvalidParamsFee0TooHigh() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.fee0 = uint64(1e18); // >= MAX_FEE

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsFee1TooHigh() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.fee1 = uint64(1e18); // >= MAX_FEE

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsExpirationInPast() public {
        vm.warp(1_000_000); // ensure block.timestamp > 1
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.expiration = uint40(block.timestamp - 1);

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsSwapHookSet() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.swapHook = address(0xBEEF);

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    function test_enterRevertsInvalidParamsSwapHookedOperationsSet() public {
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();
        data.dynamicParams.swapHookedOperations = 1;

        vm.expectRevert(EulerV2SwapReconfigureFuse.EulerV2SwapReconfigureFuseInvalidParams.selector);
        _enterExpectRevert(data);
    }

    // ============================================
    // Exit
    // ============================================

    function test_exitRevertsUnsupportedOperation() public {
        vm.expectRevert(EulerV2SwapReconfigureFuse.UnsupportedOperation.selector);
        fuse.exit();
    }

    // ============================================
    // Transient entry point
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
        EulerV2SwapReconfigureFuseEnterData memory data = _buildEnterData();

        bytes32[] memory chunks = _toChunks(abi.encode(data));
        harness.setTransientInputs(address(fuse), chunks);

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapReconfigureFuseEnter(address(fuse), address(pool), eulerAccount);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapReconfigureFuse.enterTransient, ()));

        assertEq(pool.reconfigureCallCount(), 1, "reconfigure called once");
        assertTrue(pool.reconfigured(), "reconfigured flag set");
        assertEq(evc.callCount(), 1, "EVC.call invoked once");
    }
}
