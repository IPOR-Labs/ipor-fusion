// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, DeploymentTicket} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";

/// @title StargateFactoryDispatcherReceiptGasTest
/// @notice IL-9092: pins the msgType 1 enforced option (dispatcher -> executor receipts) that the real
///         `StargateCrosschainFactory` gives a dispatcher it deploys: exactly 2,000,000 `lzReceive` gas. The Stargate
///         fork suites mirror this value in `StargateForkBase.DISPATCHER_RECEIVE_GAS` and prove the receipt handlers
///         fit it with the 1.3x margin; without this pin that constant would only be a copy of a private factory value.
/// @dev Requires the oversized real factory — skips under `--code-size-limit 60000`, passes at 130000.
contract StargateFactoryDispatcherReceiptGasTest is FactoryTestBase {
    using OptionsBuilder for bytes;

    /// @dev The value of the private `StargateCrosschainFactory.DISPATCHER_RECEIVE_GAS`.
    uint128 internal constant EXPECTED_DISPATCHER_RECEIVE_GAS = 2_000_000;

    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
        if (factoryReady) {
            _enableUsdc();
            // Register the executor's chain so a ticket from it can arrive.
            factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
            _warpConfigDelay();
            factory.executePathConfig(REMOTE_CHAIN);
            vm.deal(address(factory), 100 ether);
            StargateCrosschainFactory(payable(address(factory))).setMaxNativeFee(REMOTE_CHAIN, type(uint256).max);
        }
    }

    function testShouldDeployDispatcherWithTwoMillionReceiptGasOption() public requiresFactory {
        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("receipt-gas");
        address predicted = factory.computeExecutorAddress(creator, userSalt);
        assertEq(predicted.code.length, 0, "predicted address empty before");

        DeploymentTicket memory ticket = DeploymentTicket({
            requestId: 1,
            salt: keccak256(abi.encode(creator, userSalt)),
            executor: predicted,
            srcChainId: REMOTE_CHAIN,
            dstChainId: LOCAL_CHAIN,
            assetId: ASSET_ID,
            admin: admin,
            guardian: guardian,
            rescueDelay: 3 days,
            immutableParamsHash: keccak256(
                abi.encode(admin, guardian, uint256(3 days), REMOTE_CHAIN, LOCAL_CHAIN, ASSET_ID)
            ),
            expiresAt: block.timestamp + 7 days
        });
        endpoint.deliverLz(
            address(factory),
            REMOTE_EID,
            bytes32(uint256(uint160(address(factory)))),
            keccak256("guid"),
            CrosschainMessages.encodeDeploymentTicket(ticket)
        );

        assertGt(predicted.code.length, 0, "dispatcher deployed through the real factory");
        StargateCrosschainDispatcher deployed = StargateCrosschainDispatcher(payable(predicted));
        assertEq(
            deployed.enforcedOptions(REMOTE_EID, 1),
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(EXPECTED_DISPATCHER_RECEIVE_GAS, 0),
            "receipts to the executor are registered at exactly 2,000,000 lzReceive gas"
        );
    }
}
