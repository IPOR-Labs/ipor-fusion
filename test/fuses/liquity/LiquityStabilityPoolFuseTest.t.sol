// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {LiquityStabilityPoolFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityStabilityPoolFuse.sol";
import {LiquityBalanceFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityBalanceFuse.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperData, UniversalTokenSwapperEnterData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStabilityPool} from "../../../contracts/fuses/chains/ethereum/liquity/ext/IStabilityPool.sol";
import {SwapExecutor} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";

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
    address internal constant ETH_REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address internal constant WSTETH_REGISTRY = 0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54;
    address internal constant RETH_REGISTRY = 0x6106046F031a22713697e04C08B330dDaf3e8789;

    MockDex private mockDex;

    PlasmaVault private plasmaVault;
    LiquityStabilityPoolFuse private sbFuse;
    LiquityBalanceFuse private balanceFuse;
    UniversalTokenSwapperFuse private swapFuse;
    address private accessManager;
    address private priceOracle;

    uint256 private totalBoldInVault;
    uint256 private totalBoldToDeposit;
    uint256 private totalBoldToExit;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22631293);
        address[] memory assets = new address[](2);
        assets[0] = BOLD;
        assets[1] = WETH;
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        implementation.initialize(address(this));

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        priceFeeds[1] = priceFeeds[0];

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
                type(uint256).max,
                address(0)
            )
        );
    }

    function testShouldEnterToLiquitySB() public {
        totalBoldInVault = 300000 * 1e18;
        totalBoldToDeposit = 200000 * 1e18;
        // deposit BOLD to the PlasmaVault
        deal(BOLD, address(this), totalBoldInVault);
        ERC20(BOLD).approve(address(plasmaVault), totalBoldInVault);
        plasmaVault.deposit(totalBoldInVault, address(this));

        // enter Stability Pool
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("enter(uint256)", totalBoldToDeposit));
        plasmaVault.execute(enterCalls);

        // check the balance in PlasmaVault and Stability Pool
        uint256 balance = ERC20(BOLD).balanceOf(address(plasmaVault));
        assertEq(
            balance,
            totalBoldInVault - totalBoldToDeposit,
            "Balance should be zero after entering Stability Pool"
        );
        uint256 sbBalance = IStabilityPool(sbFuse.stabilityPool()).deposits(address(plasmaVault));
        assertEq(sbBalance, totalBoldToDeposit, "Stability Pool deposits should match the deposited amount");
    }

    function testShouldExitFromLiquitySB() public {
        testShouldEnterToLiquitySB();
        totalBoldToExit = 100000 * 1e18;
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit(uint256)", totalBoldToExit));
        plasmaVault.execute(exitCalls);
        uint256 balance = ERC20(BOLD).balanceOf(address(plasmaVault));
        assertEq(
            balance,
            totalBoldInVault - totalBoldToDeposit + totalBoldToExit,
            "Balance should be equal to the exited amount from Stability Pool"
        );
        uint256 sbBalance = IStabilityPool(sbFuse.stabilityPool()).deposits(address(plasmaVault));
        assertEq(
            sbBalance,
            totalBoldToDeposit - totalBoldToExit,
            "Stability Pool deposits should match the remaining amount after exit"
        );
    }

    function testShouldClaimCollateralFromLiquitySP() public {
        testShouldEnterToLiquitySB();

        IStabilityPool stabilityPool = IStabilityPool(sbFuse.stabilityPool());

        // simulate liquidation and trigger update (only prank troveManager here)
        vm.prank(address(stabilityPool.troveManager()));
        stabilityPool.offset(100000000, 100 ether);

        // entering again stability pool to trigger collateral claim
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(address(sbFuse), abi.encodeWithSignature("exit(uint256)", 1));
        plasmaVault.execute(exitCalls);

        uint256 balance = ERC20(WETH).balanceOf(address(plasmaVault));
        assertGt(balance, 0, "Balance should be greater than zero after claiming collateral");
    }

    function testShouldClaimCollateralFromLiquitySPThenSwap() public {
        testShouldClaimCollateralFromLiquitySP();

        // Swap WETH to BOLD using the mock dex
        uint256 amountToSwap = ERC20(WETH).balanceOf(address(plasmaVault));
        assertGt(amountToSwap, 0, "There should be WETH to swap");

        // create swap data
        address[] memory targets = new address[](3);
        targets[0] = WETH;
        targets[1] = address(mockDex);
        targets[2] = WETH;
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), amountToSwap);
        data[1] = abi.encodeWithSignature("swap(uint256,uint256)", amountToSwap, 1e10);
        data[2] = abi.encodeWithSignature("approve(address,uint256)", address(mockDex), 0);
        UniversalTokenSwapperData memory swapData = UniversalTokenSwapperData({targets: targets, data: data});

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: WETH,
            tokenOut: BOLD,
            amountIn: amountToSwap,
            data: swapData
        });

        // execute the swap
        FuseAction[] memory swapCalls = new FuseAction[](1);
        swapCalls[0] = FuseAction(
            address(swapFuse),
            abi.encodeWithSignature("enter((address,address,uint256,(address[],bytes[])))", enterData)
        );

        uint256 initialBoldBalance = ERC20(BOLD).balanceOf(address(plasmaVault));
        plasmaVault.execute(swapCalls);

        // check the balance after swap
        uint256 boldBalance = ERC20(BOLD).balanceOf(address(plasmaVault));
        assertEq(boldBalance, initialBoldBalance + 1e10, "BOLD should be obtained after the swap");
        uint256 wethBalance = ERC20(WETH).balanceOf(address(plasmaVault));
        assertEq(wethBalance, 0, "WETH balance should be zero after the swap");
    }

    function _setupMarketConfigs(
        address _mockDex
    ) private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);
        bytes32[] memory registries = new bytes32[](6);
        registries[0] = PlasmaVaultConfigLib.addressToBytes32(ETH_REGISTRY);
        registries[1] = PlasmaVaultConfigLib.addressToBytes32(WSTETH_REGISTRY);
        registries[2] = PlasmaVaultConfigLib.addressToBytes32(RETH_REGISTRY);
        registries[3] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        registries[4] = PlasmaVaultConfigLib.addressToBytes32(BOLD);
        registries[5] = PlasmaVaultConfigLib.addressToBytes32(_mockDex);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.LIQUITY_V2, registries);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        sbFuse = new LiquityStabilityPoolFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);
        swapFuse = new UniversalTokenSwapperFuse(IporFusionMarkets.LIQUITY_V2, address(new SwapExecutor()), 1e18);
        fuses = new address[](2);
        fuses[0] = address(sbFuse);
        fuses[1] = address(swapFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new LiquityBalanceFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);
        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.LIQUITY_V2, address(balanceFuse));
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
