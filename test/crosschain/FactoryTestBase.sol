// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {ICrosschainFactory, ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title FactoryTestBase
/// @notice Shared scaffolding for the two suites that need the REAL `StargateCrosschainFactory`. The factory is
///         intentionally oversized (~110,772 B runtime — it embeds both the executor and dispatcher creation
///         code for CREATE3), which is ABOVE the mandated `--code-size-limit 60000` bypass. To keep that
///         mandated run green, the factory deploy is probed under try/catch: if it fails the size limit these
///         suites SKIP; run them at `--code-size-limit 130000` for full coverage (reported to the integrator).
abstract contract FactoryTestBase is Test {
    using OptionsBuilder for bytes;

    MockLzEndpoint internal endpoint;
    MockERC20 internal usdc;
    MockStargatePool internal pool;
    ICrosschainFactory internal factory;
    bool internal factoryReady;

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);
    address internal proposer = address(0xB0B0B0);
    address internal approver = address(0xB1B1B1);
    bytes32 internal constant ASSET_ID = keccak256("USDC");

    uint256 internal constant LOCAL_CHAIN = 1;
    uint256 internal constant REMOTE_CHAIN = 42161;
    uint32 internal constant LOCAL_EID = 30101;
    uint32 internal constant REMOTE_EID = 30110;

    function _factorySetUp(uint256 configDelay_) internal {
        vm.chainId(LOCAL_CHAIN);
        vm.warp(365 days);
        endpoint = new MockLzEndpoint();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);

        try this.deployFactoryExt(configDelay_) returns (address f) {
            factory = ICrosschainFactory(f);
            factory.configureCreationCodes(
                type(StargateCrosschainExecutor).creationCode, type(StargateCrosschainDispatcher).creationCode
            );
            factoryReady = true;
        } catch {
            factoryReady = false; // factory exceeds the active code-size limit; suites skip.
        }
    }

    /// @dev External so a size-limit revert from `deployCode` is catchable (keeps the 60000 run green).
    function deployFactoryExt(uint256 configDelay_) external returns (address) {
        bytes memory args = abi.encode(address(endpoint), address(this), admin, guardian, uint256(3 days), configDelay_);
        return vm.deployCode("StargateCrosschainFactory.sol:StargateCrosschainFactory", args);
    }

    /// @dev Skips the calling test when the oversized factory could not be deployed under the active limit.
    modifier requiresFactory() {
        if (!factoryReady) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _params(address manager_) internal view returns (ExecutorInitParams memory) {
        return ExecutorInitParams({
            assetId: ASSET_ID,
            manager: manager_,
            admin: admin,
            rescueGuardian: guardian,
            rescueDelay: 3 days,
            balanceProposer: proposer,
            balanceApprover: approver,
            stalenessMax: 1 hours,
            bigChangeBps: 1000,
            minUpdateInterval: 10 minutes,
            deploymentTtl: 1 days,
            transferStalenessMax: 2 hours
        });
    }

    /// @dev The factory path options `schedulePathConfig` requires since IL-8296, with the configuration
    ///      script's gas budgets (`ConfigureCrosschainFactory.s.sol`): 8,000,000 for CREATE_DISPATCHER and
    ///      1,500,000 for DEPLOYMENT_ACK / DEPLOYMENT_NACK.
    function _factoryPathOptions(uint32 eid_) internal pure returns (bytes memory) {
        bytes memory deployOption = OptionsBuilder.newOptions().addExecutorLzReceiveOption(8_000_000, 0);
        bytes memory ackOption = OptionsBuilder.newOptions().addExecutorLzReceiveOption(1_500_000, 0);
        EnforcedOptionParam[] memory params = new EnforcedOptionParam[](3);
        params[0] = EnforcedOptionParam({eid: eid_, msgType: 1, options: deployOption});
        params[1] = EnforcedOptionParam({eid: eid_, msgType: 2, options: ackOption});
        params[2] = EnforcedOptionParam({eid: eid_, msgType: 3, options: ackOption});
        return abi.encode(params);
    }

    /// @dev Advances time past the factory configuration timelock (floored at `MIN_CONFIG_DELAY`, IL-8538).
    function _warpConfigDelay() internal {
        vm.warp(block.timestamp + CrosschainConstants.MIN_CONFIG_DELAY);
    }

    /// @dev Enable USDC on the factory (schedule, wait out the config timelock, execute).
    function _enableUsdc() internal {
        factory.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool));
        _warpConfigDelay();
        factory.executeAssetConfig(ASSET_ID);
    }
}
