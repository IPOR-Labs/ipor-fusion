// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vault} from "../../contracts/vaults/Vault.sol";
import {FlashLoanMorphoConnector} from "../../contracts/vaults/FlashLoanMorphoConnector.sol";
import {AaveV3SupplyConnector} from "../../contracts/vaults/AaveV3SupplyConnector.sol";
import {AaveV3BorrowConnector} from "../../contracts/vaults/AaveV3BorrowConnector.sol";
import {NativeSwapWethToWstEthConnector} from "../../contracts/vaults/NativeSwapWEthToWstEthConnector.sol";
import {PriceAdapter} from "../../contracts/vaults/PriceAdapter.sol";
import {AaveV3BalanceConnector} from "../../contracts/vaults/AaveV3BalanceConnector.sol";

import {ConnectorConfig} from "../../contracts/vaults/ConnectorConfig.sol";

contract ForkAmmGovernanceServiceTest is Test {
    address public constant W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address payable public vaultWstEth;
    address public flashLoanMorphoConnector;
    address public aaveV3SupplyConnector;
    address public aaveV3BorrowConnector;
    address public nativeSwapWethToWstEthConnector;
    address public balanceConnector;

    ConnectorConfig public connectorConfig;

    bytes32 internal aaveV3MarketName = bytes32("AaveV3");
    uint256 internal aaveV3MarketId;

    address internal priceAdapter;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19368505);

        priceAdapter = address(new PriceAdapter());

        balanceConnector = address(new AaveV3BalanceConnector(aaveV3MarketId, aaveV3MarketName, priceAdapter));

        connectorConfig = new ConnectorConfig();
        aaveV3MarketId = connectorConfig.addMarket(aaveV3MarketName, balanceConnector);

        address[] memory keepers = new address[](1);
        keepers[0] = address(this);

        flashLoanMorphoConnector = address(new FlashLoanMorphoConnector());
        aaveV3SupplyConnector = address(new AaveV3SupplyConnector());
        aaveV3BorrowConnector = address(new AaveV3BorrowConnector(aaveV3MarketId, aaveV3MarketName));
        nativeSwapWethToWstEthConnector = address(new NativeSwapWethToWstEthConnector());
        balanceConnector = address(new AaveV3BalanceConnector(aaveV3MarketId, aaveV3MarketName, priceAdapter));

        Vault.ConnectorStruct[] memory connectors = new Vault.ConnectorStruct[](5);
        connectors[0] = Vault.ConnectorStruct(aaveV3MarketId,flashLoanMorphoConnector);
        connectors[1] = Vault.ConnectorStruct(aaveV3MarketId,aaveV3SupplyConnector);
        connectors[2] = Vault.ConnectorStruct(aaveV3MarketId,aaveV3BorrowConnector);
        connectors[3] = Vault.ConnectorStruct(aaveV3MarketId,nativeSwapWethToWstEthConnector);
        connectors[4] = Vault.ConnectorStruct(aaveV3MarketId,balanceConnector);

        Vault.ConnectorStruct[] memory balanceConnectors = new Vault.ConnectorStruct[](1);
        balanceConnectors[0] = Vault.ConnectorStruct({marketId: aaveV3MarketId, connector: balanceConnector});

        Vault.AssetsMarketStruct[] memory supportedAssetsInMarkets = new Vault.AssetsMarketStruct[](1);

        address[] memory marketAssets = new address[](2);
        marketAssets[0] = WST_ETH;
        marketAssets[1] = W_ETH;

        supportedAssetsInMarkets[0] = Vault.AssetsMarketStruct({marketId: aaveV3MarketId, assets: marketAssets});

        vaultWstEth = payable(new Vault("ipvwstETH", "IP Vault wstETH", WST_ETH, keepers, supportedAssetsInMarkets, connectors, balanceConnectors));

        priceAdapter = address(new PriceAdapter());
    }

    function testShouldWork() public {
        uint256 initialAmount = 40 * 1e18;
        deal(WST_ETH, address(this), initialAmount);

        IERC20(WST_ETH).approve(vaultWstEth, initialAmount);

        //        uint256 amountVaultBeforeDeposit = IERC20(wstETH).balanceOf(vaultWstEth);
        //        console2.log("amountVaultBeforeDeposit", amountVaultBeforeDeposit);

        Vault(vaultWstEth).deposit(initialAmount, address(this));

        //        uint256 amountVaultAfterDeposit = IERC20(wstETH).balanceOf(vaultWstEth);
        //        console2.log("amountVaultAfterDeposit", amountVaultAfterDeposit);

        Vault.ConnectorAction[] memory calls = new Vault.ConnectorAction[](1);

        Vault.ConnectorAction[] memory flashLoanCalls = new Vault.ConnectorAction[](5);

        flashLoanCalls[0] = Vault.ConnectorAction(
            aaveV3SupplyConnector,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyConnector.SupplyData({token: WST_ETH, amount: 40 * 1e18}))
            )
        );

        flashLoanCalls[1] = Vault.ConnectorAction(
            aaveV3BorrowConnector,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3BorrowConnector.BorrowData({token: W_ETH, amount: 30 * 1e18}))
            )
        );

        flashLoanCalls[2] = Vault.ConnectorAction(
            nativeSwapWethToWstEthConnector,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(NativeSwapWethToWstEthConnector.SwapData({wEthAmount: 30 * 1e18}))
            )
        );

        flashLoanCalls[3] = Vault.ConnectorAction(
            balanceConnector,
            abi.encodeWithSignature("balanceOf(address,address,address)", address(vaultWstEth), WST_ETH, WST_ETH)
        );

        flashLoanCalls[4] = Vault.ConnectorAction(
            balanceConnector,
            abi.encodeWithSignature("balanceOf(address,address,address)", address(vaultWstEth), WST_ETH, W_ETH)
        );

        bytes memory flashLoanDataBytes = abi.encode(flashLoanCalls);

        FlashLoanMorphoConnector.FlashLoanData memory flashLoanData = FlashLoanMorphoConnector.FlashLoanData({
            token: WST_ETH,
            /// FlashLoan 100 wstETH
            amount: 100e18,
            data: flashLoanDataBytes
        });

        bytes memory data = abi.encode(flashLoanData);

        calls[0] = Vault.ConnectorAction(flashLoanMorphoConnector, abi.encodeWithSignature("enter(bytes)", data));

        Vault(payable(vaultWstEth)).execute(calls);
    }
}
