// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {EulerV2SwapRegistryFuse, EulerV2SwapRegistryFuseEnterData, EulerV2SwapRegistryFuseExitData} from "../../../contracts/fuses/euler/EulerV2SwapRegistryFuse.sol";
import {EulerFuseLib} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

import {EulerV2SwapTestVault} from "./mocks/EulerV2SwapTestVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockEulerV2SwapPool} from "./mocks/MockEulerV2SwapPool.sol";
import {MockEulerV2SwapRegistry} from "./mocks/MockEulerV2SwapRegistry.sol";

/// @title EulerV2SwapRegistryFuse Unit Tests
/// @notice Tests the register/unregister lifecycle of the EulerV2SwapRegistryFuse executed via
///         delegatecall from a PlasmaVault-like harness, routing through a mock EVC and registry.
contract EulerV2SwapRegistryFuseTest is Test {
    uint256 public constant MARKET_ID = 11; // EULER_V2
    bytes1 public constant SUB_ACCOUNT = 0x01;

    EulerV2SwapRegistryFuse public fuse;
    EulerV2SwapTestVault public harness;
    MockEVC public evc;
    MockEulerV2SwapRegistry public registry;
    MockEulerV2SwapPool public pool;

    address public eulerAccount;

    event EulerV2SwapRegistryFuseEnter(address version, address pool, address eulerAccount);
    event EulerV2SwapRegistryFuseExit(address version, address pool, address eulerAccount);

    function setUp() public {
        evc = new MockEVC();
        registry = new MockEulerV2SwapRegistry();
        harness = new EulerV2SwapTestVault();
        fuse = new EulerV2SwapRegistryFuse(MARKET_ID, address(evc), address(registry));

        // Under delegatecall, address(this) inside the fuse == harness.
        eulerAccount = EulerFuseLib.generateSubAccountAddress(address(harness), SUB_ACCOUNT);

        pool = new MockEulerV2SwapPool();
        IEulerV2Swap.StaticParams memory sp;
        sp.eulerAccount = eulerAccount;
        pool.setStaticParams(sp);
    }

    // ============================================
    // Helpers
    // ============================================

    function _enter(EulerV2SwapRegistryFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapRegistryFuse.enter, (data)));
    }

    function _exit(EulerV2SwapRegistryFuseExitData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapRegistryFuse.exit, (data)));
    }

    function _buildEnterData() internal view returns (EulerV2SwapRegistryFuseEnterData memory data) {
        data = EulerV2SwapRegistryFuseEnterData({pool: address(pool), subAccount: SUB_ACCOUNT});
    }

    // ============================================
    // Constructor
    // ============================================

    function test_constructorRevertsWhenEVCIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapRegistryFuse(MARKET_ID, address(0), address(registry));
    }

    function test_constructorRevertsWhenRegistryIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SwapRegistryFuse(MARKET_ID, address(evc), address(0));
    }

    function test_constructorSetsImmutables() public view {
        assertEq(fuse.VERSION(), address(fuse), "VERSION");
        assertEq(fuse.MARKET_ID(), MARKET_ID, "MARKET_ID");
        assertEq(address(fuse.EVC()), address(evc), "EVC");
        assertEq(address(fuse.REGISTRY()), address(registry), "REGISTRY");
    }

    // ============================================
    // Enter (register) - happy path
    // ============================================

    function test_registerHappyPath() public {
        // The vault is funded with native ETH to prove the fuse never spends it: registration is zero-bond.
        vm.deal(address(harness), 1 ether);

        EulerV2SwapRegistryFuseEnterData memory data = _buildEnterData();

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapRegistryFuseEnter(address(fuse), address(pool), eulerAccount);

        _enter(data);

        assertEq(registry.registerCallCount(), 1, "registerPool called once");
        assertEq(registry.lastRegisteredPool(), address(pool), "lastRegisteredPool");
        assertEq(registry.lastBond(), 0, "lastBond == 0 (no native ETH forwarded)");
        assertEq(registry.poolByEulerAccount(eulerAccount), address(pool), "poolByEulerAccount set");

        assertEq(evc.lastOnBehalfOfAccount(), eulerAccount, "EVC onBehalfOfAccount");
        assertEq(evc.lastCallValue(), 0, "EVC value == 0");
        assertEq(evc.lastCallTarget(), address(registry), "EVC target == registry");
        assertEq(address(harness).balance, 1 ether, "vault native ETH untouched");
    }

    // ============================================
    // Enter (register) - reverts
    // ============================================

    function test_registerRevertsInvalidOwner() public {
        address wrongAccount = address(0xDEAD);
        IEulerV2Swap.StaticParams memory sp;
        sp.eulerAccount = wrongAccount;
        pool.setStaticParams(sp);

        EulerV2SwapRegistryFuseEnterData memory data = _buildEnterData();

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapRegistryFuse.EulerV2SwapRegistryFuseInvalidOwner.selector,
                address(pool),
                eulerAccount
            )
        );
        _enter(data);
    }

    // ============================================
    // Exit (unregister) - happy path
    // ============================================

    function test_unregisterHappyPath() public {
        registry.setPoolByEulerAccount(eulerAccount, address(pool));

        EulerV2SwapRegistryFuseExitData memory data = EulerV2SwapRegistryFuseExitData({
            pool: address(pool),
            subAccount: SUB_ACCOUNT
        });

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapRegistryFuseExit(address(fuse), address(pool), eulerAccount);

        _exit(data);

        assertEq(registry.unregisterCallCount(), 1, "unregisterPool called once");
        assertEq(evc.lastOnBehalfOfAccount(), eulerAccount, "EVC onBehalfOfAccount");
        assertEq(evc.lastCallTarget(), address(registry), "EVC target == registry");
        assertEq(evc.lastCallValue(), 0, "EVC value == 0");
    }

    // ============================================
    // Exit (unregister) - reverts
    // ============================================

    function test_unregisterRevertsNotRegistered() public {
        EulerV2SwapRegistryFuseExitData memory data = EulerV2SwapRegistryFuseExitData({
            pool: address(pool),
            subAccount: SUB_ACCOUNT
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SwapRegistryFuse.EulerV2SwapRegistryFuseNotRegistered.selector,
                eulerAccount
            )
        );
        _exit(data);
    }

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
        EulerV2SwapRegistryFuseEnterData memory data = _buildEnterData();

        bytes32[] memory chunks = _toChunks(abi.encode(data));
        harness.setTransientInputs(address(fuse), chunks);

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapRegistryFuseEnter(address(fuse), address(pool), eulerAccount);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapRegistryFuse.enterTransient, ()));

        assertEq(registry.registerCallCount(), 1, "registerPool called once");
        assertEq(registry.lastRegisteredPool(), address(pool), "lastRegisteredPool");
        assertEq(registry.lastBond(), 0, "lastBond == 0 (no native ETH forwarded)");
        assertEq(registry.poolByEulerAccount(eulerAccount), address(pool), "poolByEulerAccount set");
    }

    function test_exitTransient() public {
        registry.setPoolByEulerAccount(eulerAccount, address(pool));

        EulerV2SwapRegistryFuseExitData memory data = EulerV2SwapRegistryFuseExitData({
            pool: address(pool),
            subAccount: SUB_ACCOUNT
        });

        bytes32[] memory chunks = _toChunks(abi.encode(data));
        harness.setTransientInputs(address(fuse), chunks);

        vm.expectEmit(true, true, true, true);
        emit EulerV2SwapRegistryFuseExit(address(fuse), address(pool), eulerAccount);

        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapRegistryFuse.exitTransient, ()));

        assertEq(registry.unregisterCallCount(), 1, "unregisterPool called once");
        assertEq(evc.lastOnBehalfOfAccount(), eulerAccount, "EVC onBehalfOfAccount");
        assertEq(evc.lastCallTarget(), address(registry), "EVC target == registry");
    }
}
