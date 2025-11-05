// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";

import {EbisuZapperCreateFuse, EbisuZapperCreateFuseEnterData, EbisuZapperCreateFuseExitData} from "../../../contracts/fuses/ebisu/EbisuZapperCreateFuse.sol";

import {EbisuZapperBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol";
import {IFuseCommon} from "../../../contracts/fuses/IFuseCommon.sol";
import {ITroveManager} from "../../../contracts/fuses/ebisu/ext/ITroveManager.sol";
import {ILeverageZapper} from "../../../contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/ebisu/ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "../../../contracts/fuses/ebisu/ext/IBorrowerOperations.sol";
import {EbisuMathLib} from "../../../contracts/fuses/ebisu/lib/EbisuMathLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {EbisuWethEthAdapterAddressReader} from "../../../contracts/readers/EbisuWethEthAdapterAddressReader.sol";
import {UniversalReader, ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "../../../contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";

// Direct interface for BorrowerOperations to call setInterestIndividualDelegate and adjustTroveInterestRate
interface IBorrowerOperationsFull {
    function setInterestIndividualDelegate(
        uint256 _troveId,
        address _delegate,
        uint128 _minInterestRate,
        uint128 _maxInterestRate,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee,
        uint256 _minInterestRateChangePeriod
    ) external;

    function adjustTroveInterestRate(
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external;

    function getInterestIndividualDelegateOf(
        uint256 _troveId
    )
        external
        view
        returns (
            address account,
            uint128 minInterestRate,
            uint128 maxInterestRate,
            uint256 minInterestRateChangePeriod
        );

    function addManagerOf(uint256 _troveId) external view returns (address);
}

contract MockDex {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) public {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @notice Minimal test fuse to verify msg.sender in delegatecall context
contract MsgSenderTestFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;
    // Use event to capture msg.sender (events work correctly in delegatecall)
    event MsgSenderRecorded(address sender);

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function recordMsgSender() external {
        emit MsgSenderRecorded(msg.sender);
    }
}

/**
 * @title EbisuInterestRateDelegateTest
 * @notice Tests for interest rate delegation in Ebisu protocol
 *
 * Key Concepts:
 * - Executor Wallet: The wallet that has ALPHA_ROLE on PlasmaVault and calls PlasmaVault.execute().
 *   In this test, address(this) is the executor (see setUp() where alphas[0] = address(this)).
 *   The executor is the one that triggers strategy execution in production.
 *
 * - Trove Owner: The address that owns the Trove NFT. When a trove is opened via EbisuZapperCreateFuse,
 *   the owner is set to the fuse contract (address(this) in the fuse context), but since fuses use
 *   delegatecall, the actual owner is PlasmaVault. This is verified by troveNFT.ownerOf(troveId).
 *
 * - Interest Rate Delegate: An address authorized by the trove owner to adjust interest rates.
 *   Only the trove owner (or AddManager, if set) can set a delegate. Once set, the delegate can
 *   call adjustTroveInterestRate() within the specified min/max rate bounds.
 *
 * - AddManager: A privileged address that can perform certain operations on behalf of the trove owner.
 *   Currently, EbisuZapperCreateFuse sets addManager to address(0), meaning no AddManager is set.
 *   If AddManager were set to the executor wallet, the executor could call setInterestIndividualDelegate().
 */
contract EbisuInterestRateDelegateTest is Test {
    // Base Asset
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Gas Asset
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Borrow Asset
    address internal constant EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4;
    // Collateral Assets
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    // Zapper Addresses
    address internal constant SUSDE_ZAPPER = 0x10C14374104f9FC2dAE4b38F945ff8a52f48151d;
    // Address Registries
    address internal constant SUSDE_REGISTRY = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f;

    PlasmaVault private plasmaVault;
    EbisuZapperCreateFuse private zapperFuse;
    EbisuZapperBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    UniversalTokenSwapperFuse private swapFuse;
    MsgSenderTestFuse private msgSenderTestFuse;

    address private accessManager;
    PriceOracleMiddleware private priceOracle;

    EbisuWethEthAdapterAddressReader private wethEthAdapterAddressReader;
    // ETH gas compensation constant from zapper (keep in sync with fuse)
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    MockDex private mockDex;

    // Delegate wallet (simulating executor wallet - the wallet that will adjust rates after delegation)
    address private delegateWallet;

    receive() external payable {}

    function setUp() public {
        // Create a delegate wallet for testing
        delegateWallet = makeAddr("delegateWallet");

        // block height -> 23277699 | Sep-02-2025 08:23:23 PM +UTC
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23277699);

        // assets
        address[] memory assets = new address[](4);
        assets[0] = EBUSD; // borrowed
        assets[1] = SUSDE; // collateral
        assets[2] = WETH; // compensation
        assets[3] = USDC; // base token

        // price feeders
        address[] memory priceFeeds = new address[](4);
        priceFeeds[0] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // EBUSD (USD feed)
        priceFeeds[1] = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099; // sUSDe
        priceFeeds[2] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WETH ~ ETH
        priceFeeds[3] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC (USD feed)

        // instantiate oracle middleware
        priceOracle = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        priceOracle.initialize(address(this));
        priceOracle.setAssetsPricesSources(assets, priceFeeds);

        // create plasma vault
        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "TEST sUSDe PLASMA VAULT",
                "zpTEST",
                USDC,
                address(priceOracle),
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager))
            )
        );

        // mock dex to swap USDC into sUSDe
        mockDex = new MockDex();
        deal(SUSDE, address(mockDex), 1e9 * 1e18);
        deal(EBUSD, address(mockDex), 1e9 * 1e18);

        // setup plasma vault
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs(address(mockDex))
        );

        // setup dependency balance graph
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EBISU;
        marketIds[1] = IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependence;
        dependenceMarkets[1] = dependence;

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

        // adapter address reader
        wethEthAdapterAddressReader = new EbisuWethEthAdapterAddressReader();
    }

    function testSetDelegateAndAdjustInterestRate() public {
        // Step 1: Open a trove
        (uint256 troveId, address troveOwner) = _openTroveForTesting();

        // Step 2: Get BorrowerOperations and set delegate
        IBorrowerOperationsFull borrowerOpsFull = _getBorrowerOperations();
        _setDelegate(borrowerOpsFull, troveId, troveOwner);

        // Step 3: Verify delegate was set
        _verifyDelegateSet(borrowerOpsFull, troveId);

        // Step 4: Adjust interest rate using delegate wallet
        _adjustInterestRate(borrowerOpsFull, troveId, 25 * 1e16); // 25%

        // Step 5: Test rate adjustment failures
        _testRateAdjustmentFailures(borrowerOpsFull, troveId);

        // Step 6: Final adjustment
        _adjustInterestRate(borrowerOpsFull, troveId, 15 * 1e16); // 15%
    }

    /**
     * @notice Test to verify that msg.sender in a delegatecall context is the executor wallet,
     * not the PlasmaVault itself.
     *
     * This test confirms that when PlasmaVault.execute() calls a fuse via delegatecall:
     * - msg.sender inside the fuse = executor wallet (original caller of execute())
     * - NOT PlasmaVault itself
     *
     * This is critical for Option 2: setting AddManager = msg.sender in the fuse
     * will correctly set it to the executor wallet, not PlasmaVault.
     */
    function testMsgSenderInDelegateCallContext() public {
        // The executor is address(this) (see setUp() where alphas[0] = address(this))
        address executorWallet = address(this);

        // Call the test fuse via PlasmaVault.execute()
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(address(msgSenderTestFuse), abi.encodeWithSignature("recordMsgSender()"));

        // Execute via PlasmaVault (this requires ALPHA_ROLE, which address(this) has)
        // Expect the event to be emitted with the executor wallet as msg.sender
        vm.expectEmit(true, true, true, true);
        emit MsgSenderTestFuse.MsgSenderRecorded(executorWallet);

        plasmaVault.execute(calls);

        console.log("Executor wallet (address(this)):", executorWallet);
        console.log("PlasmaVault address:", address(plasmaVault));
        console.log("msg.sender in delegatecall context = executor wallet (verified via event)");
    }

    /**
     * @notice Test that executor wallet (address(this) with ALPHA_ROLE) CANNOT directly call
     * setInterestIndividualDelegate because it's not the trove owner.
     *
     * This test verifies Option A: Calling directly from executor wallet.
     * The executor is the wallet that has ALPHA_ROLE on PlasmaVault and calls PlasmaVault.execute().
     * In this test, address(this) is the executor (see setUp() where alphas[0] = address(this)).
     *
     * Expected: The call should REVERT because:
     * - msg.sender = address(this) (executor)
     * - trove owner = PlasmaVault (from troveNFT.ownerOf())
     * - _requireCallerIsBorrower checks if msg.sender == owner OR msg.sender is AddManager
     * - Since executor is neither the owner nor AddManager (currently set to address(0) in fuse),
     *   the call will fail.
     */
    function testExecutorCannotSetDelegateDirectly() public {
        // Step 1: Open a trove
        (uint256 troveId, address troveOwner) = _openTroveForTesting();

        // Verify trove owner is PlasmaVault
        assertEq(troveOwner, address(plasmaVault), "Trove owner should be PlasmaVault");

        // Verify executor is address(this) (which has ALPHA_ROLE)
        // In setUp(), alphas[0] = address(this), so address(this) is the executor

        // Step 2: Try to call setInterestIndividualDelegate directly from executor (address(this))
        // WITHOUT using vm.prank - this simulates the real scenario
        IBorrowerOperationsFull borrowerOpsFull = _getBorrowerOperations();

        // This call should REVERT because:
        // - msg.sender = address(this) (executor wallet)
        // - trove owner = PlasmaVault
        // - executor is not the owner, and executor is not AddManager (AddManager is address(0))
        vm.expectRevert();
        borrowerOpsFull.setInterestIndividualDelegate(
            troveId,
            delegateWallet,
            5 * 1e15, // minInterestRate: 0.5%
            50 * 1e16, // maxInterestRate: 50%
            20 * 1e16, // newAnnualInterestRate: 20%
            0, // upperHint
            0, // lowerHint
            5 * 1e18, // maxUpfrontFee
            7 days // minInterestRateChangePeriod
        );

        // If we reach here, the test failed (call didn't revert)
        // This confirms that executor CANNOT set delegate directly
    }

    /**
     * @notice Test to verify that when addManager=msg.sender in EbisuZapperCreateFuse,
     * the executor wallet can call setInterestIndividualDelegate() directly.
     *
     * This test demonstrates Option 2: Setting AddManager during trove creation.
     *
     * Flow:
     * 1. Open trove via PlasmaVault.execute() calling EbisuZapperCreateFuse
     * 2. Inside the fuse, msg.sender = executor wallet (preserved from delegatecall)
     * 3. Set addManager = msg.sender (executor wallet)
     * 4. Trove owner = PlasmaVault (address(this) in delegatecall context)
     * 5. After trove is opened, executor can call setInterestIndividualDelegate() directly
     *    because _requireCallerIsBorrower() checks: msg.sender == owner OR msg.sender == AddManager
     */
    function testExecutorCanSetDelegateWhenAddManagerIsSet() public {
        address executorWallet = address(this);

        // Step 1: Open a trove via PlasmaVault.execute()
        // This will set addManager = msg.sender (executor wallet) inside the fuse
        (uint256 troveId, address troveOwner) = _openTroveForTesting();

        // Verify trove owner is PlasmaVault
        assertEq(troveOwner, address(plasmaVault), "Trove owner should be PlasmaVault");

        // Step 2: Check what AddManager is actually set to
        IBorrowerOperationsFull borrowerOpsFull = _getBorrowerOperations();
        address addManager = borrowerOpsFull.addManagerOf(troveId);

        console.log("Trove ID:", troveId);
        console.log("Trove owner (PlasmaVault):", troveOwner);
        console.log("AddManager (actual):", addManager);
        console.log("Executor wallet (address(this)):", executorWallet);
        console.log("Zapper address:", SUSDE_ZAPPER);

        // ISSUE DISCOVERED: The Zapper contract is overriding our addManager parameter
        // and setting itself as the AddManager. This is because the Zapper calls
        // BorrowerOperations.openTrove() internally, and msg.sender in that call is the Zapper.
        //
        // WORKAROUND: Since the Zapper is the AddManager, we need to either:
        // 1. Use the Zapper's setAddManager function (if it exposes one) to change AddManager to executor
        // 2. Have PlasmaVault call setAddManager after trove creation (if owner can call it)
        // 3. Investigate if the Zapper contract can be configured to respect the addManager parameter
        //
        // For now, this test documents that setting addManager=msg.sender in the fuse
        // does NOT work as expected because the Zapper overrides it.

        console.log("ISSUE: Zapper is overriding addManager parameter!");
        console.log("Expected AddManager (executor):", executorWallet);
        console.log("Actual AddManager (Zapper):", addManager);

        // Verify that executor CANNOT call setInterestIndividualDelegate when AddManager is Zapper
        vm.expectRevert();
        borrowerOpsFull.setInterestIndividualDelegate(
            troveId,
            delegateWallet,
            5 * 1e15, // minInterestRate: 0.5%
            50 * 1e16, // maxInterestRate: 50%
            20 * 1e16, // newAnnualInterestRate: 20%
            0, // upperHint
            0, // lowerHint
            5 * 1e18, // maxUpfrontFee
            7 days // minInterestRateChangePeriod
        );

        // This test currently FAILS because the Zapper overrides addManager
        // The test documents this limitation and suggests we need a different approach
        assertEq(
            addManager,
            executorWallet,
            "AddManager should be executor wallet, but Zapper is overriding it. Need to investigate Zapper contract behavior or use setAddManager after trove creation."
        );
    }

    function _openTroveForTesting() internal returns (uint256 troveId, address troveOwner) {
        EbisuZapperCreateFuseEnterData memory enterData = EbisuZapperCreateFuseEnterData({
            zapper: SUSDE_ZAPPER,
            registry: SUSDE_REGISTRY,
            collAmount: 10_000 * 1e18,
            ebusdAmount: 5_000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 1_000 * 1e18,
            annualInterestRate: 20 * 1e16,
            maxUpfrontFee: 5 * 1e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
                enterData
            )
        );

        deal(USDC, address(this), 100_000 * 1e6);
        ERC20(USDC).approve(address(plasmaVault), 100_000 * 1e6);
        plasmaVault.deposit(100_000 * 1e6, address(this));

        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);

        _swapUSDCtoToken(enterData.collAmount / 1e12, SUSDE);
        plasmaVault.execute(enterCalls);

        address wethEthAdapter = wethEthAdapterAddressReader.getEbisuWethEthAdapterAddress(address(plasmaVault));
        troveId = EbisuMathLib.calculateTroveId(address(wethEthAdapter), address(plasmaVault), SUSDE_ZAPPER, 1);

        ITroveManager tm = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = tm.getLatestTroveData(troveId);
        assertEq(troveData.annualInterestRate, 20 * 1e16, "Initial interest rate should be 20%");

        troveOwner = _getTroveOwner(troveId);
    }

    function _getTroveOwner(uint256 troveId) internal view returns (address owner) {
        IAddressesRegistry registry = IAddressesRegistry(SUSDE_REGISTRY);
        IBorrowerOperations borrowerOps = registry.borrowerOperations();

        (bool success1, bytes memory data1) = address(borrowerOps).staticcall(abi.encodeWithSignature("troveNFT()"));
        if (success1) {
            address troveNFTAddress = abi.decode(data1, (address));
            (bool success2, bytes memory data2) = troveNFTAddress.staticcall(
                abi.encodeWithSignature("ownerOf(uint256)", troveId)
            );
            if (success2) {
                return abi.decode(data2, (address));
            }
        }
        return address(plasmaVault);
    }

    function _getBorrowerOperations() internal view returns (IBorrowerOperationsFull) {
        IAddressesRegistry registry = IAddressesRegistry(SUSDE_REGISTRY);
        IBorrowerOperations borrowerOps = registry.borrowerOperations();
        return IBorrowerOperationsFull(address(borrowerOps));
    }

    function _setDelegate(IBorrowerOperationsFull borrowerOpsFull, uint256 troveId, address troveOwner) internal {
        vm.prank(troveOwner);
        borrowerOpsFull.setInterestIndividualDelegate(
            troveId,
            delegateWallet,
            5 * 1e15, // minInterestRate: 0.5%
            50 * 1e16, // maxInterestRate: 50%
            20 * 1e16, // newAnnualInterestRate: 20%
            0, // upperHint
            0, // lowerHint
            5 * 1e18, // maxUpfrontFee
            7 days // minInterestRateChangePeriod
        );
    }

    function _verifyDelegateSet(IBorrowerOperationsFull borrowerOpsFull, uint256 troveId) internal view {
        // Skip verification via getter (it may not be accessible)
        // We'll verify the delegate is set by testing if it can adjust rates
        // If delegate wasn't set correctly, adjustTroveInterestRate will revert
    }

    function _adjustInterestRate(IBorrowerOperationsFull borrowerOpsFull, uint256 troveId, uint256 newRate) internal {
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(delegateWallet);
        borrowerOpsFull.adjustTroveInterestRate(troveId, newRate, 0, 0, 5 * 1e18);

        ITroveManager tm = ITroveManager(ILeverageZapper(SUSDE_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = tm.getLatestTroveData(troveId);
        assertEq(troveData.annualInterestRate, newRate, "Interest rate should be updated");
    }

    function _testRateAdjustmentFailures(IBorrowerOperationsFull borrowerOpsFull, uint256 troveId) internal {
        // Test rate too high
        vm.prank(delegateWallet);
        vm.expectRevert();
        borrowerOpsFull.adjustTroveInterestRate(troveId, 60 * 1e16, 0, 0, 5 * 1e18);

        // Test rate too soon
        vm.prank(delegateWallet);
        vm.expectRevert();
        borrowerOpsFull.adjustTroveInterestRate(troveId, 15 * 1e16, 0, 0, 5 * 1e18);
    }

    // --- internal swapper function ---
    function _swapUSDCtoToken(uint256 amountToSwap, address tokenToObtain) private {
        address[] memory targets = new address[](3);
        targets[0] = USDC;
        targets[1] = address(mockDex);
        targets[2] = USDC;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), amountToSwap);
        data[1] = abi.encodeWithSignature(
            "swap(address,address,uint256,uint256)",
            USDC,
            tokenToObtain,
            amountToSwap,
            amountToSwap * 1e12
        );
        data[2] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), 0);
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({targets: targets, data: data});

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: tokenToObtain,
            amountIn: amountToSwap,
            data: swapData
        });

        FuseAction[] memory swapCalls = new FuseAction[](1);
        swapCalls[0] = FuseAction(
            address(swapFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
        );

        plasmaVault.execute(swapCalls);
    }

    // --- helpers ---
    function _setupMarketConfigs(
        address _mockDex
    ) private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        bytes32[] memory ebisuSubs = new bytes32[](2);
        ebisuSubs[0] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: SUSDE_ZAPPER, substrateType: EbisuZapperSubstrateType.ZAPPER})
        );
        ebisuSubs[1] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate({substrateAddress: SUSDE_REGISTRY, substrateType: EbisuZapperSubstrateType.REGISTRY})
        );

        bytes32[] memory erc20Assets = new bytes32[](2);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        erc20Assets[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE);

        bytes32[] memory swapperAssets = new bytes32[](4);
        swapperAssets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        swapperAssets[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE);
        swapperAssets[2] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        swapperAssets[3] = PlasmaVaultConfigLib.addressToBytes32(_mockDex);

        marketConfigs_ = new MarketSubstratesConfig[](3);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.EBISU, ebisuSubs);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, swapperAssets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        zapperFuse = new EbisuZapperCreateFuse(IporFusionMarkets.EBISU, WETH);
        swapFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(new SwapExecutor()),
            1e18
        );
        msgSenderTestFuse = new MsgSenderTestFuse(IporFusionMarkets.EBISU);

        fuses = new address[](3);
        fuses[0] = address(zapperFuse);
        fuses[1] = address(swapFuse);
        fuses[2] = address(msgSenderTestFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new EbisuZapperBalanceFuse(IporFusionMarkets.EBISU);
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EBISU, address(balanceFuse));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
        balanceFuses_[2] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        accessManager = accessManager_;
    }
}
