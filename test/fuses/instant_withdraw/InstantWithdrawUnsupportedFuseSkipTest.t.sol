// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultMarketsLib} from "../../../contracts/vaults/lib/PlasmaVaultMarketsLib.sol";
import {PlasmaVaultLib, InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {FusesLib} from "../../../contracts/libraries/FusesLib.sol";

contract SkipTestToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Instant withdrawal fuse that mints `params_[0]` to the vault (delegatecall context), capped at `params_[1]` when set
contract SkipTestInstantWithdrawFuse {
    uint256 public immutable MARKET_ID;
    SkipTestToken public immutable UNDERLYING;

    constructor(uint256 marketId_, SkipTestToken underlying_) {
        MARKET_ID = marketId_;
        UNDERLYING = underlying_;
    }

    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);
        if (params_.length > 1 && uint256(params_[1]) != 0 && uint256(params_[1]) < amount) {
            amount = uint256(params_[1]);
        }
        UNDERLYING.mint(address(this), amount); // address(this) is the vault under delegatecall
    }
}

/// @dev Minimal vault storage context running the real PlasmaVaultMarketsLib.withdrawFromMarkets loop
contract SkipTestVaultHarness {
    address public immutable UNDERLYING;

    constructor(address underlying_) {
        UNDERLYING = underlying_;
    }

    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function addFuse(address fuse_) external {
        FusesLib.addFuse(fuse_);
    }

    function removeFuse(address fuse_) external {
        FusesLib.removeFuse(fuse_);
    }

    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) external {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses_);
    }

    function withdrawFromMarkets(uint256 assets_) external returns (uint256[] memory) {
        return
            PlasmaVaultMarketsLib.withdrawFromMarkets(UNDERLYING, assets_, ERC20(UNDERLYING).balanceOf(address(this)));
    }
}

