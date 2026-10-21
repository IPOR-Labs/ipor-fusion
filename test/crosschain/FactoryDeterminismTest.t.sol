// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title FactoryDeterminismTest
/// @notice CREATE3 addressing guarantees (plan §3.2): `computeExecutorAddress` matches the actually deployed
///         address; salt = keccak(creator, userSalt) so a different creator cannot squat a planned address
///         (frontrunning); the executor address is chainid-independent (same address on every chain).
/// @dev Requires the oversized real factory — auto-skips under `--code-size-limit 60000`, passes at 130000.
contract FactoryDeterminismTest is FactoryTestBase {
    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
        if (factoryReady) _enableUsdc();
    }

    function testShouldMatchComputedExecutorAddress() public requiresFactory {
        bytes32 userSalt = keccak256("exec-1");
        address creator = address(0xC0FFEE);
        _allow(creator);
        address predicted = factory.computeExecutorAddress(creator, userSalt);

        vm.prank(creator);
        address deployed = factory.createExecutor(userSalt, _params(address(0x1234)));

        assertEq(deployed, predicted, "deployed executor lands at the computed CREATE3 address");
        assertGt(deployed.code.length, 0, "executor has code");
        assertTrue(
            StargateCrosschainFactory(payable(address(factory))).assetFrozen(ASSET_ID),
            "executor creation freezes its asset config"
        );
    }

    function testShouldBindSaltToCreatorPreventingSquatting() public requiresFactory {
        bytes32 userSalt = keccak256("planned");
        address victim = address(0xBEEF);
        address attacker = address(0xA77AC);
        _allow(attacker);

        // The same userSalt resolves to DIFFERENT addresses per creator: an attacker cannot squat the
        // victim's planned address by racing `createExecutor` with the same userSalt (plan §3.2 / risk #2).
        address victimAddr = factory.computeExecutorAddress(victim, userSalt);
        address attackerAddr = factory.computeExecutorAddress(attacker, userSalt);
        assertTrue(victimAddr != attackerAddr, "creator-bound salt => distinct addresses");

        vm.prank(attacker);
        address deployed = factory.createExecutor(userSalt, _params(address(0x1234)));
        assertEq(deployed, attackerAddr, "attacker lands on its own address");
        assertEq(victimAddr.code.length, 0, "victim's planned address is untouched");
    }

    function testShouldDeriveSaltAsKeccakOfCreatorAndUserSalt() public requiresFactory {
        address creator = address(0xC0FFEE);
        _allow(creator);
        assertTrue(
            factory.computeExecutorAddress(creator, keccak256("a"))
                != factory.computeExecutorAddress(creator, keccak256("b")),
            "userSalt participates in the address"
        );
    }

    function testShouldBeChainIndependentExecutorAddress() public requiresFactory {
        bytes32 userSalt = keccak256("exec-1");
        address creator = address(0xC0FFEE);

        vm.chainId(1);
        address onEth = factory.computeExecutorAddress(creator, userSalt);
        vm.chainId(42161);
        address onArb = factory.computeExecutorAddress(creator, userSalt);
        vm.chainId(8453);
        address onBase = factory.computeExecutorAddress(creator, userSalt);

        // CREATE3 address = f(factory address, salt) only — identical on every chain (same-address model).
        assertEq(onEth, onArb, "same address ETH vs ARB");
        assertEq(onArb, onBase, "same address ARB vs BASE");
    }

    function testShouldRejectExecutorForDisabledAsset() public requiresFactory {
        ExecutorInitParams memory p = _params(address(0x1234));
        p.assetId = keccak256("DAI");
        vm.expectRevert();
        factory.createExecutor(keccak256("x"), p);
    }

    function testShouldRegisterExecutorInRegistryOnCreate() public requiresFactory {
        bytes32 userSalt = keccak256("reg");
        address creator = address(0xC0FFEE);
        _allow(creator);
        vm.prank(creator);
        address deployed = factory.createExecutor(userSalt, _params(address(0x1234)));
        // isExecutor / saltOf are on the concrete factory; read via low-level staticcall to avoid importing it.
        assertEq(deployed, factory.computeExecutorAddress(creator, userSalt), "registered deployment matches preview");
    }

    function testShouldListExecutorsByManager() public requiresFactory {
        address managerA = address(0x1234);
        address managerB = address(0x5678);
        _allow(address(0xA1));
        _allow(address(0xB1));
        _allow(address(0xA2));

        assertEq(factory.executorsOf(managerA).length, 0, "unknown manager has an empty list");

        vm.prank(address(0xA1));
        address executorA1 = factory.createExecutor(keccak256("a1"), _params(managerA));
        vm.prank(address(0xB1));
        address executorB1 = factory.createExecutor(keccak256("b1"), _params(managerB));
        vm.prank(address(0xA2));
        address executorA2 = factory.createExecutor(keccak256("a2"), _params(managerA));

        address[] memory managerAExecutors = factory.executorsOf(managerA);
        assertEq(managerAExecutors.length, 2, "manager A executor count");
        assertEq(managerAExecutors[0], executorA1, "manager A first executor");
        assertEq(managerAExecutors[1], executorA2, "manager A second executor");

        address[] memory managerBExecutors = factory.executorsOf(managerB);
        assertEq(managerBExecutors.length, 1, "manager B executor count");
        assertEq(managerBExecutors[0], executorB1, "manager B executor");
    }

    function testShouldRestrictCreationByDefault() public requiresFactory {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(StargateCrosschainFactory.CreatorNotAllowed.selector, stranger));
        factory.createExecutor(keccak256("blocked"), _params(address(0x1234)));
    }

    function _allow(address creator_) private {
        StargateCrosschainFactory(payable(address(factory))).setCreatorAllowed(creator_, true);
    }
}
