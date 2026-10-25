// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseExitData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @notice IL-9117: the CCIP command fuse rejects a fresh command whose remote vault has no REMOTE_VAULT grant
///         for the target chain (`CrosschainFuseRemoteVaultNotGranted`), for every command that names a vault.
contract CcipCommandFuseRemoteVaultGateTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;

    MockERC20 internal token;
    MockCcipRouter internal router;
    CrosschainVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    CcipCrosschainSupplyFuse internal supplyFuse;
    CcipCrosschainCommandFuse internal commandFuse;
    address internal factory;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        vault = new CrosschainVaultHarness(address(token));
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(vault),
            address(token),
            keccak256("USDC"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            CcipRouteConfig({
                chainSelector: EXECUTOR_SELECTOR,
                peer: address(executor),
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            }),
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        router.setAutoDeliver(false);

        supplyFuse = new CcipCrosschainSupplyFuse(MARKET);
        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(supplyFuse), address(commandFuse));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, substrates);
    }

    uint256 internal constant OTHER_CHAIN = 10;
    address internal constant GRANTED_WORD = address(0xAA11);
    address internal constant UNGRANTED = address(0xBEEF);
    address internal constant MANAGER_WORD = address(0xCC33);

    function _grant(uint256 chainId_, address remoteVault_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(chainId_, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _data(CcipCommandType t_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = t_;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.gasLimit = 2_000_000;
    }

    function _send(uint8 action_, bytes memory actionData_) internal view returns (CcipCommandFuseEnterData memory d) {
        d = _data(CcipCommandType.SEND_COMMAND);
        d.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: action_,
            minExecutionGas: 0,
            actionData: actionData_
        });
    }

    function _expectNotGranted(address remoteVault_) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainSubstrateLib.CrosschainFuseRemoteVaultNotGranted.selector,
                REMOTE_CHAIN,
                remoteVault_
            )
        );
    }

    function _depositData(address v_) internal view returns (CcipCommandFuseEnterData memory) {
        return _send(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(v_, 1e6, 1e6));
    }

    function _redeemData(address v_) internal view returns (CcipCommandFuseEnterData memory) {
        return _send(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(v_, 1e6, 1e6));
    }

    /// @dev The first word (withdraw manager) is the vault granted on the chain, so only the second word decides.
    function _requestSharesData(address v_) internal view returns (CcipCommandFuseEnterData memory) {
        return
            _send(
                uint8(BusinessAction.REQUEST_SHARES),
                CrosschainMessages.encodeRequestSharesAction(GRANTED_WORD, v_, 1e6, 0)
            );
    }

    function _redeemFromRequestData(address v_) internal view returns (CcipCommandFuseEnterData memory) {
        return
            _send(
                uint8(BusinessAction.REDEEM_FROM_REQUEST),
                CrosschainMessages.encodeRedeemFromRequestAction(GRANTED_WORD, v_, 1e6, 1e6, address(0xD00D))
            );
    }

    // ---------------------------------------------------------------- DEPOSIT

    function testShouldRejectDepositToVaultWithoutGrant() public {
        _grant(REMOTE_CHAIN, GRANTED_WORD);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_depositData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectDepositToVaultGrantedOnOtherChain() public {
        _grant(OTHER_CHAIN, UNGRANTED);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_depositData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldSendDepositToGrantedVault() public {
        _grant(REMOTE_CHAIN, UNGRANTED);
        vault.enterCcipCommand(_depositData(UNGRANTED));
        assertEq(router.heldCount(), 1, "sent");
    }

    // ----------------------------------------------------------------- REDEEM

    function testShouldRejectRedeemOfVaultWithoutGrant() public {
        _grant(REMOTE_CHAIN, GRANTED_WORD);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_redeemData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectRedeemOfVaultGrantedOnOtherChain() public {
        _grant(OTHER_CHAIN, UNGRANTED);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_redeemData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldSendRedeemOfGrantedVault() public {
        _grant(REMOTE_CHAIN, UNGRANTED);
        vault.enterCcipCommand(_redeemData(UNGRANTED));
        assertEq(router.heldCount(), 1, "sent");
    }

    // ---------------------------------------------------------- REQUEST_SHARES

    function testShouldRejectRequestSharesForVaultWithoutGrant() public {
        _grant(REMOTE_CHAIN, GRANTED_WORD);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_requestSharesData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectRequestSharesForVaultGrantedOnOtherChain() public {
        _grant(OTHER_CHAIN, UNGRANTED);
        // First word granted on the target chain too: only the second word is the vault.
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_requestSharesData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldSendRequestSharesWhenOnlySecondWordIsGranted() public {
        // The first word (withdraw manager) is NOT granted; the second (vault) is.
        _grant(REMOTE_CHAIN, UNGRANTED);
        vault.enterCcipCommand(_requestSharesData(UNGRANTED));
        assertEq(router.heldCount(), 1, "sent");
    }

    // ----------------------------------------------------- REDEEM_FROM_REQUEST

    function testShouldRejectRedeemFromRequestForVaultWithoutGrant() public {
        _grant(REMOTE_CHAIN, GRANTED_WORD);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_redeemFromRequestData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectRedeemFromRequestForVaultGrantedOnOtherChain() public {
        _grant(OTHER_CHAIN, UNGRANTED);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(_redeemFromRequestData(UNGRANTED));
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldSendRedeemFromRequestWhenOnlySecondWordIsGranted() public {
        _grant(REMOTE_CHAIN, UNGRANTED);
        vault.enterCcipCommand(_redeemFromRequestData(UNGRANTED));
        assertEq(router.heldCount(), 1, "sent");
    }

    // ------------------------------------------------- CREATE_DISPATCHER / UPDATE_VAULTS

    function _vaultList(address first_, address second_) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = first_;
        list[1] = second_;
    }

    function testShouldRejectCreateDispatcherWithUngrantedVaultInList() public {
        _grant(REMOTE_CHAIN, GRANTED_WORD);
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.CREATE_DISPATCHER);
        d.plasmaVaults = _vaultList(GRANTED_WORD, UNGRANTED);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(d);
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectCreateDispatcherWithVaultGrantedOnOtherChain() public {
        _grant(OTHER_CHAIN, UNGRANTED);
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.CREATE_DISPATCHER);
        d.plasmaVaults = _vaultList(UNGRANTED, UNGRANTED);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(d);
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectUpdateVaultsAddingUngrantedVault() public {
        _grant(REMOTE_CHAIN, GRANTED_WORD);
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.UPDATE_VAULTS);
        d.vaultsAllowed = true;
        d.plasmaVaults = _vaultList(GRANTED_WORD, UNGRANTED);
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(d);
        assertEq(router.heldCount(), 0, "nothing sent");
    }

    function testShouldRejectUpdateVaultsAddingVaultGrantedOnOtherChain() public {
        _grant(OTHER_CHAIN, UNGRANTED);
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.UPDATE_VAULTS);
        d.vaultsAllowed = true;
        d.plasmaVaults = new address[](1);
        d.plasmaVaults[0] = UNGRANTED;
        _expectNotGranted(UNGRANTED);
        vault.enterCcipCommand(d);
        assertEq(router.heldCount(), 0, "nothing sent");
    }
}
