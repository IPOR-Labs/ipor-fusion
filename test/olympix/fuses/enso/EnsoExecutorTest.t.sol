// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/enso/EnsoExecutor.sol

import {EnsoExecutor, EnsoExecutorData} from "contracts/fuses/enso/EnsoExecutor.sol";
import {MockDelegateEnsoShortcuts} from "test/fuses/enso/MockDelegateEnsoShortcuts.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IWETH9} from "contracts/interfaces/ext/IWETH9.sol";
import {EnsoExecutor} from "contracts/fuses/enso/EnsoExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
contract EnsoExecutorTest is OlympixUnitTest("EnsoExecutor") {


    function test_execute_RevertsWhenCalledByNonPlasmaVault() public {
            // given: deploy EnsoExecutor with valid addresses
            address delegateEnso = address(new MockDelegateEnsoShortcuts());
            address weth = address(0xBEEF); // dummy non-zero WETH address, we won't hit WETH logic
            address plasmaVault = address(0xCAFE);
            EnsoExecutor executor = new EnsoExecutor(delegateEnso, weth, plasmaVault);
    
            // prepare minimal data struct (values won't be used because call should revert early)
            bytes32[] memory commands = new bytes32[](0);
            bytes[] memory state = new bytes[](0);
            address[] memory tokensToReturn = new address[](0);
            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 0,
                tokenOut: address(0),
                amountOut: 0
            });
    
            // when / then: msg.sender != PLASMA_VAULT so execute must revert with EnsoExecutorUnauthorizedCaller
            vm.expectRevert(EnsoExecutor.EnsoExecutorUnauthorizedCaller.selector);
            executor.execute(data_);
        }

    function test_execute_AllowsWhenCalledByPlasmaVault() public {
            // given: deploy EnsoExecutor with valid, non-zero addresses
            address delegateEnso = address(new MockDelegateEnsoShortcuts());
            MockERC20 tokenOut = new MockERC20("Mock", "MOCK", 18);
            address weth = address(0xBEEF); // dummy non-zero WETH address
            address plasmaVault = address(this); // make test contract the PLASMA_VAULT
            EnsoExecutor executor = new EnsoExecutor(delegateEnso, weth, plasmaVault);

            // prepare minimal data struct
            bytes32[] memory commands = new bytes32[](1);
            commands[0] = bytes32(uint256(1));
            bytes[] memory state = new bytes[](1);
            state[0] = bytes("");
            address[] memory tokensToReturn = new address[](0);

            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: 0
            });

            // when / then: msg.sender == PLASMA_VAULT so authorization passes
            executor.execute(data_);
        }

    function test_execute_RevertsWhenBalanceAlreadySet_opix_target_branch_137_true() public {
            // given: deploy EnsoExecutor with valid addresses
            address delegateEnso = address(new MockDelegateEnsoShortcuts());
            address weth = address(0xBEEF); // dummy non-zero WETH address
            address plasmaVault = address(this); // make test contract the PLASMA_VAULT
            EnsoExecutor executor = new EnsoExecutor(delegateEnso, weth, plasmaVault);
    
            // prepare a real ERC20 token as tokenOut so balanceOf() call succeeds
            MockERC20 tokenOut = new MockERC20("Mock", "MOCK", 18);
    
            // Seed executor's internal balance state via a first successful execute()
            bytes32[] memory commands1 = new bytes32[](1);
            commands1[0] = bytes32(uint256(1));
            bytes[] memory state1 = new bytes[](1);
            state1[0] = bytes("");
            address[] memory tokensToReturn1 = new address[](0);
    
            EnsoExecutorData memory first = EnsoExecutorData({
                accountId: bytes32(uint256(0)),
                requestId: bytes32(uint256(0)),
                commands: commands1,
                state: state1,
                tokensToReturn: tokensToReturn1,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: 0
            });
    
            // Mint zero tokens to executor; balanceOf will return 0 but internal assetAddress will be set
            tokenOut.mint(address(executor), 0);
    
            // First execute succeeds and sets _balance.assetAddress to tokenOut
            executor.execute(first);
    
            // sanity: internal assetAddress is now non-zero, so the branch condition will be true next time
            (address assetBefore,) = executor.getBalance();
            assertEq(assetBefore, address(tokenOut));
    
            // prepare second call data (values mostly irrelevant)
            bytes32[] memory commands2 = new bytes32[](1);
            commands2[0] = bytes32(uint256(2));
            bytes[] memory state2 = new bytes[](1);
            state2[0] = bytes("");
            address[] memory tokensToReturn2 = new address[](0);
    
            EnsoExecutorData memory second = EnsoExecutorData({
                accountId: bytes32(uint256(1)),
                requestId: bytes32(uint256(2)),
                commands: commands2,
                state: state2,
                tokensToReturn: tokensToReturn2,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: 0
            });
    
            // when / then: calling execute again must hit `if (_balance.assetAddress != address(0))` true branch
            // and revert with EnsoExecutorBalanceAlreadySet
            vm.expectRevert(EnsoExecutor.EnsoExecutorBalanceAlreadySet.selector);
            executor.execute(second);
        }

    function test_execute_WethWithdrawBranch_opix_target_branch_152_true() public {
            // given: real mock delegate and mock WETH
            MockDelegateEnsoShortcuts delegateEnso = new MockDelegateEnsoShortcuts();
            MockERC20 underlying = new MockERC20("MockWETH", "MWETH", 18);

            address wethAddr = address(underlying);
            address plasmaVault = address(this);

            EnsoExecutor executor = new EnsoExecutor(address(delegateEnso), wethAddr, plasmaVault);

            // Mock IWETH9.withdraw to succeed
            vm.mockCall(wethAddr, abi.encodeWithSelector(IWETH9.withdraw.selector), abi.encode());
            // Mock IWETH9.deposit to succeed
            vm.mockCall(wethAddr, abi.encodeWithSelector(IWETH9.deposit.selector), abi.encode());

            // Mint WETH to executor so transfer to plasmaVault succeeds
            underlying.mint(address(executor), 1 ether);

            // Prepare commands/state
            bytes32[] memory commands = new bytes32[](1);
            uint256 flags = 0x01; // CALL
            bytes32 command = bytes32((flags << 248) | uint256(uint160(address(this))));
            commands[0] = command;
            bytes[] memory state = new bytes[](1);
            state[0] = abi.encode(uint256(1));

            address[] memory tokensToReturn = new address[](0);

            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 1 ether,
                tokenOut: address(underlying),
                amountOut: 0
            });

            // Deal ETH to executor
            vm.deal(address(executor), 1 ether);

            // when: call execute from PlasmaVault
            executor.execute(data_);

            // then: internal balance assetAddress should be set to tokenOut
            (address assetAddr, uint256 assetBal) = executor.getBalance();
            assertEq(assetAddr, address(underlying));
            assetBal; // silence unused warning
        }

    function test_execute_EthBalanceBranch_opix_target_branch_161_true() public {
            // given: set this test contract as PLASMA_VAULT so calls are authorized
            address plasmaVault = address(this);
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            MockERC20 mockWeth = new MockERC20("MockWETH", "MWETH", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), address(mockWeth), plasmaVault);

            // Fund executor with some ETH so that `ethBalance > 0` branch is taken
            vm.deal(address(executor), 1 ether);

            // Mock IWETH9.deposit to succeed (called when ethBalance > 0)
            vm.mockCall(address(mockWeth), abi.encodeWithSelector(IWETH9.deposit.selector), abi.encode());
            // Mock the WETH transfer to plasmaVault
            vm.mockCall(address(mockWeth), abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)"))), abi.encode(true));

            // Prepare commands/state
            bytes32[] memory commands = new bytes32[](1);
            uint256 flags = 0x01;
            bytes32 command = bytes32((flags << 248) | uint256(uint160(address(this))));
            commands[0] = command;

            bytes[] memory state = new bytes[](1);
            state[0] = abi.encode(uint256(1));

            address[] memory tokensToReturn = new address[](0);

            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: 0
            });

            // when: call execute as PLASMA_VAULT
            executor.execute(data_);

            // then: no revert, ethBalance > 0 branch was taken
            (address assetAddr,) = executor.getBalance();
            assertEq(assetAddr, address(tokenOut));
        }

    function test_execute_TokenOutAmountOutBranch_opix_target_branch_173_true() public {
            // given: set this test contract as PLASMA_VAULT so calls are authorized
            address plasmaVault = address(this);
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            MockERC20 tokenOut = new MockERC20("MockToken", "MTK", 18);
            address weth = address(0xBEEF); // non-zero dummy WETH address
    
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
            // Prepare commands/state so delegatecall into MockDelegateEnsoShortcuts succeeds
            bytes32[] memory commands = new bytes32[](1);
            uint256 flags = 0x01; // CALL type in MockDelegateEnsoShortcuts
            bytes32 command = bytes32((flags << 248) | uint256(uint160(address(this))));
            commands[0] = command;
    
            bytes[] memory state = new bytes[](1);
            // non-empty payload to satisfy mock
            state[0] = abi.encode(uint256(1));
    
            address[] memory tokensToReturn = new address[](0);
    
            // Make tokenOut.balanceOf(executor) > 0 and strictly less than amountOut
            uint256 executorTokenBalance = 5 ether;
            uint256 expectedAmountOut = 10 ether; // amountOut > tokenOutBalance to hit opix-target-branch-173-True
    
            // Transfer tokens to executor so it holds a positive balance before execute
            tokenOut.mint(address(this), executorTokenBalance);
            tokenOut.transfer(address(executor), executorTokenBalance);
    
            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: expectedAmountOut
            });
    
            // when: call execute as PLASMA_VAULT so authorization passes
            vm.prank(plasmaVault);
            executor.execute(data_);
    
            // then: internal balance should track the remaining expected amount
            (address assetAddr, uint256 assetBal) = executor.getBalance();
            assertEq(assetAddr, address(tokenOut));
            // assetBal should equal amountOut - tokenOutBalance
            assertEq(assetBal, expectedAmountOut - executorTokenBalance);
        }

    function test_withdrawAll_RevertsWhenCallerNotPlasmaVault() public {
            // Deploy dependencies
            address plasmaVault = address(0xABC1);
            address weth = address(0xBEEF);
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
    
            // Deploy EnsoExecutor with non-zero addresses (constructor guards)
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
            // Prepare tokens array (content irrelevant, we only hit the require)
            address[] memory tokens = new address[](1);
            tokens[0] = address(0xDEAD);
    
            // Expect revert from `withdrawAll` when called by non-PLASMA_VAULT
            vm.expectRevert(EnsoExecutor.EnsoExecutorUnauthorizedCaller.selector);
            executor.withdrawAll(tokens);
        }

    function test_withdrawAll_AllowsPlasmaVaultAndResetsBalance_opix_target_branch_208_else() public {
            // given
            address plasmaVault = address(0xABCD);
            address weth = address(0xBEEF);
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
            // Seed executor with a real token balance and internal tracking via execute()
            MockERC20 tokenOut = new MockERC20("Mock", "MOCK", 18);
    
            // Mint tokens to this test contract so it can later receive them from executor
            tokenOut.mint(address(this), 100 ether);
    
            // Prepare minimal valid commands/state for MockDelegateEnsoShortcuts
            bytes32[] memory commands = new bytes32[](1);
            // Set callType = 0x01 (CALL) in flags byte so mock won't revert
            uint256 flags = 0x01;
            // Embed this test contract as target address in the low 160 bits
            bytes32 command = bytes32((flags << 248) | uint256(uint160(address(this))));
            commands[0] = command;
    
            bytes[] memory state = new bytes[](1);
            // state[0] must be non-empty but contents are irrelevant for this test
            state[0] = abi.encode(uint256(1));
    
            address[] memory tokensToReturn = new address[](0);
    
            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(uint256(1)),
                requestId: bytes32(uint256(2)),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: 100 ether
            });
    
            // transfer tokenOut to executor so it holds balance before execute
            tokenOut.transfer(address(executor), 100 ether);
    
            // when: execute called by PLASMA_VAULT initializes internal _balance
            vm.prank(plasmaVault);
            executor.execute(data_);
    
            // sanity: internal tracking should now point to tokenOut
            (address assetAddrBefore, uint256 assetBalBefore) = executor.getBalance();
            assertEq(assetAddrBefore, address(tokenOut));
            // depending on the branch, assetBalBefore can be 0 or >0, so just assert address
            assetBalBefore; // silence unused warning
    
            // prepare tokens array for withdrawAll
            address[] memory tokens = new address[](1);
            tokens[0] = address(tokenOut);
    
            // when: called by PLASMA_VAULT, we enter the else-branch of `if (msg.sender != PLASMA_VAULT)`
            vm.prank(plasmaVault);
            executor.withdrawAll(tokens);
    
            // then: internal tracking should be reset
            (address assetAddrAfter, uint256 assetBalAfter) = executor.getBalance();
            assertEq(assetAddrAfter, address(0));
            assertEq(assetBalAfter, 0);
    
            // executor should no longer hold the tokens
            assertEq(tokenOut.balanceOf(address(executor)), 0);
        }

    function test_withdrawAll_EmptyTokensArray_hitsEarlyReturnBranch() public {
            // given: a valid EnsoExecutor instance with proper constructor parameters
            address plasmaVault = address(this);
            address weth = address(0xBEEF);
            address delegateEnso = address(0xDE1E6A7E); // non-zero dummy delegate address
            EnsoExecutor executor = new EnsoExecutor(delegateEnso, weth, plasmaVault);
    
            // prepare an empty tokens array to hit `if (tokensLength == 0) { return; }` branch
            address[] memory tokens = new address[](0);
    
            // when: call withdrawAll as the authorized PlasmaVault with empty array
            // then: function should take the True branch at opix-target-branch-214 and return without reverting
            executor.withdrawAll(tokens);
        }

    function test_recovery_RevertsWhenCallerNotPlasmaVault_opix_target_branch_242_true() public {
        // deploy dependencies
        address plasmaVault = address(0xABCD);
        MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
        // Use any non-zero address as WETH (no interactions in this test)
        address weth = address(0xBEEF);
    
        EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
        // prepare arbitrary target and data for recovery
        address target = address(0x1234);
        bytes memory data = abi.encodeWithSignature("dummy()");
    
        // call recovery from a non‑plasmaVault address (address(this)) to trigger the
        // `if (msg.sender != PLASMA_VAULT)` branch and revert with EnsoExecutorUnauthorizedCaller
        vm.expectRevert(EnsoExecutor.EnsoExecutorUnauthorizedCaller.selector);
        executor.recovery(target, data);
    }

    function test_recovery_SucceedsForPlasmaVaultAndEmptyBalance_opix_target_branch_244_else() public {
            // given: set up executor with a specific PlasmaVault address
            address plasmaVault = address(this);
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            address weth = address(0xBEEF); // non-zero dummy WETH

            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);

            // prepare a non-zero target and non-empty calldata
            // Use executeShortcut with at least 1 command so the mock doesn't revert with "no commands"
            bytes32[] memory commands = new bytes32[](1);
            commands[0] = bytes32(uint256(1));
            bytes[] memory state = new bytes[](1);
            state[0] = bytes("");

            address target = address(delegateShortcuts);
            bytes memory data = abi.encodeWithSignature(
                "executeShortcut(bytes32,bytes32,bytes32[],bytes[])",
                bytes32(0),
                bytes32(0),
                commands,
                state
            );

            // when / then: call recovery from the PlasmaVault address (address(this))
            executor.recovery(target, data);
        }

    function test_recovery_RevertsWhenBalanceNotEmpty_opix_target_branch_249_true() public {
            // given: set up executor where this test contract is the PlasmaVault
            address plasmaVault = address(this);
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            address weth = address(0xBEEF); // dummy non-zero WETH address
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
            // Use a real ERC20 mock so balanceOf and transfers succeed
            MockERC20 tokenOut = new MockERC20("MockToken", "MTK", 18);
            tokenOut.mint(address(executor), 1 ether);
    
            // Prepare minimal valid commands/state for MockDelegateEnsoShortcuts
            bytes32[] memory commands = new bytes32[](1);
            bytes[] memory state = new bytes[](1);
            // Non-zero command so mock executes without reverting
            commands[0] = bytes32(uint256(1));
            state[0] = bytes("");
            address[] memory tokensToReturn = new address[](0);
    
            // Configure execute so that it sets _balance.assetAddress to tokenOut
            EnsoExecutorData memory data_ = EnsoExecutorData({
                accountId: bytes32(0),
                requestId: bytes32(0),
                commands: commands,
                state: state,
                tokensToReturn: tokensToReturn,
                wEthAmount: 0,
                tokenOut: address(tokenOut),
                amountOut: 1 ether
            });
    
            // call as PlasmaVault to pass authorization check
            vm.prank(plasmaVault);
            executor.execute(data_);
    
            // sanity: internal balance address should now be non-zero
            (address assetAddrBefore,) = executor.getBalance();
            assertEq(assetAddrBefore, address(tokenOut));
    
            // prepare arbitrary target and data for recovery (won't be reached)
            address target = address(delegateShortcuts);
            bytes memory recoveryData = abi.encodeWithSignature(
                "executeShortcut(bytes32,bytes32,bytes32[],bytes[])",
                bytes32(0),
                bytes32(0),
                new bytes32[](0),
                new bytes[](0)
            );
    
            // when / then: recovery should revert due to non-empty internal balance,
            // hitting the `if (_balance.assetAddress != address(0))` true branch
            vm.prank(plasmaVault);
            vm.expectRevert(EnsoExecutor.EnsoExecutorBalanceNotEmpty.selector);
            executor.recovery(target, recoveryData);
        }

    function test_recovery_RevertsWhenTargetIsZeroAddress_opix_target_branch_255_true() public {
            // given: make this test contract the authorized PlasmaVault
            address plasmaVault = address(this);
            address weth = address(0xBEEF); // non-zero dummy WETH address
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
            // ensure internal balance is empty so we pass the `_balance.assetAddress != address(0)` check
            (address assetAddrBefore, uint256 assetBalBefore) = executor.getBalance();
            assertEq(assetAddrBefore, address(0));
            assertEq(assetBalBefore, 0);
    
            // when: call recovery with zero target to trigger `if (target_ == address(0))` true branch
            address target = address(0);
            bytes memory data = abi.encodeWithSignature("dummy()");
    
            vm.prank(plasmaVault);
            vm.expectRevert(EnsoExecutor.EnsoExecutorInvalidTargetAddress.selector);
            executor.recovery(target, data);
        }

    function test_recovery_RevertsWhenDataIsEmpty_opix_target_branch_260_true() public {
            // given: this test contract is the authorized PlasmaVault
            address plasmaVault = address(this);
            address weth = address(0xBEEF); // non-zero dummy WETH address
            MockDelegateEnsoShortcuts delegateShortcuts = new MockDelegateEnsoShortcuts();
            EnsoExecutor executor = new EnsoExecutor(address(delegateShortcuts), weth, plasmaVault);
    
            // ensure internal balance is empty so we pass the `_balance.assetAddress != address(0)` check
            (address assetAddrBefore, uint256 assetBalBefore) = executor.getBalance();
            assertEq(assetAddrBefore, address(0));
            assertEq(assetBalBefore, 0);
    
            // when: call recovery with non-zero target but EMPTY data to trigger
            // `if (data_.length == 0)` true branch at opix-target-branch-260
            address target = address(delegateShortcuts);
            bytes memory emptyData = "";
    
            vm.prank(plasmaVault);
            vm.expectRevert(EnsoExecutor.EnsoExecutorInvalidData.selector);
            executor.recovery(target, emptyData);
        }
}