// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {
    AsyncActionFuse,
    AsyncActionFuseEnterData,
    AsyncActionFuseExitData
} from "../../../contracts/fuses/async_action/AsyncActionFuse.sol";
import {AsyncActionBalanceFuse} from "../../../contracts/fuses/async_action/AsyncActionBalanceFuse.sol";
import {
    AsyncActionFuseLib,
    AllowedAmountToOutside,
    AllowedTargets,
    AllowedSlippage,
    AsyncActionFuseSubstrate,
    AsyncActionFuseSubstrateType
} from "../../../contracts/fuses/async_action/AsyncActionFuseLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {MockTokenVault} from "./MockTokenVault.sol";
import {ReadAsyncExecutor} from "../../../contracts/readers/ReadAsyncExecutor.sol";
import {UniversalReader, ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";

/// @title AsyncActionFuseTest
/// @notice Tests for AsyncActionFuse
contract AsyncActionFuseTest is Test {
    AsyncActionFuse private _asyncActionFuse;
    AsyncActionBalanceFuse private _asyncActionBalanceFuse;
    IporFusionAccessManager private _accessManager;
    ReadAsyncExecutor private _readAsyncExecutor;
    address private constant PLASMA_VAULT = 0x6f66b845604dad6E80b2A1472e6cAcbbE66A8C40;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address private constant ATOMIST = 0x8c52fE65e3AfE15392F23536aAd128edE9aE4102;
    address private constant OWNER = 0xf2C6a2225BE9829eD77263b032E3D92C52aE6694;
    address private constant USER = 0x1212121212121212121212121212121212121212;

    /// @notice Sets up the test environment by forking Ethereum mainnet
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23739479);

        _accessManager = IporFusionAccessManager(PlasmaVault(PLASMA_VAULT).authority());

        _asyncActionFuse = new AsyncActionFuse(IporFusionMarkets.ASYNC_ACTION, WETH);
        _asyncActionBalanceFuse = new AsyncActionBalanceFuse(IporFusionMarkets.ASYNC_ACTION);
        _readAsyncExecutor = new ReadAsyncExecutor();

        vm.startPrank(OWNER);
        _accessManager.grantRole(Roles.PRE_HOOKS_MANAGER_ROLE, ATOMIST, 0);
        vm.stopPrank();

        vm.startPrank(ATOMIST);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, ATOMIST, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, ATOMIST, 0);
        vm.stopPrank();

        // Add fuses to vault
        address[] memory fuses = new address[](1);
        fuses[0] = address(_asyncActionFuse);

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).addFuses(fuses);
        PlasmaVaultGovernance(PLASMA_VAULT).addBalanceFuse(
            IporFusionMarkets.ASYNC_ACTION,
            address(_asyncActionBalanceFuse)
        );
        vm.stopPrank();

        // Deposit USDC to PlasmaVault by USER
        uint256 depositAmount = 10_000e6; // 10,000 USDC (6 decimals)
        deal(USDC, USER, depositAmount);

        vm.startPrank(USER);
        IERC20(USDC).approve(PLASMA_VAULT, depositAmount);
        PlasmaVault(PLASMA_VAULT).deposit(depositAmount, USER);
        vm.stopPrank();
    }

    /// @notice Empty test that always passes
    function testEmpty() public {
        assertTrue(true);
    }

    /// @notice Test that calling enter with zero tokenOut address reverts
    function testEnterWithZeroTokenOutReverts() public {
        // given
        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: address(0), // Zero address should cause revert
            amountOut: 1e18,
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // expect
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidTokenOut.selector);

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);
    }

    /// @notice Test that calling enter with mismatched array lengths reverts
    function testEnterWithMismatchedArrayLengthsReverts() public {
        // given
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        
        // callDatas has different length than targets
        bytes[] memory callDatas = new bytes[](0);
        
        // ethAmounts has same length as targets to test callDatas mismatch
        uint256[] memory ethAmounts = new uint256[](1);
        ethAmounts[0] = 0;

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: USDC, // Valid token address
            amountOut: 1e18,
            targets: targets,
            callDatas: callDatas, // Different length than targets
            ethAmounts: ethAmounts,
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // expect
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidArrayLength.selector);

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);
    }

    /// @notice Test that calling enter with mismatched ethAmounts and targets lengths reverts
    function testEnterWithMismatchedEthAmountsAndTargetsLengthsReverts() public {
        // given
        address[] memory targets = new address[](1);
        targets[0] = address(0x1234);
        
        // callDatas has same length as targets
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSignature("test()");
        
        // ethAmounts has different length than targets
        uint256[] memory ethAmounts = new uint256[](0);

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: USDC, // Valid token address
            amountOut: 1e18,
            targets: targets,
            callDatas: callDatas, // Same length as targets
            ethAmounts: ethAmounts, // Different length than targets
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // expect
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseInvalidArrayLength.selector);

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);
    }

    /// @notice Test that calling enter with tokenOut not in allowed list reverts
    function testEnterWithTokenOutNotAllowedReverts() public {
        // given
        // Use a token address that is not in the allowed substrates list
        address notAllowedToken = address(0x9999999999999999999999999999999999999999);

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: notAllowedToken, // Token not in allowed substrates
            amountOut: 1e18,
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // expect
        vm.expectRevert(
            abi.encodeWithSelector(
                AsyncActionFuse.AsyncActionFuseTokenOutNotAllowed.selector,
                notAllowedToken,
                1e18,
                0 // maxAllowed = 0 when token not found
            )
        );

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);
    }

    /// @notice Test that calling enter with amountOut exceeding allowedAmount reverts
    function testEnterWithAmountOutExceedingAllowedAmountReverts() public {
        // given
        // Configure USDC as allowed token with small allowedAmount
        uint256 allowedAmount = 1e6; // 1 USDC (6 decimals)
        uint256 requestedAmount = 1e18; // Much larger than allowedAmount

        AllowedAmountToOutside memory allowedAmountData = AllowedAmountToOutside({
            asset: USDC,
            amount: allowedAmount
        });

        AsyncActionFuseSubstrate memory substrate = AsyncActionFuseSubstrate({
            substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
            data: AsyncActionFuseLib.encodeAllowedAmountToOutside(allowedAmountData)
        });

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(substrate);

        // Grant substrate to market
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.ASYNC_ACTION,
            substrates
        );
        vm.stopPrank();

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: USDC, // Token is in allowed list
            amountOut: requestedAmount, // But amount exceeds allowedAmount
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // expect
        vm.expectRevert(
            abi.encodeWithSelector(
                AsyncActionFuse.AsyncActionFuseTokenOutNotAllowed.selector,
                USDC,
                requestedAmount,
                allowedAmount // maxAllowed = allowedAmount when token found but amount exceeds limit
            )
        );

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);
    }

    /// @notice Test that calling enter with target/selector not in allowed list reverts
    function testEnterWithTargetNotAllowedReverts() public {
        // given
        // Configure USDC as allowed tokenOut
        uint256 allowedAmount = 1e18;
        AllowedAmountToOutside memory allowedAmountData = AllowedAmountToOutside({
            asset: USDC,
            amount: allowedAmount
        });

        // Configure one allowed target/selector pair
        address allowedTarget = address(0x1111111111111111111111111111111111111111);
        bytes4 allowedSelector = bytes4(keccak256("allowedFunction()"));
        AllowedTargets memory allowedTargetData = AllowedTargets({
            target: allowedTarget,
            selector: allowedSelector
        });

        // Create substrates array with both allowedAmount and allowedTarget
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(allowedAmountData)
            })
        );
        substrates[1] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(allowedTargetData)
            })
        );

        // Grant substrates to market
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.ASYNC_ACTION,
            substrates
        );
        vm.stopPrank();

        // Use a target/selector that is NOT in the allowed list
        address notAllowedTarget = address(0x2222222222222222222222222222222222222222);
        bytes4 notAllowedSelector = bytes4(keccak256("notAllowedFunction()"));

        address[] memory targets = new address[](1);
        targets[0] = notAllowedTarget;

        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(notAllowedSelector);

        uint256[] memory ethAmounts = new uint256[](1);
        ethAmounts[0] = 0;

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: USDC, // Token is allowed
            amountOut: 1e6, // Amount is within limit
            targets: targets, // Target is NOT in allowed list
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // expect
        vm.expectRevert(
            abi.encodeWithSelector(
                AsyncActionFuse.AsyncActionFuseTargetNotAllowed.selector,
                notAllowedTarget,
                notAllowedSelector
            )
        );

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);
    }

    /// @notice Test that successfully deposits USDC to MockTokenVault via AsyncActionFuse
    function testEnterDepositsUsdcToMockTokenVault() public {
        // given
        uint256 depositAmount = 1_000e6; // 1,000 USDC (6 decimals)
        
        // Deploy MockTokenVault
        MockTokenVault mockVault = new MockTokenVault();

        // Configure USDC as allowed tokenOut
        AllowedAmountToOutside memory allowedAmountData = AllowedAmountToOutside({
            asset: USDC,
            amount: depositAmount
        });

        // Configure allowed targets: USDC.approve and MockTokenVault.deposit
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(allowedAmountData)
            })
        );
        substrates[1] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({
                        target: USDC,
                        selector: IERC20.approve.selector
                    })
                )
            })
        );
        substrates[2] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({
                        target: address(mockVault),
                        selector: MockTokenVault.deposit.selector
                    })
                )
            })
        );

        // Grant substrates to market
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.ASYNC_ACTION,
            substrates
        );
        vm.stopPrank();

        // Get executor address to approve
        address executor = AsyncActionFuseLib.getAsyncExecutorAddress(WETH, address(_asyncActionFuse));

        // Prepare two calls: approve and deposit
        address[] memory targets = new address[](2);
        targets[0] = USDC; // First call: approve
        targets[1] = address(mockVault); // Second call: deposit

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSelector(IERC20.approve.selector, address(mockVault), depositAmount);
        callDatas[1] = abi.encodeWithSelector(MockTokenVault.deposit.selector, USDC, depositAmount);

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 0;

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: USDC,
            amountOut: depositAmount,
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // Verify initial balance is zero
        uint256 balanceBefore = mockVault.balanceOf(USDC);
        assertEq(balanceBefore, 0, "MockVault should have zero balance before deposit");

        // when
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);

        // then
        uint256 balanceAfter = mockVault.balanceOf(USDC);
        uint256 balanceInMarketAfter = PlasmaVault(PLASMA_VAULT).totalAssetsInMarket(IporFusionMarkets.ASYNC_ACTION);
        assertEq(balanceAfter, depositAmount, "MockVault should have received the deposit amount");
        assertEq(balanceInMarketAfter, depositAmount, "Balance in market should be equal to deposit amount");
    }

    /// @notice Test that cannot execute deposit to MockTokenVault twice
    function testCannotExecuteDepositTwice() public {
        // given
        uint256 depositAmount = 1_000e6; // 1,000 USDC (6 decimals)
        
        // Deploy MockTokenVault
        MockTokenVault mockVault = new MockTokenVault();

        // Configure USDC as allowed tokenOut
        AllowedAmountToOutside memory allowedAmountData = AllowedAmountToOutside({
            asset: USDC,
            amount: depositAmount
        });

        // Configure allowed targets: USDC.approve and MockTokenVault.deposit
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(allowedAmountData)
            })
        );
        substrates[1] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({
                        target: USDC,
                        selector: IERC20.approve.selector
                    })
                )
            })
        );
        substrates[2] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({
                        target: address(mockVault),
                        selector: MockTokenVault.deposit.selector
                    })
                )
            })
        );

        // Grant substrates to market
        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.ASYNC_ACTION,
            substrates
        );
        vm.stopPrank();

        // Get executor address
        address executor = AsyncActionFuseLib.getAsyncExecutorAddress(WETH, address(_asyncActionFuse));

        // Prepare call data for deposit
        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = address(mockVault);

        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSelector(IERC20.approve.selector, address(mockVault), depositAmount);
        callDatas[1] = abi.encodeWithSelector(MockTokenVault.deposit.selector, USDC, depositAmount);

        uint256[] memory ethAmounts = new uint256[](2);
        ethAmounts[0] = 0;
        ethAmounts[1] = 0;

        AsyncActionFuseEnterData memory enterData = AsyncActionFuseEnterData({
            tokenOut: USDC,
            amountOut: depositAmount,
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            tokensDustToCheck: new address[](0)
        });

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                enterData
            )
        });

        // Execute first deposit - should succeed
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);

        // Verify first deposit succeeded
        uint256 balanceAfterFirst = mockVault.balanceOf(USDC);
        assertEq(balanceAfterFirst, depositAmount, "First deposit should succeed");


        // Try to execute second deposit - should revert because executor balance > 0
        // AsyncActionFuse checks if balance > 0 and amountOut > 0, then reverts with AsyncActionFuseBalanceNotZero
        vm.expectRevert(AsyncActionFuse.AsyncActionFuseBalanceNotZero.selector);
        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(actions);

        // Verify balance did not change (revert prevented execution)
        uint256 balanceAfterSecond = mockVault.balanceOf(USDC);
        assertEq(balanceAfterSecond, balanceAfterFirst, "Second deposit should not increase balance due to revert");
    }

    /// @notice Test that after deposit to MockTokenVault, next execute can withdraw tokens to AsyncExecutor
    function testWithdrawFromMockTokenVaultToExecutor() public {
        // given
        uint256 depositAmount = 1_000e6; // 1,000 USDC (6 decimals)
        MockTokenVault mockVault = new MockTokenVault();

        // Configure substrates
        bytes32[] memory substrates = new bytes32[](6);
        substrates[0] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
                data: AsyncActionFuseLib.encodeAllowedAmountToOutside(
                    AllowedAmountToOutside({asset: USDC, amount: depositAmount})
                )
            })
        );
        substrates[1] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({target: USDC, selector: IERC20.approve.selector})
                )
            })
        );
        substrates[2] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({target: address(mockVault), selector: MockTokenVault.deposit.selector})
                )
            })
        );
        substrates[3] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({target: address(mockVault), selector: MockTokenVault.withdraw.selector})
                )
            })
        );
        substrates[4] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
                data: AsyncActionFuseLib.encodeAllowedTargets(
                    AllowedTargets({target: USDC, selector: IERC20.transfer.selector})
                )
            })
        );
        substrates[5] = AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(
            AsyncActionFuseSubstrate({
                substrateType: AsyncActionFuseSubstrateType.ALLOWED_SLIPPAGE,
                data: AsyncActionFuseLib.encodeAllowedSlippage(
                    AllowedSlippage({slippage: 0}) // No slippage tolerance
                )
            })
        );

        vm.startPrank(ATOMIST);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(
            IporFusionMarkets.ASYNC_ACTION,
            substrates
        );
        vm.stopPrank();

        // First execute: Deposit to MockTokenVault
        FuseAction[] memory depositActions = new FuseAction[](1);
        depositActions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                AsyncActionFuseEnterData({
                    tokenOut: USDC,
                    amountOut: depositAmount,
                    targets: _createDepositTargets(address(mockVault)),
                    callDatas: _createDepositCallDatas(address(mockVault), depositAmount),
                    ethAmounts: _createEthAmounts(2),
                    tokensDustToCheck: new address[](0)
                })
            )
        });

        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(depositActions);

        assertEq(mockVault.balanceOf(USDC), depositAmount, "MockVault should have received the deposit");

        // Read executor address using ReadAsyncExecutor after first execute
        ReadResult memory readResult = UniversalReader(PLASMA_VAULT).read(
            address(_readAsyncExecutor),
            abi.encodeWithSignature("readAsyncExecutorAddress()")
        );
        address executor = abi.decode(readResult.data, (address));

        // Second execute: Withdraw from MockTokenVault
        FuseAction[] memory withdrawActions = new FuseAction[](1);
        withdrawActions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint256,address[],bytes[],uint256[],address[]))",
                AsyncActionFuseEnterData({
                    tokenOut: USDC,
                    amountOut: 0, // amountOut = 0 to bypass balance check
                    targets: _createWithdrawTargets(address(mockVault)),
                    callDatas: _createWithdrawCallDatas(depositAmount),
                    ethAmounts: _createEthAmounts(1),
                    tokensDustToCheck: new address[](0)
                })
            )
        });

        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(withdrawActions);

        assertEq(mockVault.balanceOf(USDC), 0, "MockVault should have zero balance after withdraw");
        assertEq(IERC20(USDC).balanceOf(executor), depositAmount, "Executor should have received the withdrawn tokens");

        // Get initial balances before exit
        uint256 plasmaVaultUsdcBalanceBefore = IERC20(USDC).balanceOf(PLASMA_VAULT);
        uint256 balanceInMarketBefore = PlasmaVault(PLASMA_VAULT).totalAssetsInMarket(IporFusionMarkets.ASYNC_ACTION);

        // Third execute: Exit - fetch assets from executor back to PlasmaVault
        FuseAction[] memory exitActions = new FuseAction[](1);
        address[] memory assetsToFetch = new address[](1);
        assetsToFetch[0] = USDC;
        
        exitActions[0] = FuseAction({
            fuse: address(_asyncActionFuse),
            data: abi.encodeWithSignature(
                "exit((address[]))",
                AsyncActionFuseExitData({assets: assetsToFetch})
            )
        });

        vm.prank(ATOMIST);
        PlasmaVault(PLASMA_VAULT).execute(exitActions);

        // Verify tokens were transferred to PlasmaVault
        uint256 plasmaVaultUsdcBalanceAfter = IERC20(USDC).balanceOf(PLASMA_VAULT);
        assertEq(
            plasmaVaultUsdcBalanceAfter,
            plasmaVaultUsdcBalanceBefore + depositAmount,
            "PlasmaVault should have received the tokens from executor"
        );

        // Verify executor USDC balance is zero
        uint256 executorUsdcBalanceAfter = IERC20(USDC).balanceOf(executor);
        assertEq(executorUsdcBalanceAfter, 0, "Executor should have zero USDC balance after exit");

        // Verify balance in market is zero
        uint256 balanceInMarketAfter = PlasmaVault(PLASMA_VAULT).totalAssetsInMarket(IporFusionMarkets.ASYNC_ACTION);
        assertEq(balanceInMarketAfter, 0, "Balance in market should be zero after exit");
    }

    function _createDepositTargets(address mockVault_) private pure returns (address[] memory) {
        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = mockVault_;
        return targets;
    }

    function _createDepositCallDatas(address mockVault_, uint256 amount_) private pure returns (bytes[] memory) {
        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSelector(IERC20.approve.selector, mockVault_, amount_);
        callDatas[1] = abi.encodeWithSelector(MockTokenVault.deposit.selector, USDC, amount_);
        return callDatas;
    }

    function _createWithdrawTargets(address mockVault_) private pure returns (address[] memory) {
        address[] memory targets = new address[](1);
        targets[0] = mockVault_;
        return targets;
    }

    function _createWithdrawCallDatas(uint256 amount_) private pure returns (bytes[] memory) {
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockTokenVault.withdraw.selector, USDC, amount_);
        return callDatas;
    }

    function _createEthAmounts(uint256 length_) private pure returns (uint256[] memory) {
        uint256[] memory ethAmounts = new uint256[](length_);
        // All values are 0 by default
        return ethAmounts;
    }
}

