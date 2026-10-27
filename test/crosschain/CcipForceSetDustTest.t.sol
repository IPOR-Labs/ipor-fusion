// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipDecimalsLib} from "../../contracts/crosschain/ccip/lib/CcipDecimalsLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @dev Token with 18 local decimals (shared decimals are 6 below), i.e. `DECIMAL_CONVERSION_RATE == 1e12`.
contract CcipDustToken is ERC20 {
    constructor() ERC20("USD", "USD") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipForceSetDustTest
/// @notice IL-9025: `FORCE_SET_SETTLED` / `FORCE_SET_SETTLED_UNCHECKED` take the settled figure in local
///         decimals but book it in shared decimals, so a figure that is not a multiple of the conversion rate is
///         refused at schedule time (`AmountHasDust`) instead of reverting only at execute, after `RESCUE_DELAY`.
contract CcipForceSetDustTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant BALANCE_STALENESS_MAX = 7 days;
    uint256 internal constant RATE = 1e12;
    uint256 internal constant X = 100e6; // settled balance in shared decimals

    MockCcipRouter internal router;
    CcipDustToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipDustToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            6,
            _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            back,
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
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
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);

        // Settled balance: bridge 100e18 local (= 100e6 shared), then let the value-moving receipt age.
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        vm.warp(block.timestamp + 1 days);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: BALANCE_STALENESS_MAX,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    function _arg(uint256 newSettledLD_) internal view returns (uint256) {
        return
            (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (uint256(block.timestamp - 1 hours) << 128) |
            newSettledLD_;
    }

    function _assertDustRefusedAtSchedule(CcipChainRescue kind_) internal {
        assertEq(executor.DECIMAL_CONVERSION_RATE(), RATE, "18 local / 6 shared decimals");
        uint256 dusty = X * RATE + 1;
        uint256 countBefore = executor.rescueCount();
        uint256 dustyArg = _arg(dusty);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, dusty));
        executor.scheduleChainRescue(kind_, REMOTE_CHAIN, dustyArg);
        assertEq(executor.rescueCount(), countBefore, "nothing scheduled");

        // The smallest dust (rate - 1 above a multiple) is refused too.
        uint256 maxDust = X * RATE + RATE - 1;
        uint256 maxDustArg = _arg(maxDust);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CcipDecimalsLib.AmountHasDust.selector, maxDust));
        executor.scheduleChainRescue(kind_, REMOTE_CHAIN, maxDustArg);
    }

    function _assertCleanFigureExecutes(CcipChainRescue kind_) internal {
        uint256 clean = (X - 10e6) * RATE;
        uint256 arg = _arg(clean);
        uint256 countBefore = executor.rescueCount();
        vm.prank(RESCUE_ADMIN);
        uint256 id = executor.scheduleChainRescue(kind_, REMOTE_CHAIN, arg);
        assertEq(executor.rescueCount(), countBefore + 1, "clean figure scheduled");
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(id, kind_, REMOTE_CHAIN, arg);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), X - 10e6, "settled booked in shared decimals");
    }

    function testForceSetSettledShouldRefuseDustAtSchedule() public {
        _assertDustRefusedAtSchedule(CcipChainRescue.FORCE_SET_SETTLED);
    }

    function testForceSetSettledUncheckedShouldRefuseDustAtSchedule() public {
        _assertDustRefusedAtSchedule(CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED);
    }

    function testForceSetSettledShouldScheduleAndExecuteACleanMultiple() public {
        _assertCleanFigureExecutes(CcipChainRescue.FORCE_SET_SETTLED);
    }

    function testForceSetSettledUncheckedShouldScheduleAndExecuteACleanMultiple() public {
        _assertCleanFigureExecutes(CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED);
    }
}
