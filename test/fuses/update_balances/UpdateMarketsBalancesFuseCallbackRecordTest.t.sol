// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AssetDistributionProtectionLib} from "../../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IMarketBalanceFuse} from "../../../contracts/fuses/IMarketBalanceFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {
    MorphoFlashLoanFuse,
    MorphoFlashLoanFuseEnterData
} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {UpdateMarketsBalancesFuse} from "../../../contracts/fuses/update_balances/UpdateMarketsBalancesFuse.sol";
import {UpdateMarketsBalancesEnterData} from "../../../contracts/fuses/update_balances/IUpdateMarketsBalancesFuse.sol";
import {CallbackHandlerMorpho} from "../../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {PlasmaVaultMockMarketsTestBase} from "../../vaults/PlasmaVaultMockMarketsTestBase.sol";
import {MockMorphoFlashLender} from "../../vaults/mocks/MockMorphoFlashLender.sol";
import {MockERC20Decimals} from "../../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @dev Test-only balance fuse: values the vault's balance of a 6-decimals token at 1 USD (WAD). Runs by delegatecall.
contract VaultTokenBalanceFuseMock is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;
    address public immutable TOKEN;

    constructor(uint256 marketId_, address token_) {
        MARKET_ID = marketId_;
        TOKEN = token_;
    }

    function balanceOf() external view override returns (uint256) {
        return IERC20(TOKEN).balanceOf(address(this)) * 1e12;
    }
}

