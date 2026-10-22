// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title SetDelegateFactoryDisabledTest
/// @notice IL-8557 / IL-8558: the vendored `OAppCore.setDelegate` is an instant, owner-only endpoint call with
///         no `CONFIG_DELAY` and no guardian veto, so `StargateLzOAppBase` overrides it to revert
///         `ConfigViaAuthorizedPathOnly()` for everyone (like `setPeer` / `setEnforcedOptions`). The factory
///         keeps its owner on purpose, so it is the host where the un-neutralized route was reachable.
/// @dev Requires the oversized real factory; skips under `--code-size-limit 60000` (see `FactoryTestBase`).
contract SetDelegateFactoryDisabledTest is FactoryTestBase {
    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
    }

    function _factory() internal view returns (StargateCrosschainFactory) {
        return StargateCrosschainFactory(payable(address(factory)));
    }

    function testShouldRevertSetDelegateOnFactoryByOwner() public requiresFactory {
        StargateCrosschainFactory f = _factory();
        address owner = f.owner();
        assertTrue(owner != address(0), "factory keeps its owner");

        vm.prank(owner);
        vm.expectRevert(CrosschainErrors.ConfigViaAuthorizedPathOnly.selector);
        f.setDelegate(address(0xBEEF));
    }

    function testShouldRevertSetDelegateOnFactoryByStranger() public requiresFactory {
        StargateCrosschainFactory f = _factory();

        vm.prank(address(0xBAD));
        vm.expectRevert(CrosschainErrors.ConfigViaAuthorizedPathOnly.selector);
        f.setDelegate(address(0xBEEF));
    }
}

/// @title SetDelegateExecutorDisabledTest
/// @notice IL-8557 / IL-8558: `setDelegate` is disabled on the executor for every caller, including the rescue
///         admin that is the Ownable owner during construction (ownership is then renounced).
contract SetDelegateExecutorDisabledTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
    }

    function testShouldRevertSetDelegateOnExecutor() public {
        assertEq(executor.owner(), address(0), "ownership renounced");
        vm.prank(admin);
        vm.expectRevert(CrosschainErrors.ConfigViaAuthorizedPathOnly.selector);
        executor.setDelegate(address(0xBEEF));

        vm.prank(address(0xBAD));
        vm.expectRevert(CrosschainErrors.ConfigViaAuthorizedPathOnly.selector);
        executor.setDelegate(address(0xBEEF));
    }
}

/// @title SetDelegateDispatcherDisabledTest
/// @notice IL-8557 / IL-8558: `setDelegate` is disabled on the dispatcher for every caller.
contract SetDelegateDispatcherDisabledTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(42161);
        vm.warp(365 days);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockStargatePool pool = new MockStargatePool(address(usdc), 6);
        MockLzEndpoint endpoint = new MockLzEndpoint();
        vm.recordLogs();

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
    }

    function testShouldClearEndpointDelegateAtConstruction() public {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Delegated(address,address)");
        uint256 count;
        address lastDelegate = address(1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 1 || logs[i].topics[0] != sig) continue;
            (address caller, address delegate) = abi.decode(logs[i].data, (address, address));
            if (caller != address(dispatcher)) continue;
            ++count;
            lastDelegate = delegate;
        }
        assertGe(count, 2, "owner delegate set, then cleared");
        assertEq(lastDelegate, address(0), "last delegate is zero");
    }

    function testShouldRevertSetDelegateOnDispatcher() public {
        assertEq(dispatcher.owner(), address(0), "ownership renounced");
        vm.prank(admin);
        vm.expectRevert(CrosschainErrors.ConfigViaAuthorizedPathOnly.selector);
        dispatcher.setDelegate(address(0xBEEF));

        vm.prank(address(0xBAD));
        vm.expectRevert(CrosschainErrors.ConfigViaAuthorizedPathOnly.selector);
        dispatcher.setDelegate(address(0xBEEF));
    }
}
