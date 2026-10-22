// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {AuditToken} from "./CcipAuditRemediationTest.t.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainMessages, OutboundTransfer} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";

interface IRescueHost {
    function scheduleRescue(address target_, uint256 value_, bytes calldata callData_) external returns (uint256);
    function executeRescue(uint256 rescueId_, bytes calldata callData_) external;
}

interface IMintable is IERC20 {
    function mint(address to_, uint256 amount_) external;
}

/// @title RescueNonWorseningBase
/// @notice IL-8640 (TP-L-12): the post-rescue ASSET floor is non-worsening. A rescue may never lower a sufficient
///         balance below the tracked ledger and may never lower an already-insufficient balance further, but
///         rescues that do not touch ASSET keep working while the host is below its ledger.
/// @dev Each concrete suite funds its host with an exactly backed ledger of `LEDGER` (LD) and supplies the
///      host-specific revert. Re-injection: restoring the absolute rule (`balance >= required`) fails the
///      `testBelowLedger*` tests.
abstract contract RescueNonWorseningBase is Test {
    uint256 internal constant DELAY = 3 days;
    address internal constant SINK = address(0xDEAD);
    address internal constant EOA = address(0xCAFE);

    function _host() internal view virtual returns (address);
    function _asset() internal view virtual returns (IMintable);
    function _rescueAdmin() internal view virtual returns (address);
    /// @dev Tracked ledger in LD that the host's setup leaves exactly backed.
    function _ledger() internal view virtual returns (uint256);
    /// @dev The host-specific revert for a post-rescue `balance` against the effective `required` floor.
    function _violation(uint256 balance_, uint256 required_) internal view virtual returns (bytes memory);

    function _check() internal {
        assertEq(_asset().balanceOf(_host()), _ledger(), "setup: ledger exactly backed");
        vm.deal(_host(), 10 ether);
    }

    function _rescue(address target_, uint256 value_, bytes memory callData_, bytes memory err_) internal {
        vm.prank(_rescueAdmin());
        uint256 id = IRescueHost(_host()).scheduleRescue(target_, value_, callData_);
        vm.warp(block.timestamp + DELAY);
        vm.prank(_rescueAdmin());
        if (err_.length > 0) vm.expectRevert(err_);
        IRescueHost(_host()).executeRescue(id, callData_);
    }

    /// @dev Put the host below its ledger the way an issuer-side adjustment would (balance removed, ledger kept).
    function _destroy(uint256 amount_) internal {
        vm.prank(_host());
        _asset().transfer(SINK, amount_);
    }

    function testBelowLedgerUnrelatedTokenSweepSucceeds() public {
        _check();
        _destroy(7);
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        other.mint(_host(), 5e6);
        _rescue(address(other), 0, abi.encodeCall(IERC20.transfer, (_rescueAdmin(), 5e6)), "");
        assertEq(other.balanceOf(_rescueAdmin()), 5e6, "unrelated token swept while ASSET is below the ledger");
        assertEq(_asset().balanceOf(_host()), _ledger() - 7, "ASSET untouched");
    }

    function testBelowLedgerNativeRecoverySucceeds() public {
        _check();
        _destroy(7);
        _rescue(EOA, 1 ether, "", "");
        assertEq(EOA.balance, 1 ether, "native balance recovered while ASSET is below the ledger");
    }

    function testBelowLedgerShareRecoverySucceeds() public {
        _check();
        _destroy(7);
        MockRemoteVault shares = new MockRemoteVault(_asset(), "Vault", "VLT");
        _asset().mint(address(this), 10);
        _asset().approve(address(shares), 10);
        shares.deposit(10, _host());
        _rescue(address(shares), 0, abi.encodeCall(IERC20.transfer, (_rescueAdmin(), 10)), "");
        assertEq(shares.balanceOf(_rescueAdmin()), 10, "ERC-4626 shares recovered while ASSET is below the ledger");
    }

    function testBelowLedgerRescueLoweringAssetFurtherReverts() public {
        _check();
        _destroy(7);
        uint256 balance = _ledger() - 7;
        // required collapses to the pre-call balance, so even 1 wei further is rejected.
        _rescue(
            address(_asset()),
            0,
            abi.encodeCall(IERC20.transfer, (_rescueAdmin(), 1)),
            _violation(balance - 1, balance)
        );
        assertEq(_asset().balanceOf(_host()), balance, "nothing moved");
    }

    function testBelowLedgerAssetRescueThatKeepsBalanceSucceeds() public {
        _check();
        _destroy(7);
        // Donation remedy stays available: topping the host up is never a worsening.
        _asset().mint(_host(), 7);
        assertEq(_asset().balanceOf(_host()), _ledger(), "donation restores the backing");
        _asset().mint(_host(), 3);
        _rescue(address(_asset()), 0, abi.encodeCall(IERC20.transfer, (_rescueAdmin(), 3)), "");
        assertEq(_asset().balanceOf(_rescueAdmin()), 3, "surplus above the ledger rescued");
    }

    function testSufficientBalanceDroppingBelowLedgerReverts() public {
        _check();
        _asset().mint(_host(), 5); // 5 wei untracked surplus
        _rescue(
            address(_asset()),
            0,
            abi.encodeCall(IERC20.transfer, (_rescueAdmin(), 6)),
            _violation(_ledger() - 1, _ledger())
        );
    }

    function testSufficientBalanceKeptAboveLedgerSucceeds() public {
        _check();
        _asset().mint(_host(), 5);
        _rescue(address(_asset()), 0, abi.encodeCall(IERC20.transfer, (_rescueAdmin(), 5)), "");
        assertEq(_asset().balanceOf(_host()), _ledger(), "ledger stays backed");
    }
}

