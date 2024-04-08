// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../../contracts/vaults/Vault.sol";
import {FlashLoanMorphoFuse} from "../../contracts/vaults/FlashLoanMorphoFuse.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse} from "../../contracts/vaults/AaveV3BorrowFuse.sol";
import {NativeSwapWethToWstEthFuse} from "../../contracts/vaults/NativeSwapWEthToWstEthFuse.sol";
import {PriceAdapter} from "../../contracts/vaults/PriceAdapter.sol";
import {AaveV3BalanceFuse} from "../../contracts/vaults/AaveV3BalanceFuse.sol";

import {FuseConfig} from "../../contracts/vaults/FuseConfig.sol";
import {MarketConfigurationLib} from "../../contracts/libraries/MarketConfigurationLib.sol";

contract ForkAmmGovernanceServiceTest is Test {
    address public constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    address payable public vaultWstEth;
    address public flashLoanMorphoFuse;
    address public aaveV3SupplyFuse;
    address public aaveV3BorrowFuse;
    address public nativeSwapWethToWstEthFuse;
    address public balanceFuse;

    FuseConfig public fuseConfig;

    bytes32 internal aaveV3MarketName = bytes32("AaveV3");
    uint256 internal aaveV3MarketId;

    address internal priceAdapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19368505);

        priceAdapter = address(new PriceAdapter());

        balanceFuse = address(new AaveV3BalanceFuse(aaveV3MarketId, aaveV3MarketName, priceAdapter));

        fuseConfig = new FuseConfig();
        aaveV3MarketId = fuseConfig.addMarket(aaveV3MarketName, balanceFuse);

        address[] memory keepers = new address[](1);
        keepers[0] = address(this);

        flashLoanMorphoFuse = address(new FlashLoanMorphoFuse());
        aaveV3SupplyFuse = address(new AaveV3SupplyFuse(AAVE_POOL, aaveV3MarketId));
        aaveV3BorrowFuse = address(new AaveV3BorrowFuse(aaveV3MarketId, aaveV3MarketName));
        nativeSwapWethToWstEthFuse = address(new NativeSwapWethToWstEthFuse());
        balanceFuse = address(new AaveV3BalanceFuse(aaveV3MarketId, aaveV3MarketName, priceAdapter));

        address[] memory fuses = new address[](5);
        fuses[0] = flashLoanMorphoFuse;
        fuses[1] = aaveV3SupplyFuse;
        fuses[2] = aaveV3BorrowFuse;
        fuses[3] = nativeSwapWethToWstEthFuse;
        fuses[4] = balanceFuse;

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](1);
        balanceFuses[0] = Vault.FuseStruct({marketId: aaveV3MarketId, fuse: balanceFuse});

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](1);

        bytes32[] memory marketAssets = new bytes32[](2);
        marketAssets[0] = MarketConfigurationLib.addressToBytes32(WST_ETH);
        marketAssets[1] = MarketConfigurationLib.addressToBytes32(W_ETH);

        marketConfigs[0] = Vault.MarketConfig({marketId: aaveV3MarketId, substrates: marketAssets});

        vaultWstEth = payable(
            new Vault(msg.sender, "ipvwstETH", "IP Vault wstETH", WST_ETH, keepers, marketConfigs, fuses, balanceFuses)
        );

        priceAdapter = address(new PriceAdapter());
    }

    function skipTestShouldWork() public {
        uint256 initialAmount = 40 * 1e18;
        deal(WST_ETH, address(this), initialAmount);

        IERC20(WST_ETH).approve(vaultWstEth, initialAmount);

        //        uint256 amountVaultBeforeDeposit = IERC20(wstETH).balanceOf(vaultWstEth);
        //        console2.log("amountVaultBeforeDeposit", amountVaultBeforeDeposit);

        Vault(vaultWstEth).deposit(initialAmount, address(this));

        //        uint256 amountVaultAfterDeposit = IERC20(wstETH).balanceOf(vaultWstEth);
        //        console2.log("amountVaultAfterDeposit", amountVaultAfterDeposit);

        Vault.FuseAction[] memory calls = new Vault.FuseAction[](1);

        Vault.FuseAction[] memory flashLoanCalls = new Vault.FuseAction[](5);

        flashLoanCalls[0] = Vault.FuseAction(
            aaveV3SupplyFuse,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyFuse.AaveV3SupplyFuseData({
                        asset: WST_ETH,
                        amount: 40 * 1e18,
                        userEModeCategoryId: 1e18
                    })
                )
            )
        );

        flashLoanCalls[1] = Vault.FuseAction(
            aaveV3BorrowFuse,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3BorrowFuse.BorrowData({asset: W_ETH, amount: 30 * 1e18}))
            )
        );

        flashLoanCalls[2] = Vault.FuseAction(
            nativeSwapWethToWstEthFuse,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(NativeSwapWethToWstEthFuse.SwapData({wEthAmount: 30 * 1e18}))
            )
        );

        flashLoanCalls[3] = Vault.FuseAction(
            balanceFuse,
            abi.encodeWithSignature("balanceOf(address,address,address)", address(vaultWstEth), WST_ETH, WST_ETH)
        );

        flashLoanCalls[4] = Vault.FuseAction(
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

        calls[0] = Vault.FuseAction(flashLoanMorphoFuse, abi.encodeWithSignature("enter(bytes)", data));

        Vault(payable(vaultWstEth)).execute(calls);
    }
}
