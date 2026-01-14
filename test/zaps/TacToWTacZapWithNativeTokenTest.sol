// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626ZapInWithNativeToken, ZapInData, Call} from "../../contracts/zaps/ERC4626ZapInWithNativeToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "../fuses/erc4626/IWETH9.sol";
import {MockERC4626} from "../test_helpers/MockErc4626.sol";

contract TacToWTacZapWithNativeTokenTest is Test {
    uint256 internal constant FORK_BLOCK_NUMBER = 1282355;
    MockERC4626 internal erc4626WTac;
    /// @dev TAC mainnet staking contract 0x0000000000000000000000000000000000000800
    address internal wTac = 0xB63B9f0eb4A6E6f191529D71d4D88cc8900Df2C9;

    ERC4626ZapInWithNativeToken internal zapIn;

    function setUp1() public {
        vm.createSelectFork(vm.envString("TAC_PROVIDER_URL"), FORK_BLOCK_NUMBER);

        zapIn = new ERC4626ZapInWithNativeToken();
        erc4626WTac = new MockERC4626(IERC20(wTac), "Wrapped TAC", "wTAC");
    }

    function stestShouldDepositWEthWithZapFromEth() public {
        // given
        address user = makeAddr("User");
        uint256 tacAmount = 10_000e18;
        uint256 minAmountToDeposit = 10_000e18;
        deal(user, tacAmount);

        ZapInData memory zapInData = ZapInData({
            vault: address(erc4626WTac),
            receiver: user,
            minAmountToDeposit: tacAmount,
            minSharesOut: 0,
            assetsToRefundToSender: new address[](0),
            calls: new Call[](0),
            refundNativeTo: user
        });

        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: wTac,
            data: abi.encodeWithSelector(IWETH9.deposit.selector),
            nativeTokenAmount: tacAmount
        });

        calls[1] = Call({
            target: wTac,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(erc4626WTac), tacAmount),
            nativeTokenAmount: 0
        });

        zapInData.calls = calls;

        uint256 userBalancePlasmaVaultSharesBefore = erc4626WTac.balanceOf(user);

        // when
        vm.startPrank(user);
        zapIn.zapIn{value: tacAmount}(zapInData);
        vm.stopPrank();

        // then

        uint256 userBalancePlasmaVaultSharesAfter = erc4626WTac.balanceOf(user);

        assertEq(userBalancePlasmaVaultSharesBefore, 0, "User should not have any shares before the zap");
        assertEq(userBalancePlasmaVaultSharesAfter, tacAmount, "User should have 10_000e18 wTAC in the plasma vault");
    }
}