/// @notice IL-9534 (3sigma #7, Pete D-005): PlasmaVaultMarketsLib.withdrawFromMarkets must skip an instant-withdrawal
/// entry whose fuse is no longer supported (FusesLib.isFuseSupported), keep the original loop index for the
/// (fuse, index) parameter lookup and not add the skipped fuse's market to the returned list.
contract InstantWithdrawUnsupportedFuseSkipTest is Test {
    bytes4 internal constant INSTANT_WITHDRAW_SELECTOR = bytes4(keccak256("instantWithdraw(bytes32[])"));
    uint256 internal constant REMOVED_MARKET_ID = 2001;
    uint256 internal constant HEALTHY_MARKET_ID = 2002;

    SkipTestToken internal underlying;
    SkipTestVaultHarness internal vault;
    SkipTestInstantWithdrawFuse internal removedFuse;
    SkipTestInstantWithdrawFuse internal healthyFuse;

    function setUp() public {
        underlying = new SkipTestToken();
        vault = new SkipTestVaultHarness(address(underlying));
        removedFuse = new SkipTestInstantWithdrawFuse(REMOVED_MARKET_ID, underlying);
        healthyFuse = new SkipTestInstantWithdrawFuse(HEALTHY_MARKET_ID, underlying);

        vault.addFuse(address(removedFuse));
        vault.addFuse(address(healthyFuse));
    }

    function testShouldNotCallRemovedFuseAndFallThroughToHealthyOne() public {
        // given
        address[] memory list = new address[](2);
        list[0] = address(removedFuse);
        list[1] = address(healthyFuse);
        _configure(list);
        vault.removeFuse(address(removedFuse));

        // then
        vm.expectCall(address(removedFuse), abi.encodePacked(INSTANT_WITHDRAW_SELECTOR), 0);

        // when
        uint256[] memory markets = vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18, "healthy fuse covers the full amount");
        assertEq(markets[0], HEALTHY_MARKET_ID, "only the healthy market is reported");
        assertEq(markets[1], 0, "removed fuse's market not reported");
    }

    function testShouldUseParamsOfOriginalIndexForHealthyFuseAfterSkippedEntry() public {
        // given: [removed, healthy(cap 300), healthy(cap 200)], the healthy fuse repeated with different params
        address[] memory list = new address[](3);
        list[0] = address(removedFuse);
        list[1] = address(healthyFuse);
        list[2] = address(healthyFuse);
        InstantWithdrawalFusesParamsStruct[] memory entries = new InstantWithdrawalFusesParamsStruct[](3);
        entries[0] = InstantWithdrawalFusesParamsStruct({fuse: list[0], params: new bytes32[](2)});
        entries[1] = InstantWithdrawalFusesParamsStruct({fuse: list[1], params: _paramsWithCap(300e18)});
        entries[2] = InstantWithdrawalFusesParamsStruct({fuse: list[2], params: _paramsWithCap(200e18)});
        vault.configureInstantWithdrawalFuses(entries);
        vault.removeFuse(address(removedFuse));

        // each call must carry the params configured at its own original index (amount left, then that index's cap)
        vm.expectCall(address(healthyFuse), _instantWithdrawCall(1_000e18, 300e18));
        vm.expectCall(address(healthyFuse), _instantWithdrawCall(700e18, 200e18));

        // when
        uint256[] memory markets = vault.withdrawFromMarkets(1_000e18);

        // then: 300 from index 1 and 200 from index 2 (500 < request, so swapped or shifted params change the total)
        assertEq(underlying.balanceOf(address(vault)), 500e18, "300 + 200 delivered");
        assertEq(markets[0], HEALTHY_MARKET_ID);
        assertEq(markets[1], 0, "same market listed once");
    }

    function testShouldSkipEveryOccurrenceOfRemovedFuse() public {
        // given: [removed, healthy, removed, healthy]
        InstantWithdrawalFusesParamsStruct[] memory entries = new InstantWithdrawalFusesParamsStruct[](4);
        entries[0] = InstantWithdrawalFusesParamsStruct({fuse: address(removedFuse), params: new bytes32[](2)});
        entries[1] = InstantWithdrawalFusesParamsStruct({fuse: address(healthyFuse), params: _paramsWithCap(400e18)});
        entries[2] = InstantWithdrawalFusesParamsStruct({fuse: address(removedFuse), params: new bytes32[](2)});
        entries[3] = InstantWithdrawalFusesParamsStruct({fuse: address(healthyFuse), params: new bytes32[](2)});
        vault.configureInstantWithdrawalFuses(entries);
        vault.removeFuse(address(removedFuse));

        vm.expectCall(address(removedFuse), abi.encodePacked(INSTANT_WITHDRAW_SELECTOR), 0);

        // when
        uint256[] memory markets = vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18, "400 from index 1, 600 from index 3");
        assertEq(markets[0], HEALTHY_MARKET_ID);
        assertEq(markets[1], 0);
    }

    function testShouldLeaveAmountUnservedWhenEveryEntryIsUnsupported() public {
        // given
        address[] memory list = new address[](2);
        list[0] = address(removedFuse);
        list[1] = address(healthyFuse);
        _configure(list);
        vault.removeFuse(address(removedFuse));
        vault.removeFuse(address(healthyFuse));

        vm.expectCall(address(removedFuse), abi.encodePacked(INSTANT_WITHDRAW_SELECTOR), 0);
        vm.expectCall(address(healthyFuse), abi.encodePacked(INSTANT_WITHDRAW_SELECTOR), 0);

        // when
        uint256[] memory markets = vault.withdrawFromMarkets(1_000e18);

        // then: nothing pulled, nothing reported (the vault then reverts on the missing balance as with an empty list)
        assertEq(underlying.balanceOf(address(vault)), 0, "no assets withdrawn");
        assertEq(markets[0], 0);
        assertEq(markets[1], 0);
    }

    function testShouldStillCallSupportedFuseWhenNothingIsRemoved() public {
        // given
        address[] memory list = new address[](2);
        list[0] = address(removedFuse);
        list[1] = address(healthyFuse);
        _configure(list);

        // then: the delegatecall to a supported fuse is visible to expectCall (guards the count-0 checks above)
        vm.expectCall(address(removedFuse), abi.encodePacked(INSTANT_WITHDRAW_SELECTOR), 1);

        // when
        uint256[] memory markets = vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18, "first supported fuse serves the amount");
        assertEq(markets[0], REMOVED_MARKET_ID);
        assertEq(markets[1], 0);
    }

    function _instantWithdrawCall(uint256 left_, uint256 cap_) internal pure returns (bytes memory) {
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(left_);
        params[1] = bytes32(cap_);
        return abi.encodeWithSignature("instantWithdraw(bytes32[])", params);
    }

    function _paramsWithCap(uint256 cap_) internal pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[1] = bytes32(cap_);
    }

    function _configure(address[] memory fuses_) internal {
        InstantWithdrawalFusesParamsStruct[] memory entries = new InstantWithdrawalFusesParamsStruct[](fuses_.length);
        for (uint256 i; i < fuses_.length; ++i) {
            entries[i] = InstantWithdrawalFusesParamsStruct({fuse: fuses_[i], params: new bytes32[](2)});
        }
        vault.configureInstantWithdrawalFuses(entries);
    }
}
