// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {LiquityStabilityPoolFuse} from "../../../contracts/fuses/liquity/LiquityStabilityPoolFuse.sol";
import {LiquityBalanceFuse} from "../../../contracts/fuses/liquity/LiquityBalanceFuse.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStabilityPool} from "../../../contracts/fuses/liquity/ext/IStabilityPool.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/liquity/ext/IAddressesRegistry.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {UniversalReader} from "../../../contracts/universal_reader/UniversalReader.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";

contract MockDex {
    address tokenIn;
    address tokenOut;

    constructor(address _tokenIn, address _tokenOut) {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
    }

    function swap(uint256 amountIn, uint256 amountOut) public {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        ERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

contract LiquityStabilityPoolFuseTest is Test {
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;

    address internal constant ETH_REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address internal constant WSTETH_REGISTRY = 0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54;
    address internal constant RETH_REGISTRY = 0x6106046F031a22713697e04C08B330dDaf3e8789;

    MockDex private mockDex;

    PlasmaVault private plasmaVault;
    LiquityStabilityPoolFuse private sbFuse;
    LiquityBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    UniversalTokenSwapperFuse private swapFuse;
    address private accessManager;
    address private priceOracle;

    uint256 private totalBoldInVault;
    uint256 private totalBoldToDeposit;
    uint256 private totalBoldToExit;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22631293);
        address[] memory assets = new address[](4);
        assets[0] = BOLD;
        assets[1] = WETH;
        assets[2] = WSTETH;
        assets[3] = RETH;
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        implementation.initialize(address(this));

        address[] memory priceFeeds = new address[](4);
        priceFeeds[0] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // we use USDC price feed for BOLD
        priceFeeds[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WETH price feed
        priceFeeds[2] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WSTETH price feed
        priceFeeds[3] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // RETH price feed

        implementation.setAssetsPricesSources(assets, priceFeeds);
        priceOracle = address(implementation);

        mockDex = new MockDex(WETH, BOLD);
        deal(BOLD, address(mockDex), 1e6 * 1e6);

        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvBOLD",
                BOLD,
                priceOracle,
                _setupMarketConfigs(address(mockDex)),
                _setupFuses(),
                _setupBalanceFuses(),
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager))
            )
        );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs(address(mockDex))
        );

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence; // Liquity -> ERC20_VAULT_BALANCE

        // PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
        //     IporFusionMarkets.ERC20_VAULT_BALANCE,
        //     address(erc20BalanceFuse)
        // );
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(dependence, dependenceMarkets);
    }

    function testShouldEnterToLiquitySB() public {
        // given
        totalBoldInVault = 300000 * 1e18;
        totalBoldToDeposit = 200000 * 1e18;

        deal(BOLD, address(this), totalBoldInVault);
        ERC20(BOLD).approve(address(plasmaVault), totalBoldInVault);
        plasmaVault.deposit(totalBoldInVault, address(this));

        uint256 assetBefore = plasmaVault.totalAssets();
        // when
        LiquityStabilityPoolFuse.LiquityStabilityPoolFuseEnterData memory enterData = LiquityStabilityPoolFuse
            .LiquityStabilityPoolFuseEnterData({registry: ETH_REGISTRY, amount: totalBoldToDeposit});
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("enter((address,uint256))", enterData));
        plasmaVault.execute(enterCalls); // when is is called the liquidity market balance is updated

        // then
        // check the balance in PlasmaVault and Stability Pool
        uint256 assetAfter = plasmaVault.totalAssets();

        uint256 balance = ERC20(BOLD).balanceOf(address(plasmaVault));
        assertEq(
            balance,
            totalBoldInVault - totalBoldToDeposit,
            "Balance should be zero after entering Stability Pool"
        );
        uint256 sbBalance = IStabilityPool(IAddressesRegistry(ETH_REGISTRY).stabilityPool()).deposits(
            address(plasmaVault)
        );
        assertEq(sbBalance, totalBoldToDeposit, "Stability Pool deposits should match the deposited amount");
        assertEq(assetAfter, assetBefore, "Assets should be equal to the initial assets");
    }

    function testShouldExitFromLiquitySB() public {
        // given
        testShouldEnterToLiquitySB();
        totalBoldToExit = 100000 * 1e18;

        // when
        LiquityStabilityPoolFuse.LiquityStabilityPoolFuseExitData memory exitData = LiquityStabilityPoolFuse
            .LiquityStabilityPoolFuseExitData({registry: ETH_REGISTRY, amount: totalBoldToExit});
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit((address,uint256))", exitData));
        plasmaVault.execute(exitCalls);

        // then
        uint256 balance = ERC20(BOLD).balanceOf(address(plasmaVault));
        assertEq(
            balance,
            totalBoldInVault - totalBoldToDeposit + totalBoldToExit,
            "Balance should be equal to the exited amount from Stability Pool"
        );
        uint256 sbBalance = IStabilityPool(IAddressesRegistry(ETH_REGISTRY).stabilityPool()).deposits(
            address(plasmaVault)
        );
        assertEq(
            sbBalance,
            totalBoldToDeposit - totalBoldToExit,
            "Stability Pool deposits should match the remaining amount after exit"
        );
    }

    function testShouldClaimCollateralFromLiquitySP() public {
        // given
        testShouldEnterToLiquitySB();

        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(ETH_REGISTRY).stabilityPool());

        // simulate liquidation and trigger update (only prank troveManager here)
        vm.prank(address(stabilityPool.troveManager()));
        stabilityPool.offset(1e18, 100 ether);

        // when
        LiquityStabilityPoolFuse.LiquityStabilityPoolFuseExitData memory exitData = LiquityStabilityPoolFuse
            .LiquityStabilityPoolFuseExitData({registry: ETH_REGISTRY, amount: 1});
        FuseAction[] memory exitCalls = new FuseAction[](1);
        // exiting from stability pool to trigger collateral claim
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit((address,uint256))", exitData));
        plasmaVault.execute(exitCalls);

        // then
        uint256 balance = ERC20(WETH).balanceOf(address(plasmaVault));
        assertGt(balance, 0, "Balance should be greater than zero after claiming collateral");
    }

    function testShouldClaimCollateralFromLiquitySPThenSwap() public {
        // given
        testShouldClaimCollateralFromLiquitySP();

        // Swap WETH to BOLD using the mock dex
        uint256 amountToSwap = ERC20(WETH).balanceOf(address(plasmaVault));
        assertGt(amountToSwap, 0, "There should be WETH to swap");

        address[] memory targets = new address[](3);
        targets[0] = WETH;
        targets[1] = address(mockDex);
        targets[2] = WETH;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), amountToSwap);
        data[1] = abi.encodeWithSignature("swap(uint256,uint256)", amountToSwap, 1e10);
        data[2] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), 0);
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({targets: targets, data: data});

        // when
        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: WETH,
            tokenOut: BOLD,
            amountIn: amountToSwap,
            data: swapData
        });

        FuseAction[] memory swapCalls = new FuseAction[](1);
        swapCalls[0] = FuseAction(
            address(swapFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
        );

        uint256 initialBoldBalance = ERC20(BOLD).balanceOf(address(plasmaVault));
        plasmaVault.execute(swapCalls);

        // then
        uint256 boldBalance = ERC20(BOLD).balanceOf(address(plasmaVault));
        assertEq(boldBalance, initialBoldBalance + 1e10, "BOLD should be obtained after the swap");
        uint256 wethBalance = ERC20(WETH).balanceOf(address(plasmaVault));
        assertEq(wethBalance, 0, "WETH balance should be zero after the swap");
    }

    function testShouldUpdateBalanceWhenProvidingAndLiquidatingToLiquity() external {
        // given
        uint256 initialBalance = plasmaVault.totalAssets();
        assertEq(initialBalance, 0, "Initial balance should be zero");

        deal(BOLD, address(this), 1000 ether);
        ERC20(BOLD).approve(address(plasmaVault), 1000 ether);
        plasmaVault.deposit(1000 ether, address(this));
        initialBalance = plasmaVault.totalAssets();
        assertEq(initialBalance, 1000 ether, "Balance should be 1000 BOLD after dealing");

        // when
        LiquityStabilityPoolFuse.LiquityStabilityPoolFuseEnterData memory enterData = LiquityStabilityPoolFuse
            .LiquityStabilityPoolFuseEnterData({registry: ETH_REGISTRY, amount: 500 ether});
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("enter((address,uint256))", enterData));
        plasmaVault.execute(enterCalls); // when is is called the liquidity market balance is updated

        uint256 afterDepBalance = plasmaVault.totalAssets();
        assertEq(afterDepBalance, initialBalance, "Balance should not change after providing to SP");

        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(ETH_REGISTRY).stabilityPool());
        vm.prank(address(stabilityPool.troveManager()));
        stabilityPool.offset(1e18, 100 ether);

        LiquityStabilityPoolFuse.LiquityStabilityPoolFuseExitData memory exitData = LiquityStabilityPoolFuse
            .LiquityStabilityPoolFuseExitData({registry: ETH_REGISTRY, amount: 1});
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit((address,uint256))", exitData));
        plasmaVault.execute(exitCalls);

        // then
        uint256 afterLiquidationBalance = plasmaVault.totalAssets();
        assertGt(afterLiquidationBalance, afterDepBalance, "Balance should increase after liquidation");
    }

    function _calculateBalance() private view returns (uint256) {
        bytes memory balanceOfCall = abi.encodeWithSignature("balanceOf()");
        uint256 balance = abi.decode(
            UniversalReader(address(plasmaVault)).read(address(balanceFuse), balanceOfCall).data,
            (uint256)
        );
        return balance;
    }

    function _calculateErc20Balance() private view returns (uint256) {
        bytes memory balanceOfCall = abi.encodeWithSignature("balanceOf()");
        uint256 balance = abi.decode(
            UniversalReader(address(plasmaVault)).read(address(erc20BalanceFuse), balanceOfCall).data,
            (uint256)
        );
        return balance;
    }

    function _setupMarketConfigs(
        address _mockDex
    ) private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](3);
        bytes32[] memory registries = new bytes32[](3);
        registries[0] = PlasmaVaultConfigLib.addressToBytes32(ETH_REGISTRY);
        registries[1] = PlasmaVaultConfigLib.addressToBytes32(WSTETH_REGISTRY);
        registries[2] = PlasmaVaultConfigLib.addressToBytes32(RETH_REGISTRY);
        bytes32[] memory swapperAssets = new bytes32[](3);
        swapperAssets[0] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        swapperAssets[1] = PlasmaVaultConfigLib.addressToBytes32(BOLD);
        swapperAssets[2] = PlasmaVaultConfigLib.addressToBytes32(_mockDex);
        bytes32[] memory erc20Assets = new bytes32[](1);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(BOLD);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.LIQUITY_V2, registries);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, swapperAssets);
        marketConfigs_[2] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        sbFuse = new LiquityStabilityPoolFuse(IporFusionMarkets.LIQUITY_V2);
        swapFuse = new UniversalTokenSwapperFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            address(new SwapExecutor()),
            1e18
        );

        fuses = new address[](2);
        fuses[0] = address(sbFuse);
        fuses[1] = address(swapFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new LiquityBalanceFuse(IporFusionMarkets.LIQUITY_V2);
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.LIQUITY_V2, address(balanceFuse));
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

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), IporFusionAccessManager(accessManager));
    }
}
