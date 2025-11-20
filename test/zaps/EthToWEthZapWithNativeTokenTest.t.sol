// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapInWithNativeToken, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../fuses/erc4626/IWETH9.sol";

contract EthToWEthZapWithNativeTokenTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 32275361;
    PlasmaVault internal plasmaVaultWeth = PlasmaVault(0x7872893e528Fe2c0829e405960db5B742112aa97);
    address internal weth = 0x4200000000000000000000000000000000000006;

    ERC4626ZapInWithNativeToken internal zapIn;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK_NUMBER);

        zapIn = new ERC4626ZapInWithNativeToken();
    }

    function testShouldDepositWEthWithZapFromEth() public {
        // given
        address user = makeAddr("User");
        uint256 ethAmount = 10_000e18;
        uint256 minAmountToDeposit = 10_000e18;
        deal(user, ethAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(plasmaVaultWeth),
            receiver: user,
            minAmountToDeposit: ethAmount,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0)
        });

        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: weth,
            data: abi.encodeWithSelector(IWETH9.deposit.selector),
            nativeTokenAmount: ethAmount
        });

        calls[1] = Call({
            target: weth,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(plasmaVaultWeth), ethAmount),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = plasmaVaultWeth.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: ethAmount}(zapInData);
        vm.stopPrank();

        // then

        uint256 userBalancePlasmaVaultSharesAfter = plasmaVaultWeth.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(
            userBalancePlasmaVaultSharesAfter,
            984679_501885980912334434,
            "User should have 984679501885980912334434 weth in the plasma vault"
        );
    }
}