/// @notice Stargate executor host (`StargateCrosschainExecutor._afterRescueExecuted`).
contract StargateExecutorRescueNonWorseningTest is CrosschainTestBase, RescueNonWorseningBase {
    function setUp() public {
        _baseSetUp();
        _readyAndFundIdle40();
    }

    function _host() internal view override returns (address) {
        return address(executor);
    }

    function _asset() internal view override returns (IMintable) {
        return IMintable(address(usdc));
    }

    function _rescueAdmin() internal view override returns (address) {
        return admin;
    }

    function _ledger() internal pure override returns (uint256) {
        return 40e6;
    }

    function _violation(uint256 balance_, uint256 required_) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(CrosschainErrors.RescueLedgerInvariantViolation.selector, balance_, required_);
    }
}

/// @notice Stargate dispatcher host (`StargateCrosschainDispatcher._afterRescueExecuted`).
contract StargateDispatcherRescueNonWorseningTest is RescueNonWorseningBase {
    using OptionsBuilder for bytes;

    uint256 internal constant EXECUTOR_EID = 30101;
    address internal constant ADMIN = address(0xADADAD);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    address internal dispatcher;

    function setUp() public {
        vm.chainId(42161);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](2);
        enforced[0] = EnforcedOptionParam({
            eid: uint32(EXECUTOR_EID),
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforced[1] = EnforcedOptionParam({
            eid: uint32(EXECUTOR_EID),
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0)
                .addExecutorLzComposeOption(0, 1_500_000, 0)
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            keccak256("USDC"),
            address(0xF),
            ADMIN,
            address(0x6A6A6A),
            uint256(3 days),
            uint256(1),
            uint32(EXECUTOR_EID),
            abi.encode(enforced)
        );
        dispatcher = vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args);
        vm.deal(dispatcher, 100 ether);
        usdc.mint(dispatcher, 100e6);
        bytes memory envelope =
            CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: keccak256("tracked")}));
        bytes memory composeMsg = LzComposeBuilder.build(dispatcher, uint32(EXECUTOR_EID), 100e6, envelope);
        endpoint.deliverCompose(dispatcher, address(pool), keccak256("guid"), composeMsg);
    }

    function _host() internal view override returns (address) {
        return dispatcher;
    }

    function _asset() internal view override returns (IMintable) {
        return IMintable(address(usdc));
    }

    function _rescueAdmin() internal pure override returns (address) {
        return ADMIN;
    }

    function _ledger() internal pure override returns (uint256) {
        return 100e6;
    }

    function _violation(uint256 balance_, uint256 required_) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(CrosschainErrors.RescueLedgerInvariantViolation.selector, balance_, required_);
    }
}

/// @notice CCIP host pair (`CcipCrosschainExecutor` / `CcipCrosschainDispatcher` `_afterRescueExecuted`).
abstract contract CcipRescueNonWorseningSetup is RescueNonWorseningBase {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant ADMIN = address(0xA11);

    MockCcipRouter internal router;
    AuditToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function _deploy() internal {
        router = new MockCcipRouter();
        token = new AuditToken(18);
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            ADMIN,
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _asset() internal view override returns (IMintable) {
        return IMintable(address(token));
    }

    function _rescueAdmin() internal pure override returns (address) {
        return ADMIN;
    }

    function _ledger() internal pure override returns (uint256) {
        return 100e18;
    }
}

contract CcipDispatcherRescueNonWorseningTest is CcipRescueNonWorseningSetup {
    function setUp() public {
        _deploy();
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        assertEq(dispatcher.trackedIdle(), 100e18, "dispatcher ledger funded");
    }

    function _host() internal view override returns (address) {
        return address(dispatcher);
    }

    function _violation(uint256 balance_, uint256 required_) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(CcipCrosschainDispatcher.InsufficientTrackedIdle.selector, balance_, required_);
    }
}

contract CcipExecutorRescueNonWorseningTest is CcipRescueNonWorseningSetup {
    using stdStorage for StdStorage;

    function setUp() public {
        _deploy();
        stdstore.target(address(executor)).sig("idleLedger()").checked_write(uint256(100e18));
        token.mint(address(executor), 100e18);
        assertEq(executor.idleLedger(), 100e18, "executor ledger funded");
    }

    function _host() internal view override returns (address) {
        return address(executor);
    }

    function _violation(uint256 balance_, uint256 required_) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(CcipCrosschainExecutor.UnbackedIdleCredit.selector, balance_, required_);
    }
}
