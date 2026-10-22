// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";

/// @notice IL-8634 (TP-L-06): the supply fuses clamp to the vault balance, so a 1 wei donation made the executor's
///         dust rule (`AmountHasDust` / `AmountBelowSharedDecimals`) reachable by anyone. The fuses now floor the
///         clamped amount to the executor's shared-decimals unit and leave the remainder in the vault.
contract SupplyFuseDustFloorTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint256 internal constant UNIT = 1e12; // 18 local decimals, 6 shared

    MockERC20 internal token;
    CrosschainVaultHarness internal vault;

    // CCIP
    MockCcipRouter internal router;
    CcipCrosschainExecutor internal ccipExecutor;
    CcipCrosschainSupplyFuse internal ccipFuse;

    // Stargate
    MockExecutor internal sgExecutor;
    StargateCrosschainSupplyFuse internal sgFuse;

    function setUp() public {
        token = new MockERC20("Token", "TKN", 18);
        vault = new CrosschainVaultHarness(address(token));

        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        ccipExecutor = new CcipCrosschainExecutor(
            address(router),
            address(routeValidator),
            address(vault),
            address(token),
            keccak256("TKN"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipCrosschainDispatcher dispatcher = new CcipCrosschainDispatcher(
            address(router),
            address(routeValidator),
            address(token),
            keccak256("TKN"),
            6,
            block.chainid,
            CcipRouteConfig({
                chainSelector: 1,
                peer: address(ccipExecutor),
                feeToken: address(0),
                messageGasLimit: 500_000,
                tokenGasLimit: 500_000,
                maxFee: 0,
                enabled: true
            }),
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(address(routeValidator));
        dispatcher.configureVaults(new address[](0), true);
        router.setSelector(address(dispatcher), 2);
        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: 2,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, route);
        routeValidator.registerExecutorRoute(address(ccipExecutor), REMOTE_CHAIN, route);
        vm.prank(address(routeValidator));
        ccipExecutor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(ccipExecutor), 1);

        sgExecutor = new MockExecutor(address(vault), address(token));
        sgExecutor.setDecimals(18, 6);

        ccipFuse = new CcipCrosschainSupplyFuse(MARKET);
        sgFuse = new StargateCrosschainSupplyFuse(MARKET);
        vault.setFuses(address(sgFuse), address(0), address(0), address(0));
        vault.setCcipFuses(address(ccipFuse), address(0));

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(ccipExecutor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(sgExecutor));
        vault.grantSubstrates(MARKET, subs);
    }

    function _enterCcip(uint256 amount_) private {
        vault.enterCcipSupply(
            CcipSupplyFuseEnterData({
                executor: address(ccipExecutor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: amount_,
                maxFee: 0,
                feeToken: address(0),
                gasLimit: 500_000,
                minDelivered: 0
            })
        );
    }

    function _enterSg(uint256 amount_) private {
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(sgExecutor),
                asset: address(token),
                dstChainId: REMOTE_CHAIN,
                amount: amount_,
                minAmountLD: 0,
                options: ""
            })
        );
    }

    // ---------------------------------------------------------------- CCIP

    function testShouldCcipFloorClampedAmountAfterOneWeiDonation() public {
        token.mint(address(vault), 100 * UNIT);
        token.mint(address(0xBAD), 1);
        vm.prank(address(0xBAD));
        token.transfer(address(vault), 1); // griefing donation: balance is now misaligned
        _enterCcip(type(uint256).max);
        assertEq(token.balanceOf(address(vault)), 1, "dust stays in the vault");
        assertEq(ccipExecutor.settledRemoteBalance(REMOTE_CHAIN), 100, "floored amount sent, in SD");
    }

    function testShouldCcipSkipWhenAmountFloorsToZero() public {
        token.mint(address(vault), UNIT - 1);
        _enterCcip(type(uint256).max);
        assertEq(token.balanceOf(address(vault)), UNIT - 1, "nothing moved");
        assertEq(token.balanceOf(address(ccipExecutor)), 0);
        assertEq(ccipExecutor.settledRemoteBalance(REMOTE_CHAIN), 0, "no send");
    }

    function testShouldCcipSendExactMultipleUnchanged() public {
        token.mint(address(vault), 100 * UNIT);
        _enterCcip(40 * UNIT);
        assertEq(token.balanceOf(address(vault)), 60 * UNIT);
        assertEq(ccipExecutor.settledRemoteBalance(REMOTE_CHAIN), 40);
    }

    // ------------------------------------------------------------ Stargate

    function testShouldStargateFloorClampedAmountAfterOneWeiDonation() public {
        token.mint(address(vault), 100 * UNIT + 1);
        _enterSg(type(uint256).max);
        assertEq(token.balanceOf(address(vault)), 1, "dust stays in the vault");
        assertEq(sgExecutor.lastSendAmount(), 100 * UNIT, "floored amount sent");
        assertEq(token.balanceOf(address(sgExecutor)), 100 * UNIT);
    }

    function testShouldStargateSkipWhenAmountFloorsToZero() public {
        token.mint(address(vault), UNIT - 1);
        _enterSg(type(uint256).max);
        assertEq(token.balanceOf(address(vault)), UNIT - 1, "nothing moved");
        assertEq(sgExecutor.lastSendAmount(), 0, "no send");
    }

    function testShouldStargateSendExactMultipleUnchanged() public {
        token.mint(address(vault), 100 * UNIT);
        _enterSg(40 * UNIT);
        assertEq(sgExecutor.lastSendAmount(), 40 * UNIT);
        assertEq(token.balanceOf(address(vault)), 60 * UNIT);
    }
}
