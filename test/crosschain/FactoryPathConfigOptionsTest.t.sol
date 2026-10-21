// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {StargateLzSendLib} from "../../contracts/crosschain/stargate/lib/StargateLzSendLib.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title FactoryPathConfigOptionsTest
/// @notice IL-8296 follow-up on the factory: `schedulePathConfig` stored the CREATE_DISPATCHER / ACK / NACK
///         enforced options unvalidated, and `executePathConfig` froze them in the append-only path, so a
///         bad blob blocked dispatcher deployments on that chain for every executor. `schedulePathConfig`
///         now requires, for each of message types 1-3, exactly the `addExecutorLzReceiveOption(gas, 0)`
///         shape with gas in the factory path bounds, and refuses anything else before the timelock starts.
contract FactoryPathConfigOptionsTest is FactoryTestBase {
    using OptionsBuilder for bytes;

    uint16 internal constant CREATE_DISPATCHER = 1;
    uint16 internal constant DEPLOYMENT_ACK = 2;
    uint16 internal constant DEPLOYMENT_NACK = 3;
    uint128 internal constant MIN_GAS = StargateLzSendLib.FACTORY_PATH_MIN_RECEIVE_GAS;
    uint128 internal constant MAX_GAS = StargateLzSendLib.FACTORY_PATH_MAX_RECEIVE_GAS;

    function setUp() public {
        _factorySetUp(CrosschainConstants.MIN_CONFIG_DELAY);
    }

    // ---------------------------------------------------------------------
    // 1. Positive control: the configuration script's shape schedules, executes and is stored verbatim
    // ---------------------------------------------------------------------

    function testShouldScheduleAndExecutePathWithScriptOptions() public requiresFactory {
        factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
        _warpConfigDelay();
        factory.executePathConfig(REMOTE_CHAIN);

        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        assertEq(f.eidOf(REMOTE_CHAIN), REMOTE_EID, "path written");
        assertEq(f.enforcedOptions(REMOTE_EID, CREATE_DISPATCHER), _lzReceive(8_000_000), "deploy options stored");
        assertEq(f.enforcedOptions(REMOTE_EID, DEPLOYMENT_ACK), _lzReceive(1_500_000), "ACK options stored");
        assertEq(f.enforcedOptions(REMOTE_EID, DEPLOYMENT_NACK), _lzReceive(1_500_000), "NACK options stored");
    }

    // ---------------------------------------------------------------------
    // 2. Missing options
    // ---------------------------------------------------------------------

    function testShouldRevertScheduleWithEmptyOptions() public requiresFactory {
        _expectScheduleRevert("", CREATE_DISPATCHER);
    }

    function testShouldRevertScheduleWithOnlyExecutorCommandLaneShape() public requiresFactory {
        // An executor-style registration (msgType 1 only) leaves ACK and NACK without options.
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](1);
        params[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: CREATE_DISPATCHER, options: _lzReceive(2_000_000)});
        _expectScheduleRevert(abi.encode(params), DEPLOYMENT_ACK);
    }

    function testShouldRevertScheduleWithoutNackEntry() public requiresFactory {
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](2);
        params[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: CREATE_DISPATCHER, options: _lzReceive(8_000_000)});
        params[1] = EnforcedOptionParam({eid: REMOTE_EID, msgType: DEPLOYMENT_ACK, options: _lzReceive(1_500_000)});
        _expectScheduleRevert(abi.encode(params), DEPLOYMENT_NACK);
    }

    function testShouldRevertScheduleWithHeaderOnlyOptions() public requiresFactory {
        _expectScheduleRevert(
            _options(OptionsBuilder.newOptions(), _lzReceive(1_500_000), _lzReceive(1_500_000)),
            CREATE_DISPATCHER
        );
    }

    // ---------------------------------------------------------------------
    // 3. Gas bounds (2^100 is the review's unpayable-fee shape)
    // ---------------------------------------------------------------------

    function testShouldRevertScheduleWithZeroGas() public requiresFactory {
        _expectScheduleRevert(_options(_lzReceive(0), _lzReceive(1_500_000), _lzReceive(1_500_000)), CREATE_DISPATCHER);
    }

    function testShouldRevertScheduleWithGasBelowMinimum() public requiresFactory {
        _expectScheduleRevert(
            _options(_lzReceive(8_000_000), _lzReceive(MIN_GAS - 1), _lzReceive(1_500_000)),
            DEPLOYMENT_ACK
        );
    }

    function testShouldRevertScheduleWithGasAboveMaximum() public requiresFactory {
        _expectScheduleRevert(
            _options(_lzReceive(MAX_GAS + 1), _lzReceive(1_500_000), _lzReceive(1_500_000)),
            CREATE_DISPATCHER
        );
    }

    function testShouldRevertScheduleWithUnpayableGas() public requiresFactory {
        _expectScheduleRevert(
            _options(_lzReceive(8_000_000), _lzReceive(1_500_000), _lzReceive(uint128(1) << 100)),
            DEPLOYMENT_NACK
        );
    }

    function testShouldScheduleWithGasOnBothBounds() public requiresFactory {
        factory.schedulePathConfig(
            REMOTE_CHAIN,
            REMOTE_EID,
            _options(_lzReceive(MAX_GAS), _lzReceive(MIN_GAS), _lzReceive(MIN_GAS))
        );
        _warpConfigDelay();
        factory.executePathConfig(REMOTE_CHAIN);

        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        assertEq(f.enforcedOptions(REMOTE_EID, CREATE_DISPATCHER), _lzReceive(MAX_GAS), "max gas stored");
        assertEq(f.enforcedOptions(REMOTE_EID, DEPLOYMENT_ACK), _lzReceive(MIN_GAS), "min gas stored");
    }

    // ---------------------------------------------------------------------
    // 4. Anything besides one plain lzReceive option (value, native drop, compose)
    // ---------------------------------------------------------------------

    function testShouldRevertScheduleWithLzReceiveValue() public requiresFactory {
        _expectScheduleRevert(
            _options(
                _lzReceive(8_000_000),
                OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_500_000, 1e24),
                _lzReceive(1_500_000)
            ),
            DEPLOYMENT_ACK
        );
    }

    function testShouldRevertScheduleWithNativeDrop() public requiresFactory {
        _expectScheduleRevert(
            _options(
                _lzReceive(8_000_000),
                _lzReceive(1_500_000),
                _lzReceive(1_500_000).addExecutorNativeDropOption(1e24, bytes32(uint256(uint160(address(0xBEEF)))))
            ),
            DEPLOYMENT_NACK
        );
    }

    function testShouldRevertScheduleWithCompose() public requiresFactory {
        _expectScheduleRevert(
            _options(
                _lzReceive(8_000_000).addExecutorLzComposeOption(0, 1_500_000, 0),
                _lzReceive(1_500_000),
                _lzReceive(1_500_000)
            ),
            CREATE_DISPATCHER
        );
    }

    // ---------------------------------------------------------------------
    // 5. Last duplicate wins, as in `_setEnforcedOptions`
    // ---------------------------------------------------------------------

    function testShouldRevertScheduleWhenLastDuplicateIsInvalid() public requiresFactory {
        EnforcedOptionParam[] memory params = _params(
            _lzReceive(8_000_000),
            _lzReceive(1_500_000),
            _lzReceive(1_500_000),
            4
        );
        params[3] = EnforcedOptionParam({eid: REMOTE_EID, msgType: DEPLOYMENT_ACK, options: _lzReceive(0)});
        _expectScheduleRevert(abi.encode(params), DEPLOYMENT_ACK);
    }

    function testShouldScheduleWhenLastDuplicateIsValid() public requiresFactory {
        EnforcedOptionParam[] memory params = _params(_lzReceive(8_000_000), _lzReceive(0), _lzReceive(1_500_000), 4);
        params[3] = EnforcedOptionParam({eid: REMOTE_EID, msgType: DEPLOYMENT_ACK, options: _lzReceive(1_500_000)});

        factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, abi.encode(params));
        _warpConfigDelay();
        factory.executePathConfig(REMOTE_CHAIN);

        StargateCrosschainFactory f = StargateCrosschainFactory(payable(address(factory)));
        assertEq(f.enforcedOptions(REMOTE_EID, DEPLOYMENT_ACK), _lzReceive(1_500_000), "later duplicate stored");
    }

    // ---------------------------------------------------------------------
    // 6. The early path-shape check still runs first, with its own error
    // ---------------------------------------------------------------------

    function testShouldRevertScheduleWithZeroChainIdBeforeOptionsCheck() public requiresFactory {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidChainRegistration.selector, 0, REMOTE_EID));
        factory.schedulePathConfig(0, REMOTE_EID, "");
    }

    function testShouldRevertScheduleForLocalChainBeforeOptionsCheck() public requiresFactory {
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.InvalidChainRegistration.selector, LOCAL_CHAIN, REMOTE_EID)
        );
        factory.schedulePathConfig(LOCAL_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _expectScheduleRevert(bytes memory enforcedOptions_, uint16 msgType_) internal {
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.PathConfigOptionsInvalid.selector, REMOTE_CHAIN, msgType_)
        );
        factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, enforcedOptions_);
    }

    function _lzReceive(uint128 gas_) internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas_, 0);
    }

    function _options(
        bytes memory deploy_,
        bytes memory ack_,
        bytes memory nack_
    ) internal pure returns (bytes memory) {
        return abi.encode(_params(deploy_, ack_, nack_, 3));
    }

    function _params(
        bytes memory deploy_,
        bytes memory ack_,
        bytes memory nack_,
        uint256 length_
    ) internal pure returns (EnforcedOptionParam[] memory params) {
        params = new EnforcedOptionParam[](length_);
        params[0] = EnforcedOptionParam({eid: REMOTE_EID, msgType: CREATE_DISPATCHER, options: deploy_});
        params[1] = EnforcedOptionParam({eid: REMOTE_EID, msgType: DEPLOYMENT_ACK, options: ack_});
        params[2] = EnforcedOptionParam({eid: REMOTE_EID, msgType: DEPLOYMENT_NACK, options: nack_});
    }
}
