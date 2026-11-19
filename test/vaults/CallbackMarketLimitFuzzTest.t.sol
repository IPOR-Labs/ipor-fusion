// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AssetDistributionProtectionLib} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {MorphoFlashLoanFuse, MorphoFlashLoanFuseEnterData} from "../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {CallbackHandlerMorpho} from "../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";
import {MockMorphoFlashLender} from "./mocks/MockMorphoFlashLender.sol";

/// @title CallbackMarketLimitFuzzTest
/// @notice IL-9611 (M21): pins the property fixed in IL-9404. Markets touched inside a callback (here a Morpho Blue
///         flash loan) are limit-checked after the loan is repaid, against the NAV that excludes the borrowed principal.
/// @dev Property under test: after `PlasmaVault.execute` every market with a limit holds at most
///      `limit * NAV / 1e18` (NAV read after the call), or the transaction reverted with `MarketLimitExceeded`.
///      The fuzzed inputs are the flash loan size, the split of the allocation between market A (allocated inside
///      the callback) and market B (allocated by an action of the execute itself) and both limits. Passes on the base
///      commit (pinning test). Because the in-callback check sees a NAV that still holds the borrowed principal,
///      only the check after repayment can reject an over-limit callback allocation (the revert branch below). Companion of PlasmaVaultCallbackMarketLimitTest, which holds the
///      deterministic cases.
contract CallbackMarketLimitFuzzTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant FLASH_MARKET = IporFusionMarkets.MORPHO_FLASH_LOAN;
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant LENDER_RESERVE = 1_000_000_000e6;
    uint256 internal constant ONE_HUNDRED_PERCENT = 1e18;

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

    /// @notice Fuzz: whatever the loan size, split and limits, limits hold after execute or the call reverts on them.
    /// @param flashAmount_ Flash loan size, from dust up to ~1000x the NAV
    /// @param toA_ Amount supplied to market A inside the callback (bounded to the NAV)
    /// @param toB_ Amount supplied to market B by an action of the execute (bounded to what is left idle)
    /// @param limitA_ Limit of market A (share of NAV, 1e18 = 100%)
    /// @param limitB_ Limit of market B (share of NAV, 1e18 = 100%)
    function testFuzzMarketLimitsHoldAfterCallbackExecute(
        uint256 flashAmount_,
        uint256 toA_,
        uint256 toB_,
        uint256 limitA_,
        uint256 limitB_
    ) public {
        flashAmount_ = bound(flashAmount_, 1, 1_000_000e6);
        toA_ = bound(toA_, 0, DEPOSIT);
        toB_ = bound(toB_, 0, DEPOSIT - toA_);
        limitA_ = bound(limitA_, 0, ONE_HUNDRED_PERCENT);
        limitB_ = bound(limitB_, 0, ONE_HUNDRED_PERCENT);
        _setLimits(limitA_, limitB_);

        FuseAction[] memory callbackCalls = new FuseAction[](1);
        callbackCalls[0] = _supply(address(marketA), toA_);
        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = _flashLoan(flashAmount_, callbackCalls);
        calls[1] = _supply(address(marketB), toB_);

        vm.prank(alpha);
        try plasmaVault.execute(calls) {
            uint256 nav = plasmaVault.totalAssets();
            assertEq(nav, DEPOSIT, "NAV excludes the repaid principal");
            assertLe(
                plasmaVault.totalAssetsInMarket(MARKET_A),
                Math.mulDiv(limitA_, nav, ONE_HUNDRED_PERCENT),
                "market A within its limit after execute"
            );
            assertLe(
                plasmaVault.totalAssetsInMarket(MARKET_B),
                Math.mulDiv(limitB_, nav, ONE_HUNDRED_PERCENT),
                "market B within its limit after execute"
            );
            assertEq(asset.balanceOf(address(lender)), LENDER_RESERVE, "loan repaid");
        } catch (bytes memory reason) {
            assertEq(
                bytes4(reason),
                AssetDistributionProtectionLib.MarketLimitExceeded.selector,
                "the only allowed failure is MarketLimitExceeded"
            );
            // The revert is justified: some market is above its limit measured on the post-repayment NAV
            bool aOver = toA_ > Math.mulDiv(limitA_, DEPOSIT, ONE_HUNDRED_PERCENT);
            bool bOver = toB_ > Math.mulDiv(limitB_, DEPOSIT, ONE_HUNDRED_PERCENT);
            assertTrue(aOver || bOver, "reverted although both markets fit their limits");
            assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), 0, "reverted execute left no balance in A");
            assertEq(plasmaVault.totalAssetsInMarket(MARKET_B), 0, "reverted execute left no balance in B");
        }
    }

    function _supply(address market_, uint256 amount_) private view returns (FuseAction memory) {
        Erc4626SupplyFuse fuse = market_ == address(marketA) ? supplyFuseA : supplyFuseB;
        return
            FuseAction(
                address(fuse),
                abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(market_, amount_, 0)))
            );
    }

    function _flashLoan(uint256 amount_, FuseAction[] memory callbackCalls_) private view returns (FuseAction memory) {
        return
            FuseAction(
                address(flashLoanFuse),
                abi.encodeCall(
                    MorphoFlashLoanFuse.enter,
                    (MorphoFlashLoanFuseEnterData(address(asset), amount_, abi.encode(callbackCalls_)))
                )
            );
    }
}
