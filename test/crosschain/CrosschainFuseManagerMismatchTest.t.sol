// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainNavValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";

import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title CrosschainFuseManagerMismatchTest
/// @notice Pins the "executor MANAGER == this vault" guard of every crosschain consumer (claim, balance, NAV
///         pre-hook, Stargate command, CCIP supply, CCIP command) by exact error selector and arguments. The
///         Stargate supply twin is pinned in `FuseTest.testShouldRejectSupplyEnterForWrongManager`. Each test
///         grants a foreign executor (MANAGER == 0xBEEF) so every earlier check passes and the manager guard is
///         the only reason for the revert.
contract CrosschainFuseManagerMismatchTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    address internal constant FOREIGN_MANAGER = address(0xBEEF);

    MockERC20 internal usdc;
    CrosschainVaultHarness internal vault;
    MockExecutor internal foreign;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new CrosschainVaultHarness(address(usdc));
        vault.setFuses(
            address(new StargateCrosschainSupplyFuse(MARKET)),
            address(new CrosschainClaimFuse(MARKET)),
            address(new StargateCrosschainCommandFuse(MARKET)),
            address(new CrosschainBalanceFuse(MARKET))
        );
        vault.setCcipFuses(
            address(new CcipCrosschainSupplyFuse(MARKET)),
            address(new CcipCrosschainCommandFuse(MARKET))
        );

        foreign = new MockExecutor(FOREIGN_MANAGER, address(usdc)); // MANAGER != vault
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(foreign));
        vault.grantSubstrates(MARKET, subs);
    }

    function _emptyCommand() private pure returns (Command memory) {
        return
            Command({commandId: 0, sequence: 0, commandConfigEpoch: 0, action: 0, minExecutionGas: 0, actionData: ""});
    }

    function testShouldRejectClaimForWrongManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainClaimFuse.CrosschainClaimFuseExecutorManagerMismatch.selector,
                address(foreign),
                FOREIGN_MANAGER
            )
        );
        vault.enterClaim(CrosschainClaimFuseEnterData({executor: address(foreign), amount: 1e6}));
    }

    function testShouldRejectBalanceForWrongManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainBalanceFuse.CrosschainBalanceFuseExecutorManagerMismatch.selector,
                address(foreign),
                FOREIGN_MANAGER
            )
        );
        vault.balanceOf();
    }

    function testShouldRejectPreHookForWrongManager() public {
        CrosschainNavValidationPreHook preHook = new CrosschainNavValidationPreHook(MARKET);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainNavValidationPreHook.CrosschainNavValidationPreHookExecutorManagerMismatch.selector,
                address(foreign),
                FOREIGN_MANAGER
            )
        );
        // Any selector other than execute / updateMarketsBalances reaches the executor loop.
        vault.runPreHook(address(preHook), bytes4(0x12345678));
    }

    function testShouldRejectStargateCommandForWrongManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseExecutorManagerMismatch.selector,
                address(foreign),
                FOREIGN_MANAGER
            )
        );
        vault.enterCommand(
            StargateCrosschainCommandFuseEnterData({
                commandType: StargateCrosschainCommandType.CANCEL_COMMAND,
                executor: address(foreign),
                chainId: 42161,
                eid: 0,
                enforcedOptions: "",
                plasmaVaults: new address[](0),
                requestId: 0,
                command: _emptyCommand()
            })
        );
    }

    function testShouldRejectCcipSupplyForWrongManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainSupplyFuse.CcipSupplyFuseExecutorManagerMismatch.selector,
                address(foreign),
                FOREIGN_MANAGER
            )
        );
        vault.enterCcipSupply(
            CcipSupplyFuseEnterData({
                executor: address(foreign),
                asset: address(usdc),
                dstChainId: 8453,
                amount: 1e6,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 0,
                minDelivered: 0
            })
        );
    }

    function testShouldRejectCcipCommandForWrongManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainCommandFuse.CcipCommandFuseExecutorManagerMismatch.selector,
                address(foreign),
                FOREIGN_MANAGER
            )
        );
        vault.enterCcipCommand(
            CcipCommandFuseEnterData({
                commandType: CcipCommandType.REFRESH_BALANCE,
                executor: address(foreign),
                chainId: 8453,
                route: CcipRouteConfig({
                    chainSelector: 0,
                    peer: address(0),
                    feeToken: address(0),
                    messageGasLimit: 0,
                    tokenGasLimit: 0,
                    maxFee: 0,
                    enabled: false
                }),
                plasmaVaults: new address[](0),
                vaultsAllowed: false,
                vaultsReplace: false,
                command: _emptyCommand(),
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 0
            })
        );
    }
}
