// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IMidasDataFeed} from "../../../contracts/fuses/midas/ext/IMidasDataFeed.sol";
import {IMidasDepositVault} from "../../../contracts/fuses/midas/ext/IMidasDepositVault.sol";
import {IMidasRedemptionVault} from "../../../contracts/fuses/midas/ext/IMidasRedemptionVault.sol";
import {MidasBalanceFuse} from "../../../contracts/fuses/midas/MidasBalanceFuse.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {MidasSupplyFuse} from "../../../contracts/fuses/midas/MidasSupplyFuse.sol";
import {MidasPendingRequestsHelper} from "./MidasPendingRequestsHelper.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract MidasBalanceFuseTest is Test {
    address public constant MTBILL_TOKEN = 0xDD629E5241CbC5919847783e6C96B2De4754e438;
    address public constant MBASIS_TOKEN = 0x2a8c22E3b10036f3AEF5875d04f8441d4188b656;
    address public constant MTBILL_DEPOSIT_VAULT = 0x99361435420711723aF805F08187c9E6bF796683;
    address public constant MBASIS_DEPOSIT_VAULT = 0xa8a5c4FF4c86a459EBbDC39c5BE77833B3A15d88;
    address public constant MTBILL_REDEMPTION_VAULT = 0xF6e51d24F4793Ac5e71e0502213a9BBE3A6d4517;
    address public constant MBASIS_REDEMPTION_VAULT = 0x19AB19e61A930bc5C7B75Bf06cDd954218Ca9F0b;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Mock data feed price: ~$1.07 per mTBILL (18 decimals)
    uint256 public constant MOCK_MTBILL_PRICE = 1_070000000000000000;
    // Mock data feed price: ~$1.02 per mBASIS (18 decimals)
    uint256 public constant MOCK_MBASIS_PRICE = 1_020000000000000000;

    uint256 public constant MARKET_ID = IporFusionMarkets.MIDAS;
    uint256 public constant FORK_BLOCK = 21800000;

    MidasBalanceFuse public balanceFuse;
    MidasSupplyFuse public supplyFuse;
    MidasPendingRequestsHelper public storageHelper;
    PlasmaVaultMock public vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        supplyFuse = new MidasSupplyFuse(MARKET_ID);
        balanceFuse = new MidasBalanceFuse(MARKET_ID);
        storageHelper = new MidasPendingRequestsHelper();
        vault = new PlasmaVaultMock(address(supplyFuse), address(balanceFuse));

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MTBILL_TOKEN})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MTBILL_DEPOSIT_VAULT})
        );
        substrates[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.REDEMPTION_VAULT,
                substrateAddress: MTBILL_REDEMPTION_VAULT
            })
        );
        vault.grantMarketSubstrates(MARKET_ID, substrates);

        // Mock mToken() and mTokenDataFeed() on deposit vault
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mToken.selector),
            abi.encode(MTBILL_TOKEN)
        );
        address mtbillDataFeed = _mockDataFeedAddress(MTBILL_DEPOSIT_VAULT);
        vm.mockCall(
            mtbillDataFeed,
            abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector),
            abi.encode(MOCK_MTBILL_PRICE)
        );

        // Mock mToken() on redemption vault
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.mToken.selector),
            abi.encode(MTBILL_TOKEN)
        );

        vm.label(address(balanceFuse), "MidasBalanceFuse");
        vm.label(address(storageHelper), "MidasPendingRequestsHelper");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(MTBILL_TOKEN, "mTBILL");
        vm.label(MTBILL_DEPOSIT_VAULT, "MidasDepositVault_mTBILL");
        vm.label(MTBILL_REDEMPTION_VAULT, "MidasRedemptionVault_mTBILL");
    }

    /// @dev Helper: mock mTokenDataFeed() on a deposit vault and return the data feed address
    function _mockDataFeedAddress(address depositVault_) internal returns (address dataFeed) {
        // Use a deterministic address derived from the deposit vault for the mock data feed
        dataFeed = address(uint160(uint256(keccak256(abi.encodePacked("dataFeed", depositVault_)))));
        vm.mockCall(
            depositVault_,
            abi.encodeWithSelector(IMidasDepositVault.mTokenDataFeed.selector),
            abi.encode(dataFeed)
        );
        vm.label(dataFeed, string.concat("MockDataFeed_", vm.toString(depositVault_)));
    }

    /// @dev Helper to add a pending deposit to vault's storage via delegatecall
    function _addPendingDeposit(address depositVault_, uint256 requestId_) internal {
        vault.execute(
            address(storageHelper),
            abi.encodeWithSelector(MidasPendingRequestsHelper.addPendingDeposit.selector, depositVault_, requestId_)
        );
    }

    /// @dev Helper to add a pending redemption to vault's storage via delegatecall
    function _addPendingRedemption(address redemptionVault_, uint256 requestId_) internal {
        vault.execute(
            address(storageHelper),
            abi.encodeWithSelector(
                MidasPendingRequestsHelper.addPendingRedemption.selector, redemptionVault_, requestId_
            )
        );
    }

    // ============ Constructor Tests ============

    function testShouldReturnCorrectMarketId() public view {
        assertEq(balanceFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldReturnCorrectVersion() public view {
        assertEq(balanceFuse.VERSION(), address(balanceFuse));
    }

    // ============ Balance Tests ============

    function testShouldReturnZeroWhenNoHoldings() public {
        uint256 balance = vault.balanceOf();
        assertEq(balance, 0, "Balance should be zero when no holdings");
    }

    function testShouldReturnMTokenValueWhenHoldingMTbill() public {
        uint256 mTokenAmount = 100e18; // 100 mTBILL
        deal(MTBILL_TOKEN, address(vault), mTokenAmount);

        uint256 balance = vault.balanceOf();

        // Expected: mTokenAmount * price / 1e18 = 100e18 * 1.07e18 / 1e18 = 107e18
        uint256 expectedBalance = (mTokenAmount * MOCK_MTBILL_PRICE) / 1e18;

        assertGt(balance, 0, "Balance should be greater than zero");
        assertEq(balance, expectedBalance, "Balance should equal mToken value in USD");
    }

    function testShouldReturnValueInWadDecimals() public {
        deal(MTBILL_TOKEN, address(vault), 1e18); // 1 mTBILL

        uint256 balance = vault.balanceOf();

        // 1 mTBILL at $1.07 = 1.07e18
        assertEq(balance, MOCK_MTBILL_PRICE, "1 mTBILL should be worth the data feed price");
    }

    function testShouldIncludePendingDepositValueInBalance() public {
        // Add mTBILL held by vault
        deal(MTBILL_TOKEN, address(vault), 50e18);

        // Add pending deposit to vault's storage via delegatecall
        uint256 depositRequestId = 1;
        _addPendingDeposit(MTBILL_DEPOSIT_VAULT, depositRequestId);

        // Mock mintRequests to return a pending request with $50 deposited
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mintRequests.selector, depositRequestId),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(vault),
                    tokenIn: USDC,
                    status: 0, // Pending
                    depositedUsdAmount: 50e18,
                    usdAmountWithoutFees: 49e18,
                    tokenOutRate: 0
                })
            )
        );

        uint256 balance = vault.balanceOf();

        // Balance = mToken value + pending deposit value
        // mToken: 50e18 * 1.07e18 / 1e18 = 53.5e18
        // pending deposit: 50e18 (depositedUsdAmount already in 18 decimals)
        uint256 mTokenValue = (50e18 * MOCK_MTBILL_PRICE) / 1e18;
        uint256 pendingDepositValue = 50e18;
        assertEq(balance, mTokenValue + pendingDepositValue, "Balance should include mToken value + pending deposit");
    }

    function testShouldReturnZeroPriceWhenDataFeedReturnsZero() public {
        // Mock data feed to return 0 price (via deposit vault's mTokenDataFeed)
        address dataFeed = address(uint160(uint256(keccak256(abi.encodePacked("dataFeed", MTBILL_DEPOSIT_VAULT)))));
        vm.mockCall(
            dataFeed,
            abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector),
            abi.encode(uint256(0))
        );

        deal(MTBILL_TOKEN, address(vault), 100e18);

        uint256 balance = vault.balanceOf();
        assertEq(balance, 0, "Balance should be zero when mToken price is zero");
    }

    // ============ Additional Balance Tests ============

    function testShouldReturnMTokenValueWhenHoldingMBasis() public {
        // Create a balance fuse and vault with mBASIS deposit vault in substrates
        MidasBalanceFuse mBasisBalanceFuse = new MidasBalanceFuse(MARKET_ID);
        PlasmaVaultMock mBasisVault = new PlasmaVaultMock(address(supplyFuse), address(mBasisBalanceFuse));

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MBASIS_DEPOSIT_VAULT})
        );
        mBasisVault.grantMarketSubstrates(MARKET_ID, substrates);

        // Mock mToken() and mTokenDataFeed() on mBASIS deposit vault
        vm.mockCall(
            MBASIS_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mToken.selector),
            abi.encode(MBASIS_TOKEN)
        );
        address mbasisDataFeed = _mockDataFeedAddress(MBASIS_DEPOSIT_VAULT);
        vm.mockCall(
            mbasisDataFeed,
            abi.encodeWithSelector(IMidasDataFeed.getDataInBase18.selector),
            abi.encode(MOCK_MBASIS_PRICE)
        );

        uint256 mBasisAmount = 100e18;
        deal(MBASIS_TOKEN, address(mBasisVault), mBasisAmount);

        uint256 balance = mBasisVault.balanceOf();

        uint256 expectedBalance = (mBasisAmount * MOCK_MBASIS_PRICE) / 1e18;
        assertEq(balance, expectedBalance, "Balance should equal mBASIS value in USD");
    }

    function testShouldIncludePendingRedemptionValueInBalance() public {
        // Add mTBILL held by vault
        deal(MTBILL_TOKEN, address(vault), 50e18);

        // Add pending redemption to vault's storage
        uint256 redeemRequestId = 5;
        _addPendingRedemption(MTBILL_REDEMPTION_VAULT, redeemRequestId);

        // Mock redeemRequests to return a pending request with 30 mTokens
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.redeemRequests.selector, redeemRequestId),
            abi.encode(
                IMidasRedemptionVault.Request({
                    sender: address(vault),
                    tokenOut: USDC,
                    status: 0, // Pending
                    amountMToken: 30e18,
                    mTokenRate: 0,
                    tokenOutRate: 0
                })
            )
        );

        uint256 balance = vault.balanceOf();

        // mToken value: 50e18 * 1.07e18 / 1e18 = 53.5e18
        // pending redemption value: 30e18 * 1.07e18 / 1e18 = 32.1e18
        uint256 mTokenValue = (50e18 * MOCK_MTBILL_PRICE) / 1e18;
        uint256 pendingRedemptionValue = (30e18 * MOCK_MTBILL_PRICE) / 1e18;
        assertEq(balance, mTokenValue + pendingRedemptionValue, "Balance should include mToken + pending redemption");
    }

    function testShouldIncludeAllThreeComponentsInBalance() public {
        // Component A: mToken held
        deal(MTBILL_TOKEN, address(vault), 100e18);

        // Component B: pending deposit
        uint256 depositRequestId = 10;
        _addPendingDeposit(MTBILL_DEPOSIT_VAULT, depositRequestId);
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mintRequests.selector, depositRequestId),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(vault),
                    tokenIn: USDC,
                    status: 0,
                    depositedUsdAmount: 200e18,
                    usdAmountWithoutFees: 198e18,
                    tokenOutRate: 0
                })
            )
        );

        // Component C: pending redemption
        uint256 redeemRequestId = 20;
        _addPendingRedemption(MTBILL_REDEMPTION_VAULT, redeemRequestId);
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.redeemRequests.selector, redeemRequestId),
            abi.encode(
                IMidasRedemptionVault.Request({
                    sender: address(vault),
                    tokenOut: USDC,
                    status: 0,
                    amountMToken: 50e18,
                    mTokenRate: 0,
                    tokenOutRate: 0
                })
            )
        );

        uint256 balance = vault.balanceOf();

        uint256 componentA = (100e18 * MOCK_MTBILL_PRICE) / 1e18; // 107e18
        uint256 componentB = 200e18; // depositedUsdAmount
        uint256 componentC = (50e18 * MOCK_MTBILL_PRICE) / 1e18; // 53.5e18
        uint256 expectedTotal = componentA + componentB + componentC;

        assertEq(balance, expectedTotal, "Balance should include all three components");
    }

    function testShouldExcludeProcessedDepositRequestsFromBalance() public {
        deal(MTBILL_TOKEN, address(vault), 50e18);

        // Add pending deposit to storage
        uint256 depositRequestId = 15;
        _addPendingDeposit(MTBILL_DEPOSIT_VAULT, depositRequestId);

        // Mock mintRequests to return a PROCESSED request (status = 1)
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mintRequests.selector, depositRequestId),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(vault),
                    tokenIn: USDC,
                    status: 1, // Processed - should be excluded
                    depositedUsdAmount: 50e18,
                    usdAmountWithoutFees: 49e18,
                    tokenOutRate: 1_070000000000000000
                })
            )
        );

        uint256 balance = vault.balanceOf();

        // Should only include mToken value, NOT the processed deposit
        uint256 mTokenValue = (50e18 * MOCK_MTBILL_PRICE) / 1e18;
        assertEq(balance, mTokenValue, "Balance should exclude processed deposit requests");
    }

    function testShouldExcludeProcessedRedemptionRequestsFromBalance() public {
        deal(MTBILL_TOKEN, address(vault), 50e18);

        // Add pending redemption to storage
        uint256 redeemRequestId = 25;
        _addPendingRedemption(MTBILL_REDEMPTION_VAULT, redeemRequestId);

        // Mock redeemRequests to return a PROCESSED request (status = 1)
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.redeemRequests.selector, redeemRequestId),
            abi.encode(
                IMidasRedemptionVault.Request({
                    sender: address(vault),
                    tokenOut: USDC,
                    status: 1, // Processed - should be excluded
                    amountMToken: 30e18,
                    mTokenRate: 1_070000000000000000,
                    tokenOutRate: 1e6
                })
            )
        );

        uint256 balance = vault.balanceOf();

        // Should only include mToken value, NOT the processed redemption
        uint256 mTokenValue = (50e18 * MOCK_MTBILL_PRICE) / 1e18;
        assertEq(balance, mTokenValue, "Balance should exclude processed redemption requests");
    }

    function testShouldExcludeCanceledRequestsFromBalance() public {
        deal(MTBILL_TOKEN, address(vault), 50e18);

        // Add pending deposit and redemption to storage
        uint256 depositRequestId = 30;
        uint256 redeemRequestId = 31;
        _addPendingDeposit(MTBILL_DEPOSIT_VAULT, depositRequestId);
        _addPendingRedemption(MTBILL_REDEMPTION_VAULT, redeemRequestId);

        // Mock both as CANCELED (status = 2)
        vm.mockCall(
            MTBILL_DEPOSIT_VAULT,
            abi.encodeWithSelector(IMidasDepositVault.mintRequests.selector, depositRequestId),
            abi.encode(
                IMidasDepositVault.Request({
                    sender: address(vault),
                    tokenIn: USDC,
                    status: 2, // Canceled
                    depositedUsdAmount: 100e18,
                    usdAmountWithoutFees: 99e18,
                    tokenOutRate: 0
                })
            )
        );
        vm.mockCall(
            MTBILL_REDEMPTION_VAULT,
            abi.encodeWithSelector(IMidasRedemptionVault.redeemRequests.selector, redeemRequestId),
            abi.encode(
                IMidasRedemptionVault.Request({
                    sender: address(vault),
                    tokenOut: USDC,
                    status: 2, // Canceled
                    amountMToken: 40e18,
                    mTokenRate: 0,
                    tokenOutRate: 0
                })
            )
        );

        uint256 balance = vault.balanceOf();

        // Should only include mToken value, NOT canceled requests
        uint256 mTokenValue = (50e18 * MOCK_MTBILL_PRICE) / 1e18;
        assertEq(balance, mTokenValue, "Balance should exclude canceled requests");
    }
}