/// @title UpdateMarketsBalancesFuseCallbackRecordTest
/// @notice IL-9708 (3sigma #22), change 2: UpdateMarketsBalancesFuse records the markets it refreshed, so that
///         PlasmaVault.execute re-reads and limit-checks them at its end, whatever the dependency graph says.
/// @dev Runs on the locally built vault of PlasmaVaultMockMarketsTestBase with the real UpdateMarketsBalancesFuse.
contract UpdateMarketsBalancesFuseCallbackRecordTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant FLASH_MARKET = IporFusionMarkets.MORPHO_FLASH_LOAN;
    /// @dev Market that values a token held by the vault, outside of the underlying asset
    uint256 internal constant BORROWED_MARKET = 7;
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant FLASH_AMOUNT = 100_000e6;
    uint256 internal constant LENDER_RESERVE = 1_000_000e6;
    uint256 internal constant LIMIT_10_PERCENT = 1e17;
    uint256 internal constant LIMIT_50_PERCENT = 5e17;

    bytes32 internal constant MARKET_BALANCES_UPDATED_TOPIC = keccak256("MarketBalancesUpdated(uint256[],int256)");

    MockERC20Decimals public borrowed;
    MockMorphoFlashLender public lender;
    MorphoFlashLoanFuse public flashLoanFuse;
    UpdateMarketsBalancesFuse public updateFuse;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        borrowed = new MockERC20Decimals("Borrowed", "BRW", 6);
        lender = new MockMorphoFlashLender();
        borrowed.mint(address(lender), LENDER_RESERVE);

        flashLoanFuse = new MorphoFlashLoanFuse(FLASH_MARKET, address(lender));
        updateFuse = new UpdateMarketsBalancesFuse();

        address[] memory fuses = new address[](2);
        fuses[0] = address(flashLoanFuse);
        fuses[1] = address(updateFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            FLASH_MARKET,
            address(new ZeroBalanceFuse(FLASH_MARKET))
        );
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            BORROWED_MARKET,
            address(new VaultTokenBalanceFuseMock(BORROWED_MARKET, address(borrowed)))
        );
        // the vault's own balance of the update fuse market
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET))
        );

        bytes32[] memory flashSubstrates = new bytes32[](1);
        flashSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(borrowed));
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(FLASH_MARKET, flashSubstrates);

        PlasmaVaultGovernance(address(plasmaVault)).updateCallbackHandler(
            address(new CallbackHandlerMorpho()),
            address(lender),
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        _deposit(user, DEPOSIT);
    }

    // ------------------------------------------------------------------ tests

    /// @dev A non-underlying token is flash-loaned, the callback refreshes market 7 (which values that token) and the
    ///      loan is repaid. The refresh inside the callback cached the borrowed amount; the end of execute must read
    ///      market 7 again (the token is gone), otherwise totalAssets stays inflated by the loan.
    function testShouldRereadMarketRefreshedInCallbackAfterRepayment() public {
        // given
        uint256[] memory markets = _ids(BORROWED_MARKET);
        FuseAction[] memory callbackCalls = _one(_updateCall(markets));

        // when
        _execute(_one(_flashLoan(callbackCalls)));

        // then
        assertEq(borrowed.balanceOf(address(plasmaVault)), 0, "precondition: the loan was repaid");
        assertEq(plasmaVault.totalAssetsInMarket(BORROWED_MARKET), 0, "market 7 re-read after repayment");
        assertEq(plasmaVault.totalAssets(), DEPOSIT, "NAV is not inflated by the repaid loan");
    }

    /// @dev The fuse as a plain execute action for a market above its limit: the end of execute limit-checks it.
    function testShouldRevertWhenUpdateFuseRefreshesMarketAboveLimit() public {
        // given: 40% of the NAV in A, limit lowered to 10%; the cache still holds the 40%
        uint256 allocated = (DEPOSIT * 4) / 10;
        _setLimits(LIMIT_50_PERCENT, LIMIT_50_PERCENT);
        _allocate(address(marketA), allocated);
        _setLimits(LIMIT_10_PERCENT, LIMIT_10_PERCENT);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                MARKET_A,
                allocated,
                DEPOSIT / 10
            )
        );
        vm.prank(alpha);
        plasmaVault.execute(_one(_updateCall(_ids(MARKET_A))));
    }

    /// @dev Within the limit the execute passes and its final refresh covers the market the fuse refreshed.
    function testShouldRefreshAgainAtEndOfExecuteForMarketWithinLimit() public {
        // given
        _setLimits(LIMIT_50_PERCENT, LIMIT_50_PERCENT);
        _allocate(address(marketA), DEPOSIT / 10);
        _accrue(address(marketA), 1_000);

        // when
        vm.recordLogs();
        _execute(_one(_updateCall(_ids(MARKET_A))));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256[] memory last = _lastMarketBalancesUpdated(logs);
        assertTrue(_contains(last, MARKET_A), "the final refresh covers market A");
        assertEq(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            marketA.convertToAssets(marketA.balanceOf(address(plasmaVault))),
            "cache = current value"
        );
    }

    /// @dev A duplicated id and a zero id in the list do not break the final re-read.
    function testShouldHandleDuplicatedAndZeroMarketIds() public {
        // given
        _setLimits(LIMIT_50_PERCENT, LIMIT_50_PERCENT);
        _allocate(address(marketA), DEPOSIT / 10);
        _accrue(address(marketA), 1_000);
        uint256[] memory markets = new uint256[](3);
        markets[0] = MARKET_A;
        markets[1] = 0;
        markets[2] = MARKET_A;

        // when
        vm.recordLogs();
        _execute(_one(_updateCall(markets)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256[] memory last = _lastMarketBalancesUpdated(logs);
        assertTrue(_contains(last, MARKET_A), "the final refresh covers market A");
        assertEq(_count(last, MARKET_A), 1, "market A is read once");
        assertEq(
            plasmaVault.totalAssetsInMarket(MARKET_A),
            marketA.convertToAssets(marketA.balanceOf(address(plasmaVault))),
            "cache = current value"
        );
    }

    /// @dev The record is cleared at the end of execute: a later execute without the fuse refreshes only its own market.
    function testShouldNotCarryRecordedMarketsToNextExecute() public {
        // given
        _execute(_one(_updateCall(_ids(MARKET_A))));

        // when
        vm.recordLogs();
        _execute(_one(_supplyB(DEPOSIT / 20)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256[] memory last = _lastMarketBalancesUpdated(logs);
        assertTrue(_contains(last, MARKET_B), "market B refreshed");
        assertFalse(_contains(last, MARKET_A), "market A of the previous execute is not refreshed");
    }

    // ------------------------------------------------------------------ helpers

    function _execute(FuseAction[] memory calls_) internal {
        vm.prank(alpha);
        plasmaVault.execute(calls_);
    }

    function _updateCall(uint256[] memory markets_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(updateFuse),
                abi.encodeCall(UpdateMarketsBalancesFuse.enter, (UpdateMarketsBalancesEnterData(markets_)))
            );
    }

    function _supplyB(uint256 amount_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(supplyFuseB),
                abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(marketB), amount_, 0)))
            );
    }

    function _flashLoan(FuseAction[] memory callbackCalls_) internal view returns (FuseAction memory) {
        return
            FuseAction(
                address(flashLoanFuse),
                abi.encodeCall(
                    MorphoFlashLoanFuse.enter,
                    (MorphoFlashLoanFuseEnterData(address(borrowed), FLASH_AMOUNT, abi.encode(callbackCalls_)))
                )
            );
    }

    function _one(FuseAction memory call_) internal pure returns (FuseAction[] memory calls) {
        calls = new FuseAction[](1);
        calls[0] = call_;
    }

    function _ids(uint256 id_) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id_;
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

    function _contains(uint256[] memory ids_, uint256 id_) internal pure returns (bool) {
        return _count(ids_, id_) != 0;
    }

    function _count(uint256[] memory ids_, uint256 id_) internal pure returns (uint256 count) {
        for (uint256 i; i < ids_.length; ++i) {
            if (ids_[i] == id_) {
                ++count;
            }
        }
    }
}
