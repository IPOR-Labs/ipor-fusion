// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {FlashLoanMorphoFuse} from "../../contracts/vaults/poc/FlashLoanMorphoFuse.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse} from "../../contracts/vaults/poc/AaveV3BorrowFuse.sol";
import {NativeSwapWethToWstEthFuse} from "../../contracts/vaults/poc/NativeSwapWEthToWstEthFuse.sol";
import {PriceAdapter} from "../../contracts/vaults/poc/PriceAdapter.sol";
import {AaveV3BalanceFuse} from "../../contracts/vaults/poc/AaveV3BalanceFuse.sol";

import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/IporFusionAccessManager.sol";

contract ForkAmmGovernanceServiceTest is Test {
    address public constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public vaultWstEth;
    address public flashLoanMorphoFuse;
    address public aaveV3SupplyFuse;
    address public aaveV3BorrowFuse;
    address public nativeSwapWethToWstEthFuse;
    address public balanceFuse;

    bytes32 internal aaveV3MarketName = bytes32("AaveV3");
    uint256 internal aaveV3MarketId;

    address internal priceAdapter;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19368505);

        priceAdapter = address(new PriceAdapter());

        balanceFuse = address(new AaveV3BalanceFuse(aaveV3MarketId, aaveV3MarketName, priceAdapter));

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        flashLoanMorphoFuse = address(new FlashLoanMorphoFuse());
        aaveV3SupplyFuse = address(
            new AaveV3SupplyFuse(aaveV3MarketId, AAVE_POOL, ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3)
        );
        aaveV3BorrowFuse = address(new AaveV3BorrowFuse(aaveV3MarketId, aaveV3MarketName));
        nativeSwapWethToWstEthFuse = address(new NativeSwapWethToWstEthFuse());
        balanceFuse = address(new AaveV3BalanceFuse(aaveV3MarketId, aaveV3MarketName, priceAdapter));

        address[] memory fuses = new address[](5);
        fuses[0] = flashLoanMorphoFuse;
        fuses[1] = aaveV3SupplyFuse;
        fuses[2] = aaveV3BorrowFuse;
        fuses[3] = nativeSwapWethToWstEthFuse;
        fuses[4] = balanceFuse;

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({marketId: aaveV3MarketId, fuse: balanceFuse});

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory marketAssets = new bytes32[](2);
        marketAssets[0] = PlasmaVaultConfigLib.addressToBytes32(WST_ETH);
        marketAssets[1] = PlasmaVaultConfigLib.addressToBytes32(W_ETH);

        marketConfigs[0] = MarketSubstratesConfig({marketId: aaveV3MarketId, substrates: marketAssets});

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        vaultWstEth = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "ipvwstETH",
                    "IP PlasmaVault wstETH",
                    WST_ETH,
                    address(priceOracleMiddlewareProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses,
                    FeeConfig(address(0x777), 0, address(0x555), 0),
                    address(new IporFusionAccessManager(msg.sender))
                )
            )
        );

        priceAdapter = address(new PriceAdapter());
    }

    function skipTestShouldWork() public {
        uint256 initialAmount = 40 * 1e18;
        deal(WST_ETH, address(this), initialAmount);

        IERC20(WST_ETH).approve(vaultWstEth, initialAmount);

        //        uint256 amountVaultBeforeDeposit = IERC20(wstETH).balanceOf(vaultWstEth);
        //        console2.log("amountVaultBeforeDeposit", amountVaultBeforeDeposit);

        PlasmaVault(vaultWstEth).deposit(initialAmount, address(this));

        //        uint256 amountVaultAfterDeposit = IERC20(wstETH).balanceOf(vaultWstEth);
        //        console2.log("amountVaultAfterDeposit", amountVaultAfterDeposit);

        FuseAction[] memory calls = new FuseAction[](1);

        FuseAction[] memory flashLoanCalls = new FuseAction[](5);

        flashLoanCalls[0] = FuseAction(
            aaveV3SupplyFuse,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: WST_ETH, amount: 40 * 1e18, userEModeCategoryId: 1e18}))
            )
        );

        flashLoanCalls[1] = FuseAction(
            aaveV3BorrowFuse,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3BorrowFuse.BorrowData({asset: W_ETH, amount: 30 * 1e18}))
            )
        );

        flashLoanCalls[2] = FuseAction(
            nativeSwapWethToWstEthFuse,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(NativeSwapWethToWstEthFuse.SwapData({wEthAmount: 30 * 1e18}))
            )
        );

        flashLoanCalls[3] = FuseAction(
            balanceFuse,
            abi.encodeWithSignature("balanceOf(address,address,address)", address(vaultWstEth), WST_ETH, WST_ETH)
        );

        flashLoanCalls[4] = FuseAction(
            balanceFuse,
            abi.encodeWithSignature("balanceOf(address,address,address)", address(vaultWstEth), WST_ETH, W_ETH)
        );

        bytes memory flashLoanDataBytes = abi.encode(flashLoanCalls);

        FlashLoanMorphoFuse.FlashLoanData memory flashLoanData = FlashLoanMorphoFuse.FlashLoanData({
            asset: WST_ETH,
            /// FlashLoan 100 wstETH
            amount: 100e18,
            data: flashLoanDataBytes
        });

        bytes memory data = abi.encode(flashLoanData);

        calls[0] = FuseAction(flashLoanMorphoFuse, abi.encodeWithSignature("enter(bytes)", data));

        PlasmaVault(payable(vaultWstEth)).execute(calls);
    }
}
