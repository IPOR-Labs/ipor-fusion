// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultRequestSharesFuse, PlasmaVaultRequestSharesFuseEnterData} from "../../../contracts/fuses/plasma_vault/PlasmaVaultRequestSharesFuse.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperEnterData, UniversalTokenSwapperData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {UniversalTokenSwapperSubstrateLib} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperSubstrateLib.sol";
import {Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultRedeemFromRequestFuse, PlasmaVaultRedeemFromRequestFuseEnterData} from "../../../contracts/fuses/plasma_vault/PlasmaVaultRedeemFromRequestFuse.sol";

interface CreditEnforcer {
    function mintStablecoin(uint256 amount) external returns (uint256);
}

interface PegStabilityModule {
    function redeem(uint256 amount) external;
}

contract PlasmaVaultRequestSharesTest is Test {
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant R_USD = 0x09D4214C03D01F49544C0448DBE3A27f768F2b34;

    address private constant FORTUNAFI_VAULT = 0xe9385eFf3F937FcB0f0085Da9A3F53D6C2B4fB5F;
    address private constant FORTUNAFI_ALPHA = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6;
    address private constant FORTUNAFI_WithdrawManager = 0xA90196785A133AD5f1768347Eb407fCb1B44b77d;

    address private constant TAU_VAULT = 0x9dC2819B49C3d39b11a5F4C8c0c17BD7e18126D9;
    address private constant TAU_ATOMIST = 0xf2C6a2225BE9829eD77263b032E3D92C52aE6694;
    address private constant TAU_ALPHA = 0xf2C6a2225BE9829eD77263b032E3D92C52aE6694;

    address private constant USER = TestAddresses.USER;

    address private _universalTokenSwapper;
    address private constant BalanceFuseUniversalTokenSwapper = 0xe9562d7bd06b43E6391C5bE4B3c5F5C2BC1E06Bf;
    address private constant pegStabilityModule = 0x4809010926aec940b550D34a46A52739f996D75D;
    address private constant creditEnforcer = 0x04716DB62C085D9e08050fcF6F7D775A03d07720;
    address private constant ERC20VaultBalanceFuse = 0x6cEBf3e3392D0860Ed174402884b941DCBB30654;

    address private constant IPOR_OPTIMIZER_USDC_VAULT = 0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2;

    address private constant SupplyFuseErc4626Market1 = 0x12FD0EE183c85940CAedd4877f5d3Fc637515870; //  FORTUNAFI_VAULT
    address private constant SupplyFuseErc4626Market2 = 0x83Be46881AaeBA80B3d647e08a47301Db2e4E754; // IPOR_OPTIMIZER_USDC_VAULT

    address private plasmaVaultRequestSharesFuse;
    address private plasmaVaultRedeemFromRequestFuse;
    address private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22075985);

        deal(USDC, USER, 100_000e6);

        vm.startPrank(USER);
        ERC20(USDC).approve(TAU_VAULT, 100_000e6);
        PlasmaVault(TAU_VAULT).deposit(100_000e6, USER);
        vm.stopPrank();

        // missing configuration
        addERC20VaultBalanceFuse();
        addUniversalTokenSwapper();
        setupDependenciesGraph();
        addPlasmaVaultRequestFuses();

        // IL-6952: The WITHDRAW_MANAGER storage slot was moved from the old location (which collided
        // with CALLBACK_HANDLER) to the new slot 0x465d2ff...00. The forked FORTUNAFI_VAULT still has
        // the withdraw manager at the old slot, so we write it to the new slot for the fuse to find it.
        vm.store(
            FORTUNAFI_VAULT,
            0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100,
            bytes32(uint256(uint160(FORTUNAFI_WithdrawManager)))
        );
    }

    function testShouldSwapUsdcToRUsdc() public {
        // given
        uint256 usdcAmount = 50_000e6;

        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = creditEnforcer;

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, pegStabilityModule, usdcAmount);
        data[1] = abi.encodeWithSelector(CreditEnforcer.mintStablecoin.selector, usdcAmount);

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: USDC,
            tokenOut: R_USD,
            amountIn: usdcAmount,
            minAmountOut: 0,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            _universalTokenSwapper,
            abi.encodeWithSignature("enter((address,address,uint256,uint256,(address[],bytes[])))", enterData)
        );

        uint256 usdcVaultBalanceBefore = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 rUsdcVaultBalanceBefore = ERC20(R_USD).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();
        //when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 usdcVaultBalanceAfter = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 rUsdcVaultBalanceAfter = ERC20(R_USD).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();

        assertEq(usdcVaultBalanceBefore, 100000000000, "usdcVaultBalanceBefore is not equal to 100000000000");
        assertEq(usdcVaultBalanceAfter, 50000000000, "usdcVaultBalanceAfter is not equal to 50000000000");

        assertEq(rUsdcVaultBalanceBefore, 0, "rUsdcVaultBalanceBefore is not equal to 0");
        assertEq(
            rUsdcVaultBalanceAfter,
            50000000000000000000000,
            "rUsdcVaultBalanceAfter is not equal to 50000000000000000000000"
        );

        assertEq(vaultTotalAssetsBefore, 100000000000, "vaultTotalAssetsBefore is not equal to 100000000000");
        assertEq(vaultTotalAssetsAfter, 100002029082, "vaultTotalAssetsAfter is not equal to 100002029082");
    }

    function testShouldBeAbleToDepositToFortunaFiVault() public {
        // given
        testShouldSwapUsdcToRUsdc();

        uint256 rUsdcVaultBalanceBefore = ERC20(R_USD).balanceOf(TAU_VAULT);
        uint256 usdcVaultBalanceBefore = ERC20(USDC).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();

        // Note: SupplyFuseErc4626Market1 is a deployed on-chain contract with the old 2-field struct signature
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            SupplyFuseErc4626Market1,
            abi.encodeWithSignature("enter((address,uint256))", FORTUNAFI_VAULT, rUsdcVaultBalanceBefore)
        );

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        // when

        uint256 rUsdcVaultBalanceAfter = ERC20(R_USD).balanceOf(TAU_VAULT);
        uint256 usdcVaultBalanceAfter = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 vaultTotalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();

        assertEq(usdcVaultBalanceBefore, 50000000000, "usdcVaultBalanceBefore is not equal to 50000000000");
        assertEq(usdcVaultBalanceAfter, 50000000000, "usdcVaultBalanceAfter is not equal to 50000000000");

        assertEq(
            rUsdcVaultBalanceBefore,
            50000000000000000000000,
            "rUsdcVaultBalanceBefore is not equal to 50000000000000000000000"
        );
        assertEq(rUsdcVaultBalanceAfter, 0, "rUsdcVaultBalanceAfter is not equal to 0");

        assertEq(vaultTotalAssetsBefore, 100002029082, "vaultTotalAssetsBefore is not equal to 100002029082");
        assertEq(vaultTotalAssetsAfter, 100002029082, "vaultTotalAssetsAfter is not equal to 100002029082");
    }

    function testShouldBeAbleToRequestShares() public {
        // given
        testShouldBeAbleToDepositToFortunaFiVault();
        uint256 sharesAmountBefore = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);

        bytes[] memory data = new bytes[](1);
        PlasmaVaultRequestSharesFuseEnterData memory enterData = PlasmaVaultRequestSharesFuseEnterData({
            sharesAmount: sharesAmountBefore,
            plasmaVault: FORTUNAFI_VAULT
        });
        data[0] = abi.encode(enterData);

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            plasmaVaultRequestSharesFuse,
            abi.encodeWithSignature("enter((uint256,address))", enterData)
        );

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        uint256 sharesAmountAfter = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);

        assertEq(
            sharesAmountBefore,
            4933203068300153978987452,
            "sharesAmountBefore is not equal to 4933203068300153978987452"
        );
        assertEq(
            sharesAmountAfter,
            4895730457793346009363064,
            "sharesAmountAfter is not equal to 4895730457793346009363064"
        );
    }

    function testShouldEnterUsingTransient() public {
        // given
        testShouldBeAbleToDepositToFortunaFiVault();
        uint256 sharesAmountBefore = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);

        address[] memory fuses = new address[](1);
        fuses[0] = plasmaVaultRequestSharesFuse;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(sharesAmountBefore);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(FORTUNAFI_VAULT);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse})
            )
        });

        calls[1] = FuseAction({fuse: plasmaVaultRequestSharesFuse, data: abi.encodeWithSignature("enterTransient()")});

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(calls);
        vm.stopPrank();

        // then
        uint256 sharesAmountAfter = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);

        assertEq(
            sharesAmountBefore,
            4933203068300153978987452,
            "sharesAmountBefore is not equal to 4933203068300153978987452"
        );
        assertEq(
            sharesAmountAfter,
            4895730457793346009363064,
            "sharesAmountAfter is not equal to 4895730457793346009363064"
        );
    }

    function testShouldBeAbleToRedeemFromRequest() public {
        // given
        testShouldBeAbleToRequestShares();

        uint256 sharesAmountBefore = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);
        uint256 totalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();
        uint256 rUsdVaultBalanceBefore = ERC20(R_USD).balanceOf(TAU_VAULT);

        bytes[] memory data = new bytes[](1);
        PlasmaVaultRedeemFromRequestFuseEnterData memory enterData = PlasmaVaultRedeemFromRequestFuseEnterData({
            sharesAmount: sharesAmountBefore,
            plasmaVault: FORTUNAFI_VAULT
        });
        data[0] = abi.encode(enterData);

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            plasmaVaultRedeemFromRequestFuse,
            abi.encodeWithSignature("enter((uint256,address))", enterData)
        );

        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(FORTUNAFI_ALPHA);
        WithdrawManager(FORTUNAFI_WithdrawManager).releaseFunds(block.timestamp - 100, sharesAmountBefore * 10);
        vm.stopPrank();

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        uint256 sharesAmountAfter = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);
        uint256 totalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();
        uint256 rUsdVaultBalanceAfter = ERC20(R_USD).balanceOf(TAU_VAULT);

        assertEq(
            sharesAmountBefore,
            4895730457793346009363064,
            "sharesAmountBefore is not equal to 4895730457793346009363064"
        );
        assertEq(sharesAmountAfter, 0, "sharesAmountAfter is not equal to 0");

        assertEq(totalAssetsBefore, 99622213669, "totalAssetsBefore is not equal to 99622213669");
        assertEq(totalAssetsAfter, 99622082952, "totalAssetsAfter is not equal to 99622082952");

        assertEq(rUsdVaultBalanceBefore, 0, "rUsdVaultBalanceBefore is not equal to 0");
        assertEq(
            rUsdVaultBalanceAfter,
            49620183006786641511424,
            "rUsdVaultBalanceAfter is not equal to 49620183006786641511424"
        );
    }

    function testShouldRedeemFromRequestUsingTransient() public {
        // given
        testShouldBeAbleToRequestShares();

        uint256 sharesAmountBefore = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);
        uint256 totalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();
        uint256 rUsdVaultBalanceBefore = ERC20(R_USD).balanceOf(TAU_VAULT);

        vm.warp(block.timestamp + 1 hours);

        vm.startPrank(FORTUNAFI_ALPHA);
        WithdrawManager(FORTUNAFI_WithdrawManager).releaseFunds(block.timestamp - 100, sharesAmountBefore * 10);
        vm.stopPrank();

        address[] memory fuses = new address[](1);
        fuses[0] = plasmaVaultRedeemFromRequestFuse;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(sharesAmountBefore);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(FORTUNAFI_VAULT);

        FuseAction[] memory calls = new FuseAction[](2);

        calls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse})
            )
        });

        calls[1] = FuseAction({
            fuse: plasmaVaultRedeemFromRequestFuse,
            data: abi.encodeWithSignature("enterTransient()")
        });

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(calls);
        vm.stopPrank();

        // then
        uint256 sharesAmountAfter = ERC20(FORTUNAFI_VAULT).balanceOf(TAU_VAULT);
        uint256 totalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();
        uint256 rUsdVaultBalanceAfter = ERC20(R_USD).balanceOf(TAU_VAULT);

        assertEq(
            sharesAmountBefore,
            4895730457793346009363064,
            "sharesAmountBefore is not equal to 4895730457793346009363064"
        );
        assertEq(sharesAmountAfter, 0, "sharesAmountAfter is not equal to 0");

        assertEq(totalAssetsBefore, 99622213669, "totalAssetsBefore is not equal to 99622213669");
        assertEq(totalAssetsAfter, 99622082952, "totalAssetsAfter is not equal to 99622082952");

        assertEq(rUsdVaultBalanceBefore, 0, "rUsdVaultBalanceBefore is not equal to 0");
        assertEq(
            rUsdVaultBalanceAfter,
            49620183006786641511424,
            "rUsdVaultBalanceAfter is not equal to 49620183006786641511424"
        );
    }

    function testShouldSwapRUsdToUsdc() public {
        testShouldSwapUsdcToRUsdc();

        uint256 redeemAmount = 50_000e6;
        uint256 usdcVaultBalanceBefore = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 rUsdcVaultBalanceBefore = ERC20(R_USD).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();

        address[] memory targets = new address[](2);
        targets[0] = R_USD;
        targets[1] = pegStabilityModule;

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ERC20.approve.selector, pegStabilityModule, rUsdcVaultBalanceBefore);
        data[1] = abi.encodeWithSelector(PegStabilityModule.redeem.selector, redeemAmount);

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: R_USD,
            tokenOut: USDC,
            amountIn: rUsdcVaultBalanceBefore,
            minAmountOut: 0,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            _universalTokenSwapper,
            abi.encodeWithSignature("enter((address,address,uint256,uint256,(address[],bytes[])))", enterData)
        );

        //when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 usdcVaultBalanceAfter = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 rUsdcVaultBalanceAfter = ERC20(R_USD).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();

        assertEq(usdcVaultBalanceBefore, 50000000000, "usdcVaultBalanceBefore is not equal to 50000000000");
        assertEq(usdcVaultBalanceAfter, 100000000000, "usdcVaultBalanceAfter is not equal to 100000000000");

        assertEq(
            rUsdcVaultBalanceBefore,
            50000000000000000000000,
            "rUsdcVaultBalanceBefore is not equal to 50000000000000000000000"
        );
        assertEq(rUsdcVaultBalanceAfter, 0, "rUsdcVaultBalanceAfter is not equal to 0");

        assertEq(vaultTotalAssetsBefore, 100002029082, "vaultTotalAssetsBefore is not equal to 100002029082");
        assertEq(vaultTotalAssetsAfter, 100000000000, "vaultTotalAssetsAfter is not equal to 100000000000");
    }

    function testShouldTransferToIporOptimizerUsdcVault() public {
        // given
        uint256 usdcAmount = 50_000e6;

        // Note: SupplyFuseErc4626Market2 is a deployed on-chain contract with the old 2-field struct signature
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            SupplyFuseErc4626Market2,
            abi.encodeWithSignature("enter((address,uint256))", IPOR_OPTIMIZER_USDC_VAULT, usdcAmount)
        );

        uint256 usdcVaultBalanceBefore = ERC20(USDC).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 usdcVaultBalanceAfter = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 vaultTotalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();

        assertEq(usdcVaultBalanceBefore, 100000000000, "usdcVaultBalanceBefore is not equal to 100000000000");
        assertEq(usdcVaultBalanceAfter, 50000000000, "usdcVaultBalanceAfter is not equal to 50000000000");

        assertEq(vaultTotalAssetsBefore, 100000000000, "vaultTotalAssetsBefore is not equal to 100000000000");
        assertEq(vaultTotalAssetsAfter, 99999999999, "vaultTotalAssetsAfter is not equal to 99999999999");
    }

    function testShouldBeAbleToWithdrawFromIporOptimizerUsdcVault() public {
        // given
        uint256 usdcAmount = 40_000e6;

        testShouldTransferToIporOptimizerUsdcVault();

        // Note: SupplyFuseErc4626Market2 is a deployed on-chain contract with the old 2-field struct signature
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            SupplyFuseErc4626Market2,
            abi.encodeWithSignature("exit((address,uint256))", IPOR_OPTIMIZER_USDC_VAULT, usdcAmount)
        );

        uint256 usdcVaultBalanceBefore = ERC20(USDC).balanceOf(TAU_VAULT);

        uint256 vaultTotalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();

        vm.warp(block.timestamp + 1000);

        // when
        vm.startPrank(TAU_ALPHA);
        PlasmaVault(TAU_VAULT).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 usdcVaultBalanceAfter = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 vaultTotalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();

        assertEq(usdcVaultBalanceBefore, 50000000000, "usdcVaultBalanceBefore is not equal to 50000000000");
        assertEq(usdcVaultBalanceAfter, 90000000000, "usdcVaultBalanceAfter is not equal to 90000000000");

        assertEq(vaultTotalAssetsBefore, 99999999999, "vaultTotalAssetsBefore is not equal to 99999999999");
        assertEq(vaultTotalAssetsAfter, 99999976456, "vaultTotalAssetsAfter is not equal to 99999976456");
    }

    function testShouldBeableToWithdrawUsingInstantWithdraw() public {
        // given
        uint256 withdrawAmount = 70_000e6;

        testShouldTransferToIporOptimizerUsdcVault();

        uint256 usdcVaultBalanceBefore = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 vaultTotalAssetsBefore = PlasmaVault(TAU_VAULT).totalAssets();

        vm.warp(block.timestamp + 1000);

        // when
        vm.startPrank(USER);
        PlasmaVault(TAU_VAULT).withdraw(withdrawAmount, USER, USER);
        vm.stopPrank();

        // then
        uint256 usdcVaultBalanceAfter = ERC20(USDC).balanceOf(TAU_VAULT);
        uint256 vaultTotalAssetsAfter = PlasmaVault(TAU_VAULT).totalAssets();

        assertEq(usdcVaultBalanceBefore, 50000000000, "usdcVaultBalanceBefore is not equal to 50000000000");
        assertEq(usdcVaultBalanceAfter, 10, "usdcVaultBalanceAfter is not equal to 10");

        assertEq(vaultTotalAssetsBefore, 99999999999, "vaultTotalAssetsBefore is not equal to 99999999999");
        assertEq(vaultTotalAssetsAfter, 30000008165, "vaultTotalAssetsAfter is not equal to 30000008165");
    }

    function addERC20VaultBalanceFuse() private {
        vm.startPrank(TAU_ATOMIST);
        PlasmaVaultGovernance(TAU_VAULT).addBalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE, ERC20VaultBalanceFuse);
        vm.stopPrank();

        bytes32[] memory erc20VaultBalanceTokens = new bytes32[](1);
        erc20VaultBalanceTokens[0] = PlasmaVaultConfigLib.addressToBytes32(R_USD);

        vm.startPrank(TAU_ATOMIST);
        PlasmaVaultGovernance(TAU_VAULT).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20VaultBalanceTokens
        );
        vm.stopPrank();
    }

    function addUniversalTokenSwapper() private {
        // Create new fuse instance with updated constructor
        _universalTokenSwapper = address(new UniversalTokenSwapperFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER));

        address[] memory fuses = new address[](1);
        fuses[0] = _universalTokenSwapper;

        address[] memory balanceFuses = new address[](1);
        balanceFuses[0] = BalanceFuseUniversalTokenSwapper;

        vm.startPrank(TAU_ATOMIST);
        PlasmaVaultGovernance(TAU_VAULT).addFuses(fuses);
        PlasmaVaultGovernance(TAU_VAULT).addBalanceFuse(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            BalanceFuseUniversalTokenSwapper
        );
        vm.stopPrank();

        // Using new substrate encoding format
        bytes32[] memory universalSwapSubstrates = new bytes32[](6);
        // Token substrates
        universalSwapSubstrates[0] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDC);
        universalSwapSubstrates[1] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(R_USD);
        // Target substrates
        universalSwapSubstrates[2] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(USDC);
        universalSwapSubstrates[3] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(R_USD);
        universalSwapSubstrates[4] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(pegStabilityModule);
        universalSwapSubstrates[5] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(creditEnforcer);

        vm.startPrank(TAU_ATOMIST);
        PlasmaVaultGovernance(TAU_VAULT).grantMarketSubstrates(
            IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER,
            universalSwapSubstrates
        );
        vm.stopPrank();
    }

    function setupDependenciesGraph() private {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER;
        marketIds[1] = IporFusionMarkets.ERC4626_0001;

        uint256[][] memory dependencies = new uint256[][](2);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        dependencies[1] = new uint256[](1);
        dependencies[1][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        vm.startPrank(TAU_ATOMIST);
        PlasmaVaultGovernance(TAU_VAULT).updateDependencyBalanceGraphs(marketIds, dependencies);
        vm.stopPrank();
    }

    function addPlasmaVaultRequestFuses() private {
        plasmaVaultRequestSharesFuse = address(new PlasmaVaultRequestSharesFuse(IporFusionMarkets.ERC4626_0001));
        plasmaVaultRedeemFromRequestFuse = address(
            new PlasmaVaultRedeemFromRequestFuse(IporFusionMarkets.ERC4626_0001)
        );
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        address[] memory fuses = new address[](3);
        fuses[0] = plasmaVaultRequestSharesFuse;
        fuses[1] = plasmaVaultRedeemFromRequestFuse;
        fuses[2] = _transientStorageSetInputsFuse;

        vm.startPrank(TAU_ATOMIST);
        PlasmaVaultGovernance(TAU_VAULT).addFuses(fuses);
        vm.stopPrank();
    }
}
