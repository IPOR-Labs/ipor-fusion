// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    EulerV2SwapDeployFuse,
    EulerV2SwapDeployFuseEnterData
} from "../../../contracts/fuses/euler/EulerV2SwapDeployFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IEulerV2Swap} from "../../../contracts/fuses/euler/ext/IEulerV2Swap.sol";

import {EulerV2SwapTestVault} from "./mocks/EulerV2SwapTestVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";
import {MockEulerV2SwapFactory} from "./mocks/MockEulerV2SwapFactory.sol";
import {MockEulerV2SwapPool} from "./mocks/MockEulerV2SwapPool.sol";
import {MockPriceOracleMiddlewareForEulerSwap} from "./mocks/MockPriceOracleMiddlewareForEulerSwap.sol";

/// @title EulerV2SwapDeployFuse pool substrate requirement (IL-9706)
/// @notice `enter` must refuse to deploy a pool that has no pool entry on the EULER_V2 market for the same
///         pool address and sub-account. The entry is built inline (no library symbols) so this file compiles
///         on the base commit, where the deploy proceeds without any entry.
contract EulerV2SwapDeployFusePoolSubstrateTest is Test {
    uint256 public constant MARKET_ID = 11;
    bytes1 public constant SUB_ACCOUNT = 0x01;
    bytes1 public constant OTHER_SUB_ACCOUNT = 0x02;
    uint256 public constant PRICE_DEVIATION_WAD = 1e16;

    EulerV2SwapDeployFuse public fuse;
    EulerV2SwapTestVault public harness;
    MockEVC public evc;
    MockEulerV2SwapFactory public factory;
    MockEulerV2SwapPool public pool;
    MockPriceOracleMiddlewareForEulerSwap public oracle;

    address public eulerAccount;
    address public predictedPool;

    address public asset0 = address(0xA0);
    address public asset1 = address(0xA1);
    address public supplyVault0 = address(0x5010);
    address public supplyVault1 = address(0x5011);

    function setUp() public {
        evc = new MockEVC();
        factory = new MockEulerV2SwapFactory();
        harness = new EulerV2SwapTestVault();
        fuse = new EulerV2SwapDeployFuse(MARKET_ID, address(evc), address(factory), PRICE_DEVIATION_WAD);

        eulerAccount = EulerFuseLib.generateSubAccountAddress(address(harness), SUB_ACCOUNT);

        pool = new MockEulerV2SwapPool();
        pool.setAssets(asset0, asset1);
        predictedPool = address(pool);
        factory.setComputeResult(predictedPool);

        oracle = new MockPriceOracleMiddlewareForEulerSwap();
        harness.setPriceOracle(address(oracle));
        vm.mockCall(supplyVault0, abi.encodeWithSignature("asset()"), abi.encode(asset0));
        vm.mockCall(supplyVault1, abi.encodeWithSignature("asset()"), abi.encode(asset1));
        vm.mockCall(asset0, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.mockCall(asset1, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        oracle.setAssetPrice(asset0, 1e18, 18);
        oracle.setAssetPrice(asset1, 1e18, 18);
    }

    // ============================================
    // Helpers
    // ============================================

    /// @dev Raw pool entry: pool << 96 | subAccount << 72 | kind (bit 64) = 1.
    function _poolEntry(address pool_, bytes1 subAccount_) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(pool_)) << 96) | (uint256(uint8(subAccount_)) << 72) | (1 << 64));
    }

    /// @dev Grants the two supply vaults (supply-only pool) plus the given extra entries.
    function _grant(bytes32[] memory extra) internal {
        bytes32[] memory substrates = new bytes32[](2 + extra.length);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: false, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: false, canBorrow: false, subAccounts: SUB_ACCOUNT})
        );
        for (uint256 i; i < extra.length; ++i) {
            substrates[2 + i] = extra[i];
        }
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _one(bytes32 entry) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = entry;
    }

    function _buildEnterData() internal view returns (EulerV2SwapDeployFuseEnterData memory data) {
        IEulerV2Swap.StaticParams memory sp;
        sp.supplyVault0 = supplyVault0;
        sp.supplyVault1 = supplyVault1;
        sp.eulerAccount = eulerAccount;

        IEulerV2Swap.DynamicParams memory dp;
        dp.equilibriumReserve0 = uint112(1e18);
        dp.equilibriumReserve1 = uint112(1e18);
        dp.priceX = uint80(1e18);
        dp.priceY = uint80(1e18);
        dp.concentrationX = uint64(5e17);
        dp.concentrationY = uint64(5e17);
        dp.fee0 = uint64(1e15);
        dp.fee1 = uint64(1e15);

        IEulerV2Swap.InitialState memory init;
        init.reserve0 = uint112(1e18);
        init.reserve1 = uint112(1e18);

        data = EulerV2SwapDeployFuseEnterData({
            staticParams: sp,
            dynamicParams: dp,
            initialState: init,
            salt: bytes32(uint256(1)),
            predictedPool: predictedPool,
            subAccount: SUB_ACCOUNT
        });
    }

    function _enter(EulerV2SwapDeployFuseEnterData memory data) internal {
        harness.delegateExecute(address(fuse), abi.encodeCall(EulerV2SwapDeployFuse.enter, (data)));
    }

    function _expectNotGranted() internal {
        vm.expectRevert(
            abi.encodeWithSignature("EulerV2SwapDeployFusePoolNotGranted(address,bytes1)", predictedPool, SUB_ACCOUNT)
        );
    }

    // ============================================
    // Tests
    // ============================================

    function test_enterRevertsWithoutPoolEntry() public {
        _grant(new bytes32[](0));

        _expectNotGranted();
        _enter(_buildEnterData());

        assertEq(evc.setOperatorCallCount(), 0, "operator must not be installed");
        assertEq(factory.deployCallCount(), 0, "pool must not be deployed");
    }

    function test_enterRevertsWhenEntryIsForOtherSubAccount() public {
        _grant(_one(_poolEntry(predictedPool, OTHER_SUB_ACCOUNT)));

        _expectNotGranted();
        _enter(_buildEnterData());

        assertEq(evc.setOperatorCallCount(), 0, "operator must not be installed");
    }

    function test_enterRevertsWhenEntryIsForOtherPoolAddress() public {
        _grant(_one(_poolEntry(address(0xDEAD), SUB_ACCOUNT)));

        _expectNotGranted();
        _enter(_buildEnterData());

        assertEq(evc.setOperatorCallCount(), 0, "operator must not be installed");
    }

    function test_enterDeploysWithPoolEntry() public {
        _grant(_one(_poolEntry(predictedPool, SUB_ACCOUNT)));

        _enter(_buildEnterData());

        assertEq(evc.setOperatorCallCount(), 1, "operator installed once");
        assertTrue(evc.isAccountOperatorAuthorized(eulerAccount, predictedPool), "operator authorized");
        assertEq(factory.deployCallCount(), 1, "pool deployed once");
    }

    // ============================================
    // Sub-account 0x00 with the vault's underlying (IL-9706, D-027)
    // ============================================

    bytes1 internal constant SUB_ACCOUNT_ZERO = 0x00;

    /// @dev Grants both supply vaults, plus an optional borrow vault, and the pool entry on sub-account `subAccount_`;
    ///      the harness (the vault in the delegatecall context) reports `vaultAsset_` as its `asset()`.
    function _grantOn(bytes1 subAccount_, address borrowVault_, address vaultAsset_) internal {
        uint256 n = borrowVault_ == address(0) ? 3 : 4;
        bytes32[] memory substrates = new bytes32[](n);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault0, isCollateral: false, canBorrow: false, subAccounts: subAccount_})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: supplyVault1, isCollateral: false, canBorrow: false, subAccounts: subAccount_})
        );
        substrates[2] = _poolEntry(predictedPool, subAccount_);
        if (borrowVault_ != address(0)) {
            substrates[3] = EulerFuseLib.substrateToBytes32(
                EulerSubstrate({
                    eulerVault: borrowVault_,
                    isCollateral: false,
                    canBorrow: true,
                    subAccounts: subAccount_
                })
            );
        }
        harness.grantMarketSubstrates(MARKET_ID, substrates);
        vm.mockCall(address(harness), abi.encodeWithSignature("asset()"), abi.encode(vaultAsset_));
    }

    function _enterDataOn(bytes1 subAccount_) internal view returns (EulerV2SwapDeployFuseEnterData memory data) {
        data = _buildEnterData();
        data.subAccount = subAccount_;
        data.staticParams.eulerAccount = EulerFuseLib.generateSubAccountAddress(address(harness), subAccount_);
    }

    function _expectSubAccountZeroUsesVaultAsset() internal {
        vm.expectRevert(
            abi.encodeWithSignature("EulerV2SwapDeployFuseSubAccountZeroUsesVaultAsset(address)", address(harness))
        );
    }

    function test_enterRevertsOnSubAccountZeroWhenSupplyVault0IsVaultAsset() public {
        _grantOn(SUB_ACCOUNT_ZERO, address(0), supplyVault0);

        _expectSubAccountZeroUsesVaultAsset();
        _enter(_enterDataOn(SUB_ACCOUNT_ZERO));

        assertEq(evc.setOperatorCallCount(), 0, "operator must not be installed");
        assertEq(factory.deployCallCount(), 0, "pool must not be deployed");
    }

    function test_enterRevertsOnSubAccountZeroWhenSupplyVault1IsVaultAsset() public {
        _grantOn(SUB_ACCOUNT_ZERO, address(0), supplyVault1);

        _expectSubAccountZeroUsesVaultAsset();
        _enter(_enterDataOn(SUB_ACCOUNT_ZERO));

        assertEq(evc.setOperatorCallCount(), 0, "operator must not be installed");
        assertEq(factory.deployCallCount(), 0, "pool must not be deployed");
    }

    function test_enterDeploysOnSubAccountZeroWhenNeitherSupplyVaultIsVaultAsset() public {
        _grantOn(SUB_ACCOUNT_ZERO, address(0), address(0xBEEF));

        _enter(_enterDataOn(SUB_ACCOUNT_ZERO));

        assertEq(evc.setOperatorCallCount(), 1, "operator installed once");
        assertEq(factory.deployCallCount(), 1, "pool deployed once");
    }

    function test_enterDeploysOnNonZeroSubAccountWhenSupplyVaultIsVaultAsset() public {
        _grantOn(SUB_ACCOUNT, address(0), supplyVault0);

        _enter(_enterDataOn(SUB_ACCOUNT));

        assertEq(evc.setOperatorCallCount(), 1, "operator installed once");
        assertEq(factory.deployCallCount(), 1, "pool deployed once");
    }

    /// @dev Borrow vaults are not covered by the check (documented atomist rule, not enforced).
    function test_enterDeploysOnSubAccountZeroWhenBorrowVaultIsVaultAsset() public {
        address borrowVault = address(0xB0);
        _grantOn(SUB_ACCOUNT_ZERO, borrowVault, borrowVault);
        // borrowVault0 != 0 also requires supplyVault1 as collateral substrate
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: supplyVault0,
                isCollateral: true,
                canBorrow: false,
                subAccounts: SUB_ACCOUNT_ZERO
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: supplyVault1,
                isCollateral: true,
                canBorrow: false,
                subAccounts: SUB_ACCOUNT_ZERO
            })
        );
        substrates[2] = _poolEntry(predictedPool, SUB_ACCOUNT_ZERO);
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: borrowVault,
                isCollateral: false,
                canBorrow: true,
                subAccounts: SUB_ACCOUNT_ZERO
            })
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);

        EulerV2SwapDeployFuseEnterData memory data = _enterDataOn(SUB_ACCOUNT_ZERO);
        data.staticParams.borrowVault0 = borrowVault;

        _enter(data);

        assertEq(evc.setOperatorCallCount(), 1, "operator installed once");
        assertEq(factory.deployCallCount(), 1, "pool deployed once");
    }
}
