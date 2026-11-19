// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultMarketsLib} from "../../contracts/vaults/lib/PlasmaVaultMarketsLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AssetDistributionProtectionLib} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {MorphoFlashLoanFuse, MorphoFlashLoanFuseEnterData} from "../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {
    Erc4626SupplyFuse,
    Erc4626SupplyFuseEnterData,
    Erc4626SupplyFuseExitData
} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {CallbackHandlerMorpho} from "../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";
import {MockMorphoFlashLender} from "./mocks/MockMorphoFlashLender.sol";

/// @title PlasmaVaultCallbackMarketLimitTest
/// @notice IL-9404 (BugPoCer F-04): markets touched by fuse actions inside a callback (PlasmaVault.executeInternal, here
///         a Morpho Blue flash loan) are refreshed and limit-checked again at the end of PlasmaVault.execute, after the
///         loan was repaid, together with the markets of the execute itself.
/// @dev Runs on the locally built vault of PlasmaVaultMockMarketsTestBase; the flash loan comes from
///      MockMorphoFlashLender (Morpho Blue semantics). A limit check inside the callback would see a NAV that still holds
///      the borrowed tokens; executeInternal does not check limits (IL-9708), so only the check after repayment
///      produces the limit asserted here. foundry.toml sets
///      `isolate = false`, so several `execute` calls in one test share the transient storage of one transaction.
contract PlasmaVaultCallbackMarketLimitTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant FLASH_MARKET = IporFusionMarkets.MORPHO_FLASH_LOAN;
    uint256 internal constant DEPOSIT = 1_000e6;
    /// @dev 100x the NAV, inflates the NAV seen by the check inside the callback
    uint256 internal constant FLASH_AMOUNT = 100_000e6;
    uint256 internal constant LENDER_RESERVE = 1_000_000e6;
    uint256 internal constant LIMIT_10_PERCENT = 1e17;
    uint256 internal constant LIMIT_50_PERCENT = 5e17;

    bytes32 internal constant EXECUTE_FINISHED_TOPIC = keccak256("ExecuteFinished(address,uint256,uint256[])");
    bytes32 internal constant MARKET_BALANCES_UPDATED_TOPIC = keccak256("MarketBalancesUpdated(uint256[],int256)");

    MockMorphoFlashLender public lender;
    MorphoFlashLoanFuse public flashLoanFuse;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        lender = new MockMorphoFlashLender();
        asset.mint(address(lender), LENDER_RESERVE);

        flashLoanFuse = new MorphoFlashLoanFuse(FLASH_MARKET, address(lender));

        address[] memory fuses = new address[](1);
        fuses[0] = address(flashLoanFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            FLASH_MARKET,
            address(new ZeroBalanceFuse(FLASH_MARKET))
        );

        bytes32[] memory flashSubstrates = new bytes32[](1);
        flashSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(FLASH_MARKET, flashSubstrates);

        PlasmaVaultGovernance(address(plasmaVault)).updateCallbackHandler(
            address(new CallbackHandlerMorpho()),
            address(lender),
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        _deposit(user, DEPOSIT);
    }

    // ------------------------------------------------------------------ tests

    /// @dev Regression of BugPoCer F-04: 10% limit on market A, a 100x-NAV flash loan, the whole NAV supplied
    ///      to A inside the callback. The revert arguments are measured against the NAV after repayment (DEPOSIT);
    ///      an in-callback check would have used DEPOSIT + FLASH_AMOUNT and passed (IL-9708: there is none).
    function testShouldRevertWhenCallbackAllocationExceedsMarketLimitAfterRepayment() public {
        // given
        _setLimits(LIMIT_10_PERCENT, LIMIT_10_PERCENT);
        FuseAction[] memory calls = _calls(_flashLoan(_calls(_supply(address(marketA), DEPOSIT))));

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                MARKET_A,
                DEPOSIT,
                DEPOSIT / 10
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // and the allocation did not happen
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), 0, "no cached balance in market A");
        assertEq(marketA.balanceOf(address(plasmaVault)), 0, "no shares of market A");
        assertEq(asset.balanceOf(address(plasmaVault)), DEPOSIT, "assets stay idle");
        assertEq(asset.balanceOf(address(lender)), LENDER_RESERVE, "lender reserve untouched");
    }

    function testShouldAllowCallbackAllocationWithinMarketLimit() public {
        // given
        _setLimits(LIMIT_10_PERCENT, LIMIT_10_PERCENT);
        uint256 amount = DEPOSIT / 20;

        // when
        _execute(_calls(_flashLoan(_calls(_supply(address(marketA), amount)))));

        // then
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), amount, "market A holds 5% of the NAV");
        assertEq(plasmaVault.totalAssets(), DEPOSIT, "NAV unchanged");
        assertEq(asset.balanceOf(address(plasmaVault)), DEPOSIT - amount, "flash loan repaid from the vault");
        assertEq(asset.balanceOf(address(lender)), LENDER_RESERVE, "lender repaid");
    }

    /// @dev IL-8350 / IL-8362: the value of market A changes after the callback returned (before the repayment); the
    ///      vault caches the value after the callback, not the one written by the refresh inside the callback. Market
    ///      limits are not active: the refresh after execute always runs.
    function testShouldCacheCallbackMarketValueAfterCallbackReturns() public {
        // given
        uint256 amount = DEPOSIT / 2;
        uint256 lateTransfer = 30e6;
        lender.setAfterCallbackTransfer(address(marketA), lateTransfer);

        // when
        _execute(_calls(_flashLoan(_calls(_supply(address(marketA), amount)))));

        // then
        uint256 valueAfterCallback = marketA.convertToAssets(marketA.balanceOf(address(plasmaVault)));
        assertGt(valueAfterCallback, amount, "precondition: market A grew after the callback");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), valueAfterCallback, "cache = value after the callback");
        assertEq(plasmaVault.totalAssets(), DEPOSIT - amount + valueAfterCallback, "NAV includes the late value");
    }

    /// @dev Two flash loans in one execute: the first callback puts 50% of the NAV into A (limit 10%), the second puts
    ///      10% into B (limit 50%). Markets of every callback are checked, so the execute reverts on A.
    function testShouldCheckMarketsOfEveryCallbackInOneExecute() public {
        // given
        _setLimits(LIMIT_10_PERCENT, LIMIT_50_PERCENT);
        uint256 toA = DEPOSIT / 2;
        uint256 toB = DEPOSIT / 10;
        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = _flashLoan(_calls(_supply(address(marketA), toA)));
        calls[1] = _flashLoan(_calls(_supply(address(marketB), toB)));

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                MARKET_A,
                toA,
                DEPOSIT / 10
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // and nothing was allocated
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), 0, "no cached balance in market A");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_B), 0, "no cached balance in market B");
    }

    /// @dev Two executes in one transaction: the callback markets of the first one must not be refreshed by the second.
    function testShouldClearCallbackMarketsAtEndOfExecute() public {
        // given: the first execute touches market A in a callback
        vm.recordLogs();
        _execute(_calls(_flashLoan(_calls(_supply(address(marketA), DEPOSIT / 20)))));
        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        assertTrue(
            _contains(_executeFinishedMarkets(firstLogs), MARKET_A),
            "precondition: the first execute refreshed the callback market"
        );

        // when: the second execute, without a callback, touches market B only
        vm.recordLogs();
        _execute(_calls(_supply(address(marketB), DEPOSIT / 20)));
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();

        // then
        uint256[] memory refreshed = _lastMarketBalancesUpdated(secondLogs);
        assertEq(refreshed.length, 1, "the second execute refreshes one market");
        assertEq(refreshed[0], MARKET_B, "the second execute refreshes market B only");

        uint256[] memory reported = _executeFinishedMarkets(secondLogs);
        assertEq(reported.length, 1, "the second execute reports its own market list");
        assertEq(reported[0], MARKET_B, "the second execute reports market B");
    }

    /// @dev ExecuteFinished reports the union of the execute's markets and the callback markets, without duplicates:
    ///      A is touched directly and in the callback, B only in the callback.
    function testShouldReportUnionOfExecuteAndCallbackMarkets() public {
        // given
        uint256 amount = DEPOSIT / 20;
        FuseAction[] memory callbackCalls = new FuseAction[](2);
        callbackCalls[0] = _supply(address(marketA), amount);
        callbackCalls[1] = _supply(address(marketB), amount);
        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = _supply(address(marketA), amount);
        calls[1] = _flashLoan(callbackCalls);

        uint256[] memory expected = new uint256[](3);
        expected[0] = MARKET_A;
        expected[1] = FLASH_MARKET;
        expected[2] = MARKET_B;

        // when
        vm.recordLogs();
        _execute(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(_executeFinishedMarkets(logs), expected, "ExecuteFinished carries the union");
        assertEq(_lastMarketBalancesUpdated(logs), expected, "the union is refreshed after execute");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), 2 * amount, "market A");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_B), amount, "market B");
    }

    function testCallbackMarketsSlotFollowsErc7201() public pure {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.transient.CallbackMarkets")) - 1)) &
            ~bytes32(uint256(0xff));

        assertEq(PlasmaVaultMarketsLib.CALLBACK_MARKETS_TRANSIENT_SLOT, expected, "ERC-7201 slot");
    }

    /// @dev Pins the behaviour documented for IL-9404 under D-002: the check after repayment lists every callback
    ///      market and has no risk-reducing exemption. Market A is already above its limit (limit lowered after the
    ///      allocation), so a flash-loan callback that only partially deleverages A still reverts; a callback that
    ///      brings A back under the limit passes.
    function testShouldRevertCallbackDeleverageOfOverLimitMarket() public {
        // given: 40% of the NAV in A under a 50% limit, then the limit is lowered to 10%
        uint256 allocated = (DEPOSIT * 4) / 10;
        _setLimits(LIMIT_50_PERCENT, LIMIT_50_PERCENT);
        _execute(_calls(_supply(address(marketA), allocated)));
        _setLimits(LIMIT_10_PERCENT, LIMIT_10_PERCENT);
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), allocated, "precondition: A is above its new limit");

        // when / then: a partial deleverage inside the callback leaves A (300) above the limit (100)
        uint256 partialExit = DEPOSIT / 10;
        FuseAction[] memory partialCalls = _calls(_flashLoan(_calls(_exit(address(marketA), partialExit))));
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                MARKET_A,
                allocated - partialExit,
                DEPOSIT / 10
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(partialCalls);
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), allocated, "reverted deleverage changed nothing");

        // and: a deleverage that brings A under the limit passes
        uint256 fullExit = allocated - DEPOSIT / 20;
        _execute(_calls(_flashLoan(_calls(_exit(address(marketA), fullExit)))));
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), DEPOSIT / 20, "A is back under its limit");
        assertEq(plasmaVault.totalAssets(), DEPOSIT, "NAV unchanged");
    }

    /// @dev Control: the same allocation as in the PoC, done directly, is rejected by the existing check.
    function testShouldRevertDirectAllocationAboveMarketLimit() public {
        // given
        _setLimits(LIMIT_10_PERCENT, LIMIT_10_PERCENT);
        FuseAction[] memory calls = _calls(_supply(address(marketA), DEPOSIT));

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                MARKET_A,
                DEPOSIT,
                DEPOSIT / 10
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    // ------------------------------------------------------------------ helpers

    function _execute(FuseAction[] memory calls_) internal {
        vm.prank(alpha);
        plasmaVault.execute(calls_);
    }

    function _supply(address market_, uint256 amount_) internal view returns (FuseAction memory) {
        Erc4626SupplyFuse fuse = market_ == address(marketA) ? supplyFuseA : supplyFuseB;
        return
            FuseAction(
                address(fuse),
                abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(market_, amount_, 0)))
            );
    }

    function _exit(address market_, uint256 amount_) internal view returns (FuseAction memory) {
        Erc4626SupplyFuse fuse = market_ == address(marketA) ? supplyFuseA : supplyFuseB;
        return
            FuseAction(
                address(fuse),
                abi.encodeCall(Erc4626SupplyFuse.exit, (Erc4626SupplyFuseExitData(market_, amount_, 0, 0)))
            );
    }

    function _flashLoan(FuseAction[] memory callbackCalls_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(flashLoanFuse),
                abi.encodeCall(
                    MorphoFlashLoanFuse.enter,
                    (MorphoFlashLoanFuseEnterData(address(asset), FLASH_AMOUNT, abi.encode(callbackCalls_)))
                )
            );
    }

    function _calls(FuseAction memory call_) internal pure returns (FuseAction[] memory calls) {
        calls = new FuseAction[](1);
        calls[0] = call_;
    }

    /// @dev Market ids of the ExecuteFinished event of the vault in `logs_` (zero entries removed)
    function _executeFinishedMarkets(Vm.Log[] memory logs_) internal view returns (uint256[] memory marketIds) {
        bool found;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(plasmaVault) && logs_[i].topics[0] == EXECUTE_FINISHED_TOPIC) {
                (, , marketIds) = abi.decode(logs_[i].data, (address, uint256, uint256[]));
                found = true;
            }
        }
        assertTrue(found, "ExecuteFinished emitted");
        marketIds = _nonZero(marketIds);
    }

    /// @dev Market ids of the last MarketBalancesUpdated event of the vault in `logs_`
    function _lastMarketBalancesUpdated(Vm.Log[] memory logs_) internal view returns (uint256[] memory marketIds) {
        bool found;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(plasmaVault) && logs_[i].topics[0] == MARKET_BALANCES_UPDATED_TOPIC) {
                (marketIds, ) = abi.decode(logs_[i].data, (uint256[], int256));
                found = true;
            }
        }
        assertTrue(found, "MarketBalancesUpdated emitted");
    }

    function _nonZero(uint256[] memory ids_) internal pure returns (uint256[] memory result) {
        uint256 count;
        for (uint256 i; i < ids_.length; ++i) {
            if (ids_[i] != 0) {
                ++count;
            }
        }
        result = new uint256[](count);
        count = 0;
        for (uint256 i; i < ids_.length; ++i) {
            if (ids_[i] != 0) {
                result[count] = ids_[i];
                ++count;
            }
        }
    }

    function _contains(uint256[] memory ids_, uint256 id_) internal pure returns (bool) {
        for (uint256 i; i < ids_.length; ++i) {
            if (ids_[i] == id_) {
                return true;
            }
        }
        return false;
    }
}
