// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @dev Calls the configuration library from a contract with its own storage, to exercise the address variant
contract SubstrateConfigHarness {
    function grantAssets(uint256 marketId_, address[] calldata assets_) external {
        PlasmaVaultConfigLib.grantSubstratesAsAssetsToMarket(marketId_, assets_);
    }

    function grant(uint256 marketId_, bytes32[] calldata substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    /// @dev Rewrites a list entry in place and leaves the allowances untouched, as ExchangeRateValidatorPreHook does
    function rewriteEntry(uint256 marketId_, uint256 index_, bytes32 substrate_) external {
        PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId_).substrates[index_] = substrate_;
    }

    function substrates(uint256 marketId_) external view returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
    }

    function isGranted(uint256 marketId_, bytes32 substrate_) external view returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, substrate_);
    }
}

/// @title PlasmaVaultGrantSubstratesDuplicateTest
/// @notice IL-9642 - `grantMarketSubstrates` and `grantSubstratesAsAssetsToMarket` stored the list verbatim, so a
///         repeated substrate made every balance fuse that walks the list count its position more than once. The
///         configuration core now reverts with `MarketSubstrateDuplicate(marketId, substrate)` on an exact duplicate.
/// @dev The custom error is addressed by its literal signature so that the test also compiles against the base commit.
contract PlasmaVaultGrantSubstratesDuplicateTest is PlasmaVaultMockMarketsTestBase {
    bytes4 private constant DUPLICATE_SELECTOR = bytes4(keccak256("MarketSubstrateDuplicate(uint256,bytes32)"));

    bytes32 private constant S1 = bytes32(uint256(uint160(address(0x1111))));
    bytes32 private constant S2 = bytes32(uint256(uint160(address(0x2222))));
    bytes32 private constant S3 = bytes32(uint256(uint160(address(0x3333))));

    function _governance() private view returns (PlasmaVaultGovernance) {
        return PlasmaVaultGovernance(address(plasmaVault));
    }

    function _list(bytes32 a_, bytes32 b_, bytes32 c_) private pure returns (bytes32[] memory list) {
        list = new bytes32[](3);
        list[0] = a_;
        list[1] = b_;
        list[2] = c_;
    }

    function testShouldRevertWhenAdjacentDuplicateGranted() public {
        bytes32[] memory list = new bytes32[](2);
        list[0] = S1;
        list[1] = S1;

        vm.expectRevert(abi.encodeWithSelector(DUPLICATE_SELECTOR, MARKET_A, S1));
        _governance().grantMarketSubstrates(MARKET_A, list);
    }

    function testShouldRevertWhenNonAdjacentDuplicateGranted() public {
        vm.expectRevert(abi.encodeWithSelector(DUPLICATE_SELECTOR, MARKET_A, S1));
        _governance().grantMarketSubstrates(MARKET_A, _list(S1, S2, S1));
    }

    function testShouldRevertWhenZeroSubstrateRepeated() public {
        bytes32[] memory list = new bytes32[](2);

        vm.expectRevert(abi.encodeWithSelector(DUPLICATE_SELECTOR, MARKET_A, bytes32(0)));
        _governance().grantMarketSubstrates(MARKET_A, list);
    }

    function testShouldKeepPreviousConfigurationWhenDuplicateRejected() public {
        bytes32[] memory before = _governance().getMarketSubstrates(MARKET_A);

        vm.expectRevert(abi.encodeWithSelector(DUPLICATE_SELECTOR, MARKET_A, S2));
        _governance().grantMarketSubstrates(MARKET_A, _list(S1, S2, S2));

        bytes32[] memory afterRevert = _governance().getMarketSubstrates(MARKET_A);
        assertEq(afterRevert.length, before.length, "list length unchanged");
        assertEq(afterRevert[0], before[0], "list entry unchanged");
    }

    function testShouldGrantListWithoutDuplicates() public {
        _governance().grantMarketSubstrates(MARKET_A, _list(S1, S2, S3));

        bytes32[] memory stored = _governance().getMarketSubstrates(MARKET_A);
        assertEq(stored.length, 3, "three substrates stored");
        assertEq(stored[0], S1);
        assertEq(stored[1], S2);
        assertEq(stored[2], S3);
    }

    /// @dev The same list granted again, and a list overlapping the previous one, must pass: the old grants are
    ///      cleared before the new list is checked, so they never count as duplicates
    function testShouldAllowRegrantingSameAndOverlappingLists() public {
        _governance().grantMarketSubstrates(MARKET_A, _list(S1, S2, S3));
        _governance().grantMarketSubstrates(MARKET_A, _list(S1, S2, S3));

        bytes32[] memory overlapping = new bytes32[](2);
        overlapping[0] = S3;
        overlapping[1] = S1;
        _governance().grantMarketSubstrates(MARKET_A, overlapping);

        bytes32[] memory stored = _governance().getMarketSubstrates(MARKET_A);
        assertEq(stored.length, 2, "overlapping list stored");
        assertEq(stored[0], S3);
        assertEq(stored[1], S1);
    }

    function testShouldAllowEmptyAndSingleEntryLists() public {
        _governance().grantMarketSubstrates(MARKET_A, new bytes32[](0));
        assertEq(_governance().getMarketSubstrates(MARKET_A).length, 0, "empty list");

        bytes32[] memory single = new bytes32[](1);
        single[0] = S1;
        _governance().grantMarketSubstrates(MARKET_A, single);
        assertEq(_governance().getMarketSubstrates(MARKET_A).length, 1, "single entry");
    }

    function testShouldAllowSameSubstrateOnDifferentMarkets() public {
        bytes32[] memory single = new bytes32[](1);
        single[0] = S1;
        _governance().grantMarketSubstrates(MARKET_A, single);
        _governance().grantMarketSubstrates(MARKET_B, single);

        assertEq(_governance().getMarketSubstrates(MARKET_B)[0], S1);
    }

    /// @dev Only exact duplicates are detected: an alias with dirty upper bits is a different bytes32 value and stays
    ///      the configurator's responsibility (documented in the NatSpec)
    function testShouldNotDetectAliasWithDirtyUpperBits() public {
        bytes32 alias_ = S1 | (bytes32(uint256(1)) << 200);
        bytes32[] memory list = new bytes32[](2);
        list[0] = S1;
        list[1] = alias_;

        _governance().grantMarketSubstrates(MARKET_A, list);

        assertEq(_governance().getMarketSubstrates(MARKET_A).length, 2, "alias stored as a separate substrate");
    }

    // ------------------------------------------------------------------ address variant

    function testShouldRevertWhenDuplicateAssetAddressGranted() public {
        SubstrateConfigHarness harness = new SubstrateConfigHarness();
        address[] memory assets = new address[](3);
        assets[0] = address(0x1111);
        assets[1] = address(0x2222);
        assets[2] = address(0x1111);

        vm.expectRevert(abi.encodeWithSelector(DUPLICATE_SELECTOR, MARKET_A, S1));
        harness.grantAssets(MARKET_A, assets);
    }

    function testShouldGrantAssetAddressesAndAllowRegrant() public {
        SubstrateConfigHarness harness = new SubstrateConfigHarness();
        address[] memory assets = new address[](2);
        assets[0] = address(0x1111);
        assets[1] = address(0x2222);

        harness.grantAssets(MARKET_A, assets);
        harness.grantAssets(MARKET_A, assets);

        assertEq(harness.substrates(MARKET_A).length, 2, "two assets stored");
        assertTrue(harness.isGranted(MARKET_A, S1));
        assertTrue(harness.isGranted(MARKET_A, S2));

        address[] memory narrowed = new address[](1);
        narrowed[0] = address(0x2222);
        harness.grantAssets(MARKET_A, narrowed);

        assertFalse(harness.isGranted(MARKET_A, S1), "revoked asset no longer granted");
        assertTrue(harness.isGranted(MARKET_A, S2));
    }

    // ------------------------------------------------------------------ stale allowance after in-place rewrite

    function testShouldRegrantOriginalSubstrateAfterListEntryRewrittenInPlace() public {
        SubstrateConfigHarness harness = new SubstrateConfigHarness();
        bytes32[] memory original = new bytes32[](1);
        original[0] = S1;
        harness.grant(MARKET_A, original);

        // re-anchor: the list entry changes, the allowance of the original value stays set
        harness.rewriteEntry(MARKET_A, 0, S2);

        harness.grant(MARKET_A, original);

        bytes32[] memory stored = harness.substrates(MARKET_A);
        assertEq(stored.length, 1, "one entry stored");
        assertEq(stored[0], S1, "original value restored");
        assertTrue(harness.isGranted(MARKET_A, S1), "original value granted");
        assertFalse(harness.isGranted(MARKET_A, S2), "rewritten value not granted");
    }

    function testShouldRegrantOriginalAssetAfterListEntryRewrittenInPlace() public {
        SubstrateConfigHarness harness = new SubstrateConfigHarness();
        address[] memory original = new address[](1);
        original[0] = address(0x1111);
        harness.grantAssets(MARKET_A, original);

        harness.rewriteEntry(MARKET_A, 0, S2);

        harness.grantAssets(MARKET_A, original);

        assertEq(harness.substrates(MARKET_A).length, 1, "one entry stored");
        assertTrue(harness.isGranted(MARKET_A, S1), "original asset granted");
    }

    function testShouldStillRevertOnDuplicateAfterListEntryRewrittenInPlace() public {
        SubstrateConfigHarness harness = new SubstrateConfigHarness();
        bytes32[] memory original = new bytes32[](1);
        original[0] = S1;
        harness.grant(MARKET_A, original);
        harness.rewriteEntry(MARKET_A, 0, S2);

        vm.expectRevert(abi.encodeWithSelector(DUPLICATE_SELECTOR, MARKET_A, S1));
        harness.grant(MARKET_A, _list(S1, S3, S1));
    }

    function testShouldLeaveExactlyOneAllowanceAfterRegrant() public {
        SubstrateConfigHarness harness = new SubstrateConfigHarness();
        bytes32[] memory original = new bytes32[](1);
        original[0] = S1;
        harness.grant(MARKET_A, original);
        harness.rewriteEntry(MARKET_A, 0, S2);
        harness.grant(MARKET_A, _list(S1, S2, S3));

        // revoke semantics unchanged: narrowing the list clears values that are still listed
        harness.grant(MARKET_A, original);
        assertTrue(harness.isGranted(MARKET_A, S1));
        assertFalse(harness.isGranted(MARKET_A, S2), "dropped value revoked");
        assertFalse(harness.isGranted(MARKET_A, S3), "dropped value revoked");
    }
}
