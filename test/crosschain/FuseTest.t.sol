// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPlasmaVault} from "../../contracts/interfaces/IPlasmaVault.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {IFuseInstantWithdraw} from "../../contracts/fuses/IFuseInstantWithdraw.sol";
import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData,
    StargateCrosschainSupplyFuseExitData
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {
    CrosschainSubstrateLib,
    CrosschainSubstrate,
    CrosschainSubstrateType
} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {
    CrosschainNavValidationPreHook
} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title FuseTest
/// @notice Fuse layer via a delegatecall harness: supply enter (transfer -> sendAsset) / exit (requestAssets),
///         claim, command variants, balance fuse USD-WAD math vs a mock oracle, the assertion that
///         `StargateCrosschainSupplyFuse` does NOT implement `IFuseInstantWithdraw`, and the pre-hook's fail-closed
///         gate / no-op behavior (plan §5, spec §6).
contract FuseTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant DST_CHAIN = 42161;
    address internal constant REMOTE_VAULT_A = address(0xAA01);
    address internal constant REMOTE_VAULT_B = address(0xBB02);

    MockERC20 internal usdc;
    CrosschainVaultHarness internal vault;
    MockExecutor internal executor;
    MockPriceOracleMiddleware internal oracle;

    StargateCrosschainSupplyFuse internal supplyFuse;
    CrosschainClaimFuse internal claimFuse;
    StargateCrosschainCommandFuse internal commandFuse;
    CrosschainBalanceFuse internal balanceFuse;
    CrosschainNavValidationPreHook internal preHook;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new CrosschainVaultHarness(address(usdc));

        supplyFuse = new StargateCrosschainSupplyFuse(MARKET);
        claimFuse = new CrosschainClaimFuse(MARKET);
        commandFuse = new StargateCrosschainCommandFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        preHook = new CrosschainNavValidationPreHook(MARKET);
        vault.setFuses(address(supplyFuse), address(claimFuse), address(commandFuse), address(balanceFuse));

        executor = new MockExecutor(address(vault), address(usdc)); // MANAGER == vault
        _grant(address(vault), address(executor));

        oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8); // $1.00, 8-decimal feed
        vault.setPriceOracleMiddleware(address(oracle));
    }

    function _grant(address vault_, address executor_) internal {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(executor_);
        CrosschainVaultHarness(vault_).grantSubstrates(MARKET, subs);
    }

    /// @dev Grants the executor plus REMOTE_VAULT substrates in ONE call (grantMarketSubstrates REPLACES the list).
    function _grantWithRemoteVaults(address executor_, uint256 chainId_, address[] memory vaults_) internal {
        bytes32[] memory subs = new bytes32[](1 + vaults_.length);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(executor_);
        for (uint256 i; i < vaults_.length; ++i) {
            subs[1 + i] = CrosschainSubstrateLib.remoteVaultSubstrate(chainId_, vaults_[i]);
        }
        vault.grantSubstrates(MARKET, subs);
    }

    function _vaults1(address vault_) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = vault_;
    }

    /// @dev External wrapper so `vm.expectRevert` can catch reverts from the (inlined) internal library.
    function encodeRemoteVaultSubstrate(uint256 chainId_, address vault_) external pure returns (bytes32) {
        return CrosschainSubstrateLib.remoteVaultSubstrate(chainId_, vault_);
    }

    // ---------------------------------------------------------------------
    // Supply fuse
    // ---------------------------------------------------------------------

    function testShouldSupplyEnterTransferAndSend() public {
        usdc.mint(address(vault), 200e6);
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(executor),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 100e6,
                minAmountLD: 99e6,
                options: ""
            })
        );
        assertEq(usdc.balanceOf(address(executor)), 100e6, "assets transferred to the executor");
        assertEq(executor.lastSendChainId(), DST_CHAIN);
        assertEq(executor.lastSendAmount(), 100e6);
        assertEq(executor.lastSendMin(), 99e6);
    }

    function testShouldSupplyEnterClampToVaultBalance() public {
        usdc.mint(address(vault), 100e6);
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(executor),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 1000e6,
                minAmountLD: 0,
                options: ""
            })
        );
        assertEq(executor.lastSendAmount(), 100e6, "clamped to the vault balance");
    }

    function testShouldSupplyEnterNoopOnZeroAmount() public {
        usdc.mint(address(vault), 100e6);
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(executor),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 0,
                minAmountLD: 0,
                options: ""
            })
        );
        assertEq(usdc.balanceOf(address(executor)), 0, "no transfer on zero amount");
        assertEq(executor.lastSendChainId(), 0, "no send recorded");
    }

    function testShouldSupplyExitRequest() public {
        uint128 nativeDrop = 0.001 ether;
        vault.exitSupply(
            StargateCrosschainSupplyFuseExitData({
                executor: address(executor),
                dstChainId: DST_CHAIN,
                amount: 50e6,
                minReturn: 48e6,
                nativeDrop: nativeDrop,
                options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
            })
        );
        assertEq(executor.lastRequestChainId(), DST_CHAIN);
        assertEq(executor.lastRequestAmount(), 50e6);
        assertEq(executor.lastRequestMin(), 48e6);
        bytes memory expected = OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
            .addExecutorNativeDropOption(nativeDrop, bytes32(uint256(uint160(address(executor)))));
        assertEq(executor.lastRequestOptions(), expected, "recall carries dispatcher native drop");
    }

    function testShouldRejectSupplyEnterForNonGrantedExecutor() public {
        MockExecutor rogue = new MockExecutor(address(vault), address(usdc));
        usdc.mint(address(vault), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseUnsupportedSubstrate.selector, uint8(1), address(rogue)
            )
        );
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(rogue),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 100e6,
                minAmountLD: 0,
                options: ""
            })
        );
    }

    function testShouldRejectSupplyEnterForWrongManager() public {
        MockExecutor foreign = new MockExecutor(address(0xBEEF), address(usdc)); // MANAGER != vault
        _grant(address(vault), address(foreign));
        usdc.mint(address(vault), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainSupplyFuse.CrosschainSupplyFuseExecutorManagerMismatch.selector,
                address(foreign),
                address(0xBEEF)
            )
        );
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(foreign),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 100e6,
                minAmountLD: 0,
                options: ""
            })
        );
    }

    // ---------------------------------------------------------------------
    // Claim fuse
    // ---------------------------------------------------------------------

    function testShouldClaimFromExecutor() public {
        usdc.mint(address(executor), 100e6);
        vault.enterClaim(CrosschainClaimFuseEnterData({executor: address(executor), amount: 60e6}));
        assertEq(usdc.balanceOf(address(vault)), 60e6, "claimed assets returned to the vault");
        assertEq(usdc.balanceOf(address(executor)), 40e6, "executor debited");
        assertEq(executor.lastClaimAmount(), 60e6);
    }

    function testShouldSupplyAndClaimAssetDifferentFromVaultUnderlying() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockExecutor daiExecutor = new MockExecutor(address(vault), address(dai));
        _grant(address(vault), address(daiExecutor));
        // The claim fuse prices what it withdrew so the balance fuse can remove it from the cached
        // market value; a non-underlying executor asset therefore needs its own feed — the same feed the
        // balance fuse already requires to value that executor at all.
        oracle.setPrice(address(dai), 1e8, 8);
        dai.mint(address(vault), 100e18);

        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(daiExecutor),
                asset: address(dai),
                dstChainId: DST_CHAIN,
                amount: 60e18,
                minAmountLD: 59e18,
                options: ""
            })
        );
        vault.enterClaim(CrosschainClaimFuseEnterData({executor: address(daiExecutor), amount: 40e18}));

        assertEq(dai.balanceOf(address(vault)), 80e18, "non-underlying asset returned through claim");
        assertEq(dai.balanceOf(address(daiExecutor)), 20e18, "executor debited in its own asset");
        assertEq(daiExecutor.lastClaimAmount(), 40e18);
    }

    // ---------------------------------------------------------------------
    // Command fuse variants
    // ---------------------------------------------------------------------

    function _cmd(StargateCrosschainCommandType t_)
        internal
        view
        returns (StargateCrosschainCommandFuseEnterData memory d)
    {
        d.commandType = t_;
        d.executor = address(executor);
        d.chainId = DST_CHAIN;
    }

    function testShouldForwardRegisterChain() public {
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.REGISTER_CHAIN);
        d.eid = 30110;
        vault.enterCommand(d);
        assertEq(executor.lastRegisterChainId(), DST_CHAIN);
        assertEq(executor.lastRegisterEid(), 30110);
    }

    event CrosschainCommandFuseEnter(address version, address executor, uint8 commandType, uint256 chainId);

    function testShouldEmitZeroChainIdForCancelDispatcherRequest() public {
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.CANCEL_DISPATCHER_REQUEST);
        assertTrue(d.chainId != 0, "precondition: non-zero chainId");
        vm.expectEmit(false, false, false, true, address(vault));
        emit CrosschainCommandFuseEnter(
            commandFuse.VERSION(), address(executor), uint8(StargateCrosschainCommandType.CANCEL_DISPATCHER_REQUEST), 0
        );
        vault.enterCommand(d);

        // A non-cancel command still reports its chainId.
        d = _cmd(StargateCrosschainCommandType.CREATE_DISPATCHER);
        vm.expectEmit(false, false, false, true, address(vault));
        emit CrosschainCommandFuseEnter(
            commandFuse.VERSION(), address(executor), uint8(StargateCrosschainCommandType.CREATE_DISPATCHER), DST_CHAIN
        );
        vault.enterCommand(d);
    }

    function testShouldForwardCreateDispatcher() public {
        // Empty allowlist: nothing to validate against REMOTE_VAULT substrates.
        vault.enterCommand(_cmd(StargateCrosschainCommandType.CREATE_DISPATCHER));
        assertEq(executor.lastCreateChainId(), DST_CHAIN);
    }

    function testShouldForwardCreateDispatcherWithGrantedVaults() public {
        address[] memory vaults = new address[](2);
        vaults[0] = REMOTE_VAULT_A;
        vaults[1] = REMOTE_VAULT_B;
        _grantWithRemoteVaults(address(executor), DST_CHAIN, vaults);
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.CREATE_DISPATCHER);
        d.plasmaVaults = vaults;
        vault.enterCommand(d);
        assertEq(executor.lastCreateChainId(), DST_CHAIN);
    }

    function testShouldForwardUpdatePlasmaVaults() public {
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        d.plasmaVaults = _vaults1(REMOTE_VAULT_A);
        vault.enterCommand(d);
        assertEq(executor.lastUpdateChainId(), DST_CHAIN);
    }

    function testShouldForwardSendCommand() public {
        // Action NONE carries no vault target — validation is left to the executor/dispatcher.
        vault.enterCommand(_cmd(StargateCrosschainCommandType.SEND_COMMAND));
        assertEq(executor.lastCommandChainId(), DST_CHAIN);
    }

    function testShouldForwardRetryAndCancelCommand() public {
        vault.enterCommand(_cmd(StargateCrosschainCommandType.RETRY_COMMAND));
        assertEq(executor.lastRetryChainId(), DST_CHAIN);
        vault.enterCommand(_cmd(StargateCrosschainCommandType.CANCEL_COMMAND));
        assertEq(executor.lastCancelCommandChainId(), DST_CHAIN);
    }

    /// @dev IL-8600: a retry replays the stored command, so a stored DEPOSIT is gated like a fresh SEND_COMMAND.
    function testShouldGateRetryOfDepositLikeSendCommand() public {
        executor.setActiveCommandAction(uint8(BusinessAction.DEPOSIT));
        executor.setActiveCommandTarget(REMOTE_VAULT_A);
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));

        // NAV fail-closed: the live getBalance() read reverts and nothing is forwarded.
        executor.setBalanceReverts(true);
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.enterCommand(_cmd(StargateCrosschainCommandType.RETRY_COMMAND));
        assertEq(executor.lastRetryChainId(), 0, "retry not forwarded while NAV is fail-closed");

        // NAV healthy: the retry proceeds and performs exactly one live NAV read (new-exposure path).
        executor.setBalanceReverts(false);
        vm.expectCall(address(executor), abi.encodeWithSelector(MockExecutor.getBalance.selector), 1);
        vault.enterCommand(_cmd(StargateCrosschainCommandType.RETRY_COMMAND));
        assertEq(executor.lastRetryChainId(), DST_CHAIN);

        // A blocked destination chain refuses the retry of a DEPOSIT (IL-8580 parity with SEND_COMMAND).
        executor.setChainBlocked(DST_CHAIN, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseChainBlocked.selector, address(executor), DST_CHAIN
            )
        );
        vault.enterCommand(_cmd(StargateCrosschainCommandType.RETRY_COMMAND));
    }

    function testShouldTreatRetryOfRedeemAsRecovery() public {
        executor.setActiveCommandAction(uint8(BusinessAction.REDEEM));
        executor.setBalanceReverts(true); // fail-closed NAV must not block a recovery
        executor.setChainBlocked(DST_CHAIN, true); // nor a blocked chain
        vm.expectCall(address(executor), abi.encodeWithSelector(MockExecutor.getBalance.selector), 0);
        vault.enterCommand(_cmd(StargateCrosschainCommandType.RETRY_COMMAND));
        assertEq(executor.lastRetryChainId(), DST_CHAIN, "redeem retry forwarded without a NAV read");
    }

    function testShouldRejectUndefinedCommandType() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseUnsupportedCommandType.selector, uint8(0)
            )
        );
        vault.enterCommand(_cmd(StargateCrosschainCommandType.UNDEFINED));
    }

    function testShouldRejectCommandForNonGrantedExecutor() public {
        MockExecutor rogue = new MockExecutor(address(vault), address(usdc));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.executor = address(rogue);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseUnsupportedSubstrate.selector, uint8(1), address(rogue)
            )
        );
        vault.enterCommand(d);
    }

    // ---------------------------------------------------------------------
    // REMOTE_VAULT substrates (chainId-bound remote PlasmaVault whitelist)
    // ---------------------------------------------------------------------

    function testShouldRoundTripRemoteVaultSubstrate() public pure {
        bytes32 encoded = CrosschainSubstrateLib.remoteVaultSubstrate(DST_CHAIN, REMOTE_VAULT_A);
        CrosschainSubstrate memory decoded = CrosschainSubstrateLib.bytes32ToSubstrate(encoded);
        assertEq(uint8(decoded.substrateType), uint8(CrosschainSubstrateType.REMOTE_VAULT), "type");
        assertEq(decoded.chainId, DST_CHAIN, "chainId");
        assertEq(decoded.substrateAddress, REMOTE_VAULT_A, "address");
    }

    function testShouldRoundTripExecutorSubstrate() public view {
        bytes32 encoded = CrosschainSubstrateLib.executorSubstrate(address(executor));
        CrosschainSubstrate memory decoded = CrosschainSubstrateLib.bytes32ToSubstrate(encoded);
        assertEq(uint8(decoded.substrateType), uint8(CrosschainSubstrateType.EXECUTOR), "type");
        assertEq(decoded.chainId, 0, "executor substrate carries no chainId");
        assertEq(decoded.substrateAddress, address(executor), "address");
    }

    function testShouldRevertRemoteVaultSubstrateOnChainIdOverflow() public {
        uint256 tooBig = uint256(1) << 88; // MAX_SUBSTRATE_CHAIN_ID + 1
        vm.expectRevert(abi.encodeWithSelector(CrosschainSubstrateLib.CrosschainFuseChainIdOverflow.selector, tooBig));
        this.encodeRemoteVaultSubstrate(tooBig, REMOTE_VAULT_A);
    }

    function testShouldRejectCreateDispatcherForNonGrantedVault() public {
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.CREATE_DISPATCHER);
        d.plasmaVaults = _vaults1(REMOTE_VAULT_A); // never granted
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_A
            )
        );
        vault.enterCommand(d);
        assertEq(executor.lastCreateChainId(), 0, "createDispatcher must not be forwarded");
    }

    function testShouldRejectCreateDispatcherWhenOneOfVaultsNotGranted() public {
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        address[] memory vaults = new address[](2);
        vaults[0] = REMOTE_VAULT_A; // granted
        vaults[1] = REMOTE_VAULT_B; // NOT granted
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.CREATE_DISPATCHER);
        d.plasmaVaults = vaults;
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_B
            )
        );
        vault.enterCommand(d);
    }

    function testShouldRejectUpdatePlasmaVaultsForNonGrantedVault() public {
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        d.plasmaVaults = _vaults1(REMOTE_VAULT_B);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_B
            )
        );
        vault.enterCommand(d);
        assertEq(executor.lastUpdateChainId(), 0, "updatePlasmaVaults must not be forwarded");
    }

    function testShouldRejectVaultGrantedForDifferentChainId() public {
        // Vault granted for chain 10, targeted on DST_CHAIN — the grant is chainId-bound.
        _grantWithRemoteVaults(address(executor), 10, _vaults1(REMOTE_VAULT_A));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        d.plasmaVaults = _vaults1(REMOTE_VAULT_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_A
            )
        );
        vault.enterCommand(d);
    }

    function testShouldForwardSendCommandDepositForGrantedVault() public {
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.DEPOSIT);
        d.command.actionData = CrosschainMessages.encodeDepositAction(REMOTE_VAULT_A, 100e6, 99e6);
        vault.enterCommand(d);
        assertEq(executor.lastCommandChainId(), DST_CHAIN);
    }

    function testShouldRevertDepositCommandOnBlockedChain() public {
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        executor.setChainBlocked(DST_CHAIN, true);
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.DEPOSIT);
        d.command.actionData = CrosschainMessages.encodeDepositAction(REMOTE_VAULT_A, 100e6, 99e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseChainBlocked.selector, address(executor), DST_CHAIN
            )
        );
        vault.enterCommand(d);

        StargateCrosschainCommandFuseEnterData memory u = _cmd(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        u.plasmaVaults = _vaults1(REMOTE_VAULT_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseChainBlocked.selector, address(executor), DST_CHAIN
            )
        );
        vault.enterCommand(u);
    }

    function testShouldAllowRedeemCommandOnBlockedChain() public {
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        executor.setChainBlocked(DST_CHAIN, true);
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.REDEEM);
        d.command.actionData = CrosschainMessages.encodeRedeemAction(REMOTE_VAULT_A, 50e6, 49e6);
        vault.enterCommand(d);
        assertEq(executor.lastCommandChainId(), DST_CHAIN);
    }

    function testShouldAllowEmptyVaultListOnBlockedChain() public {
        executor.setChainBlocked(DST_CHAIN, true);
        StargateCrosschainCommandFuseEnterData memory u = _cmd(StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS);
        u.plasmaVaults = new address[](0);
        vault.enterCommand(u);
    }

    function testShouldRejectSendCommandDepositForNonGrantedVault() public {
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.DEPOSIT);
        d.command.actionData = CrosschainMessages.encodeDepositAction(REMOTE_VAULT_A, 100e6, 99e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_A
            )
        );
        vault.enterCommand(d);
        assertEq(executor.lastCommandChainId(), 0, "sendCommandToDispatcher must not be forwarded");
    }

    function testShouldRejectSendCommandRedeemForNonGrantedVault() public {
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.REDEEM);
        d.command.actionData = CrosschainMessages.encodeRedeemAction(REMOTE_VAULT_B, 50e6, 49e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_B
            )
        );
        vault.enterCommand(d);
    }

    function testShouldValidateRequestSharesTargetVault() public {
        // REQUEST_SHARES validates the PLASMA VAULT (2nd tuple element), not the withdraw manager.
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.REQUEST_SHARES);
        d.command.actionData = CrosschainMessages.encodeRequestSharesAction(address(0x1111), REMOTE_VAULT_A, 10e6, 0);
        vault.enterCommand(d);
        assertEq(executor.lastCommandChainId(), DST_CHAIN);

        d.command.actionData = CrosschainMessages.encodeRequestSharesAction(address(0x1111), REMOTE_VAULT_B, 10e6, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_B
            )
        );
        vault.enterCommand(d);
    }

    function testShouldValidateRedeemFromRequestTargetVault() public {
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.command.action = uint8(BusinessAction.REDEEM_FROM_REQUEST);
        d.command.actionData = CrosschainMessages.encodeRedeemFromRequestAction(
            address(0x1111), REMOTE_VAULT_A, 10e6, 9e6, address(0x2222)
        );
        vault.enterCommand(d);
        assertEq(executor.lastCommandChainId(), DST_CHAIN);

        d.command.actionData = CrosschainMessages.encodeRedeemFromRequestAction(
            address(0x1111), REMOTE_VAULT_B, 10e6, 9e6, address(0x2222)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector, DST_CHAIN, REMOTE_VAULT_B
            )
        );
        vault.enterCommand(d);
    }

    // ---------------------------------------------------------------------
    // Balance fuse USD-WAD math
    // ---------------------------------------------------------------------

    function testShouldReturnUsdWadBalance() public {
        executor.setBalance(100e6); // 100 USDC in underlying units
        // 100 USDC at $1.00 == $100 == 100 * 1e18 WAD.
        assertEq(vault.balanceOf(), 100e18, "USD-WAD valuation");
    }

    function testShouldSumMultipleExecutors() public {
        MockExecutor executor2 = new MockExecutor(address(vault), address(usdc));
        // Grant both executors in one call (grantMarketSubstrates REPLACES the list).
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(executor2));
        vault.grantSubstrates(MARKET, subs);

        executor.setBalance(100e6);
        executor2.setBalance(50e6);
        assertEq(vault.balanceOf(), 150e18, "sum across granted executors");
    }

    function testShouldIgnoreRemoteVaultSubstratesInBalance() public {
        // Executor + a REMOTE_VAULT substrate granted together: NAV sums the executor only.
        _grantWithRemoteVaults(address(executor), DST_CHAIN, _vaults1(REMOTE_VAULT_A));
        executor.setBalance(100e6);
        assertEq(vault.balanceOf(), 100e18, "REMOTE_VAULT substrates carry no local balance");
    }

    function testShouldReturnZeroBalanceWhenOnlyRemoteVaultsGranted() public {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.remoteVaultSubstrate(DST_CHAIN, REMOTE_VAULT_A);
        vault.grantSubstrates(MARKET, subs);
        assertEq(vault.balanceOf(), 0, "no executor granted -> zero NAV");
    }

    function testShouldReturnZeroWhenNoExecutorGranted() public {
        CrosschainVaultHarness fresh = new CrosschainVaultHarness(address(usdc));
        fresh.setFuses(address(supplyFuse), address(claimFuse), address(commandFuse), address(balanceFuse));
        fresh.setPriceOracleMiddleware(address(oracle));
        assertEq(fresh.balanceOf(), 0, "no crosschain exposure -> zero");
    }

    function testShouldRevertBalanceWithoutPriceOracle() public {
        CrosschainVaultHarness fresh = new CrosschainVaultHarness(address(usdc));
        fresh.setFuses(address(supplyFuse), address(claimFuse), address(commandFuse), address(balanceFuse));
        MockExecutor exec = new MockExecutor(address(fresh), address(usdc));
        _grant(address(fresh), address(exec));
        exec.setBalance(100e6);
        // Non-zero balance but no oracle middleware configured -> reverts.
        vm.expectRevert(CrosschainBalanceFuse.CrosschainBalanceFuseInvalidPriceOracleMiddleware.selector);
        fresh.balanceOf();
    }

    // ---------------------------------------------------------------------
    // Executor / vault asset consistency (§9 P2)
    // ---------------------------------------------------------------------

    function testShouldRejectSupplyEnterWhenPassedAssetDiffersFromExecutorAsset() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockExecutor daiExecutor = new MockExecutor(address(vault), address(dai)); // handles DAI
        _grant(address(vault), address(daiExecutor));
        usdc.mint(address(vault), 100e6);
        // Passing USDC while the executor handles DAI must fail the per-call denomination check.
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseExecutorAssetMismatch.selector,
                address(daiExecutor),
                address(usdc),
                address(dai)
            )
        );
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(daiExecutor),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 100e6,
                minAmountLD: 0,
                options: ""
            })
        );
    }

    function testShouldSupplyEnterAssetDifferentFromVaultUnderlying() public {
        // The bridged asset follows the executor's ASSET() and may differ from the vault underlying (USDC).
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockExecutor daiExecutor = new MockExecutor(address(vault), address(dai));
        _grant(address(vault), address(daiExecutor));
        dai.mint(address(vault), 100e18);
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(daiExecutor),
                asset: address(dai),
                dstChainId: DST_CHAIN,
                amount: 60e18,
                minAmountLD: 59e18,
                options: ""
            })
        );
        assertEq(dai.balanceOf(address(daiExecutor)), 60e18, "DAI transferred to the executor");
        assertEq(daiExecutor.lastSendAmount(), 60e18);
        assertEq(daiExecutor.lastSendChainId(), DST_CHAIN);
    }

    function testShouldRejectClaimForCodelessExecutor() public {
        address codelessExecutor = address(0xC1A1);
        _grant(address(vault), codelessExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainSubstrateLib.CrosschainFuseExecutorNoCode.selector, codelessExecutor)
        );
        vault.enterClaim(CrosschainClaimFuseEnterData({executor: codelessExecutor, amount: 10e6}));
    }

    function testShouldAllowCommandForMismatchedAssetExecutor() public {
        // The command fuse deliberately does NOT enforce asset denomination — command operations move
        // no assets; the supply/claim/balance fuses keep enforcing it.
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockExecutor otherAsset = new MockExecutor(address(vault), address(dai));
        _grant(address(vault), address(otherAsset));
        StargateCrosschainCommandFuseEnterData memory d = _cmd(StargateCrosschainCommandType.SEND_COMMAND);
        d.executor = address(otherAsset);
        vault.enterCommand(d);
        assertEq(otherAsset.lastCommandChainId(), DST_CHAIN, "command forwarded despite asset mismatch");
    }

    function testShouldPriceExecutorInItsOwnAsset() public {
        // Executor denominated in DAI (18 decimals, $2.00) while the vault underlying is USDC.
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockExecutor daiExecutor = new MockExecutor(address(vault), address(dai));
        _grant(address(vault), address(daiExecutor));
        oracle.setPrice(address(dai), 2e8, 8);
        daiExecutor.setBalance(100e18); // 100 DAI
        // 100 DAI at $2.00 == $200 == 200 * 1e18 WAD.
        assertEq(vault.balanceOf(), 200e18, "balance priced with the executor asset feed and decimals");
    }

    function testShouldSumExecutorsWithDifferentAssets() public {
        // USDC executor (6 decimals, $1.00) + DAI executor (18 decimals, $2.00) granted together.
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockExecutor daiExecutor = new MockExecutor(address(vault), address(dai));
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(daiExecutor));
        vault.grantSubstrates(MARKET, subs);
        oracle.setPrice(address(dai), 2e8, 8);
        executor.setBalance(100e6); // 100 USDC -> $100
        daiExecutor.setBalance(50e18); // 50 DAI -> $100
        assertEq(vault.balanceOf(), 200e18, "sum of per-asset USD valuations");
    }

    function testShouldFailClosedBalanceForCodelessExecutorSubstrate() public {
        // Grant an EXECUTOR substrate pointing at an address with no code.
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(0xC0DE1E55));
        vault.grantSubstrates(MARKET, subs);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainSubstrateLib.CrosschainFuseExecutorNoCode.selector, address(0xC0DE1E55))
        );
        vault.balanceOf();
    }

    function testShouldStillSumMultipleValidExecutorsAfterAssetChecks() public {
        MockExecutor executor2 = new MockExecutor(address(vault), address(usdc));
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(executor2));
        vault.grantSubstrates(MARKET, subs);
        executor.setBalance(100e6);
        executor2.setBalance(50e6);
        assertEq(vault.balanceOf(), 150e18, "correctly configured executors still sum");
    }

    // ---------------------------------------------------------------------
    // Instant-withdraw prohibition
    // ---------------------------------------------------------------------

    function testShouldNotImplementInstantWithdraw() public {
        // The supply fuse deliberately omits IFuseInstantWithdraw: calling its selector finds no function.
        (bool ok,) = address(supplyFuse)
            .call(abi.encodeWithSelector(IFuseInstantWithdraw.instantWithdraw.selector, new bytes32[](0)));
        assertFalse(ok, "StargateCrosschainSupplyFuse must NOT implement instantWithdraw");
    }

    // ---------------------------------------------------------------------
    // NAV validation pre-hook
    // ---------------------------------------------------------------------

    function testShouldPassPreHookWhenFresh() public {
        executor.setBalance(100e6);
        vault.runPreHook(address(preHook), bytes4(0x12345678)); // no revert -> fresh
    }

    function testShouldRevertPreHookWhenExecutorBlocked() public {
        executor.setBalanceReverts(true); // getBalance() reverts (stale/blocked chain)
        vm.expectRevert(); // the pre-hook propagates the fail-closed revert
        vault.runPreHook(address(preHook), bytes4(0x12345678));
    }

    /// @dev IL-8639: non-reverting best-effort health view mirroring the hook's executor walk.
    function testShouldReportNavHealthyWhenExecutorFresh() public {
        executor.setBalance(100e6);
        assertTrue(preHook.isNavHealthy(address(vault)));
    }

    function testShouldReportNavUnhealthyWhenExecutorFailClosed() public {
        executor.setBalanceReverts(true);
        assertFalse(preHook.isNavHealthy(address(vault)));
        executor.setBalanceReverts(false);
        assertTrue(preHook.isNavHealthy(address(vault)));
    }

    function testShouldReportNavHealthyWithoutExecutorSubstrates() public {
        CrosschainVaultHarness fresh = new CrosschainVaultHarness(address(usdc));
        assertTrue(preHook.isNavHealthy(address(fresh)));
    }

    function testShouldReportNavUnhealthyOnManagerMismatchAndMalformedSubstrate() public {
        executor.setManager(address(0xBEEF));
        assertFalse(preHook.isNavHealthy(address(vault)));
        executor.setManager(address(vault));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = bytes32((uint256(3) << 248) | uint256(uint160(address(executor))));
        vault.grantSubstrates(MARKET, subs);
        assertFalse(preHook.isNavHealthy(address(vault)));
        assertFalse(preHook.isNavHealthy(address(0xDEAD))); // not a vault: the substrate read fails, never reverts
    }

    function testShouldLetExecuteReachActionLevelRecoveryGateWhenNavBlocked() public {
        executor.setBalanceReverts(true);
        vault.runPreHook(address(preHook), IPlasmaVault.execute.selector);
    }

    /// @dev IL-8258: a fail-closed executor must not freeze the refresh of the vault's other markets.
    function testShouldNotGateUpdateMarketsBalancesWhenNavBlocked() public {
        executor.setBalanceReverts(true);
        vault.runPreHook(address(preHook), IPlasmaVault.updateMarketsBalances.selector);
    }

    function testShouldPreserveCachedBalanceDuringApprovedRecovery() public {
        vault.setCachedMarketBalance(MARKET, 100e6);
        executor.setBalanceReverts(true);
        vault.exitSupply(
            StargateCrosschainSupplyFuseExitData({
                executor: address(executor),
                dstChainId: DST_CHAIN,
                amount: 10e6,
                minReturn: 0,
                nativeDrop: 0,
                options: ""
            })
        );
        assertEq(vault.balanceOf(), 100e18, "recovery preserves the cached market NAV");
    }

    /// @dev Audit H-1. A claim during a fail-closed window moves assets from the executor into the
    ///      vault's own balance. `PlasmaVault.totalAssets()` is `balanceOf(underlying) + Σ markets`, so if
    ///      the crosschain market kept its full pre-claim cached value those assets would be counted
    ///      twice — inflating share price and letting `updateMarketsBalances` realize a phantom gain that
    ///      mints performance fee shares. The cached fallback must net out what was withdrawn.
    function testShouldNotDoubleCountClaimedAssetsDuringRecovery() public {
        vault.setCachedMarketBalance(MARKET, 100e6); // 100 USDC cached in the crosschain market
        usdc.mint(address(executor), 100e6);
        executor.setBalanceReverts(true); // live NAV fail-closed

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 marketValueUsd =
            vault.enterClaimThenBalanceOf(CrosschainClaimFuseEnterData({executor: address(executor), amount: 40e6}));
        uint256 claimed = usdc.balanceOf(address(vault)) - vaultBefore;
        assertEq(claimed, 40e6, "assets really moved into the vault");

        // 100 USDC cached - 40 USDC now held directly by the vault = 60 USDC of remaining remote NAV.
        assertEq(marketValueUsd, 60e18, "claimed assets removed from the cached market value");

        // Total exposure is unchanged: what the market still reports plus what the vault now holds.
        assertEq(marketValueUsd + claimed * 1e12, 100e18, "no value invented, none lost");
    }

    /// @dev Audit C-01. A claim that moves nothing is not a recovery action and must not gain access to
    ///      the stale-cache fallback while live executor NAV remains fail-closed.
    function testShouldRejectCachedFallbackWhenClaimMovesNoAssets() public {
        vault.setCachedMarketBalance(MARKET, 100e6);
        executor.setBalanceReverts(true);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.enterClaimThenBalanceOf(CrosschainClaimFuseEnterData({executor: address(executor), amount: 40e6}));
        assertEq(usdc.balanceOf(address(vault)), vaultBefore, "nothing was actually claimed");
    }

    /// @dev Audit C-01. Moving tokens is insufficient if their oracle value is zero: without a positive
    ///      correction the cached market value cannot be reconciled safely. The fail-closed post-update
    ///      must revert the whole batch, including the executor transfer.
    function testShouldRejectCachedFallbackWhenClaimedValueIsZero() public {
        vault.setCachedMarketBalance(MARKET, 100e6);
        usdc.mint(address(executor), 1);
        // A nonzero oracle answer which nevertheless rounds one smallest USDC unit down to zero WAD.
        oracle.setPrice(address(usdc), 1, 18);
        executor.setBalanceReverts(true);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.enterClaimThenBalanceOf(CrosschainClaimFuseEnterData({executor: address(executor), amount: 1}));

        assertEq(usdc.balanceOf(address(vault)), 0, "reverted batch cannot retain the claimed tokens");
        assertEq(usdc.balanceOf(address(executor)), 1, "executor transfer rolled back with the batch");
    }

    /// @dev Audit M-5. The Stargate fuses must refuse an executor that does not speak the Stargate
    ///      transport, symmetrically with the CCIP fuses' `transportKind()` assertion.
    function testShouldRejectExecutorThatIsNotStargateTransport() public {
        executor.setStargatePool(address(0)); // simulate a cross-wired (e.g. CCIP) executor
        usdc.mint(address(vault), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainSupplyFuse.CrosschainSupplyFuseWrongTransport.selector, address(executor)
            )
        );
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(executor),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 10e6,
                minAmountLD: 0,
                options: ""
            })
        );

        StargateCrosschainCommandFuseEnterData memory d;
        d.commandType = StargateCrosschainCommandType.REGISTER_CHAIN;
        d.executor = address(executor);
        d.chainId = DST_CHAIN;
        d.eid = 30110;
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateCrosschainCommandFuse.CrosschainCommandFuseWrongTransport.selector, address(executor)
            )
        );
        vault.enterCommand(d);
    }

    function testShouldBlockNewRemoteSupplyWhenNavBlocked() public {
        usdc.mint(address(vault), 10e6);
        executor.setBalanceReverts(true);
        vm.expectRevert();
        vault.enterSupply(
            StargateCrosschainSupplyFuseEnterData({
                executor: address(executor),
                asset: address(usdc),
                dstChainId: DST_CHAIN,
                amount: 10e6,
                minAmountLD: 0,
                options: ""
            })
        );
        assertEq(usdc.balanceOf(address(vault)), 10e6, "blocked before value transfer");
    }

    function testShouldNoopPreHookWhenNoExecutorGranted() public {
        CrosschainVaultHarness fresh = new CrosschainVaultHarness(address(usdc));
        fresh.runPreHook(address(preHook), bytes4(0x12345678)); // no executor substrate -> no-op
    }

    function testShouldSkipRemoteVaultSubstratesInPreHook() public {
        // Executor blocked would revert, but here only a REMOTE_VAULT substrate is granted -> no-op.
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.remoteVaultSubstrate(DST_CHAIN, REMOTE_VAULT_A);
        vault.grantSubstrates(MARKET, subs);
        vault.runPreHook(address(preHook), bytes4(0x12345678));
    }

    function testShouldFailClosedPreHookForUndefinedSubstrate() public {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = bytes32(uint256(uint160(address(executor))));
        vault.grantSubstrates(MARKET, subs);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainNavValidationPreHook.CrosschainNavValidationPreHookInvalidExecutorSubstrate.selector,
                uint8(CrosschainSubstrateType.UNDEFINED),
                address(executor)
            )
        );
        vault.runPreHook(address(preHook), bytes4(0x12345678));
    }

    function testShouldRejectOutOfRangeSubstrateTypeWithCustomError() public {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = bytes32((uint256(3) << 248) | uint256(uint160(address(executor))));
        vault.grantSubstrates(MARKET, subs);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainSubstrateLib.CrosschainFuseInvalidSubstrateType.selector, uint256(3))
        );
        vault.runPreHook(address(preHook), bytes4(0x12345678));
    }
}
