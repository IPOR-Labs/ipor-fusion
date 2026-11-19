// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    AssetDistributionProtectionLib,
    MarketLimit
} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {MorphoFlashLoanFuse, MorphoFlashLoanFuseEnterData} from "../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {CallbackHandlerMorpho} from "../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";
import {MockMorphoFlashLender} from "./mocks/MockMorphoFlashLender.sol";

/// @notice Test fuse of market 7 (ERC20_VAULT_BALANCE) whose action does nothing: it only puts market 7 on the list of
///         markets touched in the callback
contract CallbackMarketTouchFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function enter() external {}
}

/// @title PlasmaVaultCallbackLimitAfterRepaymentTest
/// @notice IL-9708 (change 1): PlasmaVault.executeInternal refreshes the market caches in a callback but does not check
///         the market limits there. The only limit check is the one at the end of execute, after the flash loan was
///         repaid.
/// @dev A flash loan of a token that market 7 values (not the underlying) lifts market 7 to about 99% of the NAV while
///      the callback runs. Before the change that check reverted a legitimate execute; after it the loan is repaid,
///      market 7 is back to zero and the limit holds.
contract PlasmaVaultCallbackLimitAfterRepaymentTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant FLASH_MARKET = IporFusionMarkets.MORPHO_FLASH_LOAN;
    uint256 internal constant TOKEN_MARKET = IporFusionMarkets.ERC20_VAULT_BALANCE;
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant FLASH_AMOUNT = 100_000e6;
    uint256 internal constant LENDER_RESERVE = 1_000_000e6;
    uint256 internal constant LIMIT_10_PERCENT = 1e17;

    MockMorphoFlashLender public lender;
    MorphoFlashLoanFuse public flashLoanFuse;
    MockERC20Decimals public token;
    CallbackMarketTouchFuse public touchFuse;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();

        token = new MockERC20Decimals("Mock Token", "mTKN", 6);
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            PlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware()
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(tokens, sources);

        lender = new MockMorphoFlashLender();
        asset.mint(address(lender), LENDER_RESERVE);
        token.mint(address(lender), LENDER_RESERVE);

        flashLoanFuse = new MorphoFlashLoanFuse(FLASH_MARKET, address(lender));
        touchFuse = new CallbackMarketTouchFuse(TOKEN_MARKET);

        address[] memory fuses = new address[](2);
        fuses[0] = address(flashLoanFuse);
        fuses[1] = address(touchFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            FLASH_MARKET,
            address(new ZeroBalanceFuse(FLASH_MARKET))
        );
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            TOKEN_MARKET,
            address(new ERC20BalanceFuse(TOKEN_MARKET))
        );

        bytes32[] memory flashSubstrates = new bytes32[](2);
        flashSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
        flashSubstrates[1] = PlasmaVaultConfigLib.addressToBytes32(address(token));
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(FLASH_MARKET, flashSubstrates);

        bytes32[] memory tokenSubstrates = new bytes32[](1);
        tokenSubstrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(token));
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(TOKEN_MARKET, tokenSubstrates);

        PlasmaVaultGovernance(address(plasmaVault)).updateCallbackHandler(
            address(new CallbackHandlerMorpho()),
            address(lender),
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );

        _deposit(user, DEPOSIT);
    }

    /// @dev Market 7 limit of 10%, flash loan of the token, the callback touches market 7. During the callback market 7
    ///      holds the whole loan (about 99% of the NAV); after repayment it holds nothing.
    function testShouldNotCheckMarketLimitInsideCallbackWhenBorrowedTokenIsRepaid() public {
        // given
        _setTokenMarketLimit(TOKEN_MARKET, LIMIT_10_PERCENT);
        FuseAction[] memory callbackCalls = new FuseAction[](1);
        callbackCalls[0] = FuseAction(address(touchFuse), abi.encodeCall(CallbackMarketTouchFuse.enter, ()));
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(flashLoanFuse),
            abi.encodeCall(
                MorphoFlashLoanFuse.enter,
                (MorphoFlashLoanFuseEnterData(address(token), FLASH_AMOUNT, abi.encode(callbackCalls)))
            )
        );

        // when
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        assertEq(plasmaVault.totalAssetsInMarket(TOKEN_MARKET), 0, "market 7 cache is zero after repayment");
        assertEq(token.balanceOf(address(plasmaVault)), 0, "no token left in the vault");
        assertEq(token.balanceOf(address(lender)), LENDER_RESERVE, "lender repaid");
        assertEq(plasmaVault.totalAssets(), DEPOSIT, "NAV unchanged");
    }

    /// @dev The check after repayment stays: market A at 10%, the whole NAV supplied to A in the callback
    function testShouldRevertWhenCallbackAllocationExceedsLimitAgainstNavAfterRepayment() public {
        // given
        _setLimits(LIMIT_10_PERCENT, LIMIT_10_PERCENT);
        FuseAction[] memory callbackCalls = new FuseAction[](1);
        callbackCalls[0] = FuseAction(
            address(supplyFuseA),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(marketA), DEPOSIT, 0)))
        );
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(flashLoanFuse),
            abi.encodeCall(
                MorphoFlashLoanFuse.enter,
                (MorphoFlashLoanFuseEnterData(address(asset), FLASH_AMOUNT, abi.encode(callbackCalls)))
            )
        );

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

    function _setTokenMarketLimit(uint256 marketId_, uint256 limit_) internal {
        MarketLimit[] memory limits = new MarketLimit[](1);
        limits[0] = MarketLimit(marketId_, limit_);
        PlasmaVaultGovernance(address(plasmaVault)).setupMarketsLimits(limits);
        PlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();
    }
}
