// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "@ipor-vaults/contracts/vaults/Vault.sol";
import "@ipor-vaults/contracts/vaults/FlashLoanMorphoConnector.sol";
import "@ipor-vaults/contracts/vaults/AaveV3SupplyConnector.sol";
import "@ipor-vaults/contracts/vaults/AaveV3BorrowConnector.sol";
import "@ipor-vaults/contracts/vaults/NativeSwapWEthToWstEthConnector.sol";

contract ForkAmmGovernanceServiceTest is Test {
    address public constant wEth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address payable public vaultWstEth;
    address public flashLoanMorphoConnector;
    address public aaveV3SupplyConnector;
    address public aaveV3BorrowConnector;
    address public nativeSwapWethToWstEthConnector;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19368505);

        vaultWstEth = payable(
            new Vault("ipvwstETH", "IP Vault wstETH", wstETH)
        );

        flashLoanMorphoConnector = address(new FlashLoanMorphoConnector());
        aaveV3SupplyConnector = address(new AaveV3SupplyConnector());
        aaveV3BorrowConnector = address(new AaveV3BorrowConnector());
        nativeSwapWethToWstEthConnector = address(
            new NativeSwapWethToWstEthConnector()
        );

        Vault(vaultWstEth).addConnector(flashLoanMorphoConnector);
        Vault(vaultWstEth).addConnector(aaveV3SupplyConnector);
        Vault(vaultWstEth).addConnector(aaveV3BorrowConnector);
        Vault(vaultWstEth).addConnector(nativeSwapWethToWstEthConnector);
    }

    function testShouldWork() public {

        uint256 initialAmount = 40 * 1e18;
        deal(wstETH, address(this), initialAmount);

        IERC20(wstETH).approve(vaultWstEth, initialAmount);
        Vault(vaultWstEth).deposit(initialAmount, address(this));


        Vault.ConnectorAction[] memory calls = new Vault.ConnectorAction[](1);

        Vault.ConnectorAction[]
        memory flashLoanCalls = new Vault.ConnectorAction[](3);

        flashLoanCalls[0] = Vault.ConnectorAction(
            aaveV3SupplyConnector,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyConnector.SupplyData({
                        token: wstETH,
                        amount: 40 * 1e18
                    })
                )
            )
        );

        flashLoanCalls[1] = Vault.ConnectorAction(
            aaveV3BorrowConnector,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3BorrowConnector.BorrowData({
                        token: wEth,
                        amount: 30 * 1e18
                    })
                )
            )
        );

        flashLoanCalls[2] = Vault.ConnectorAction(
            nativeSwapWethToWstEthConnector,
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    NativeSwapWethToWstEthConnector.SwapData({
                        wEthAmount: 30 * 1e18
                    })
                )
            )
        );


        bytes memory flashLoanDataBytes = abi.encode(flashLoanCalls);

        FlashLoanMorphoConnector.FlashLoanData
        memory flashLoanData = FlashLoanMorphoConnector.FlashLoanData({
            token: wstETH,
            amount: 61e18,
            data: flashLoanDataBytes
        });

        bytes memory data = abi.encode(flashLoanData);

        calls[0] = Vault.ConnectorAction(
            flashLoanMorphoConnector,
            abi.encodeWithSignature("enter(bytes)", data)
        );

        Vault(payable(vaultWstEth)).execute(calls);
    }
}
