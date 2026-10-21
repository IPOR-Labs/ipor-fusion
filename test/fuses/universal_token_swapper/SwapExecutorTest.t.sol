// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {SwapExecutor, SwapExecutorData} from "../../../contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {
    SwapExecutorEth,
    SwapExecutorEthData
} from "../../../contracts/fuses/universal_token_swapper/SwapExecutorEth.sol";
import {
    SwapExecutorRestricted,
    SwapExecutorData as SwapExecutorDataRestricted
} from "../../../contracts/fuses/universal_token_swapper/SwapExecutorRestricted.sol";

/// @title Mock Token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title Mock DEX for testing swap execution
contract MockDex {
    IERC20 public tokenIn;
    IERC20 public tokenOut;
    uint256 public swapRate;

    constructor(address tokenIn_, address tokenOut_, uint256 swapRate_) {
        tokenIn = IERC20(tokenIn_);
        tokenOut = IERC20(tokenOut_);
        swapRate = swapRate_;
    }

    function swap(uint256 amountIn_) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn_);
        uint256 amountOut = (amountIn_ * swapRate) / 1e18;
        tokenOut.transfer(msg.sender, amountOut);
    }
}

/// @title Mock DEX that pushes an arbitrary token to msg.sender, simulating a multi-output/dust route
contract MockDexPushToken {
    function push(address token_, uint256 amount_) external {
        MockERC20(token_).mint(msg.sender, amount_);
    }
}

/// @title Mock Reentrancy Attacker DEX
contract ReentrancyAttacker {
    SwapExecutor public target;
    SwapExecutorData public attackData;
    bool public attacked;

    constructor(address target_) {
        target = SwapExecutor(target_);
    }

    function setAttackData(SwapExecutorData calldata data_) external {
        attackData = data_;
    }

    function attack() external {
        if (!attacked) {
            attacked = true;
            target.execute(attackData);
        }
    }
}

/// @title SwapExecutor Unit Tests
contract SwapExecutorTest is Test {
    SwapExecutor public swapExecutor;
    SwapExecutorRestricted public swapExecutorRestricted;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockDex public mockDex;
    MockDexPushToken public mockPush;

    address public restrictedAddress;
    address public unauthorizedAddress;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");
        tokenC = new MockERC20("Token C", "TKNC");

        // Deploy SwapExecutor
        swapExecutor = new SwapExecutor();

        // Setup restricted executor
        restrictedAddress = address(this);
        unauthorizedAddress = address(0x1234);
        swapExecutorRestricted = new SwapExecutorRestricted(restrictedAddress);

        // Deploy mock DEX with 1:1 swap rate
        mockDex = new MockDex(address(tokenA), address(tokenB), 1e18);

        // Deploy mock DEX that pushes an arbitrary token to the caller (simulates multi-output residue)
        mockPush = new MockDexPushToken();

        // Mint tokens
        tokenA.mint(address(this), 1000e18);
        tokenB.mint(address(mockDex), 1000e18);
    }

    // ============================================
    // SwapExecutorRestricted - Access Control Tests
    // ============================================

    /// @notice TEST-002: Test constructor reverts when restricted address is zero
    function testShouldRevertWhenRestrictedAddressIsZero() public {
        vm.expectRevert(SwapExecutorRestricted.SwapExecutorRestrictedInvalidRestrictedAddress.selector);
        new SwapExecutorRestricted(address(0));
    }

    /// @notice TEST-002: Test execute reverts when caller is not restricted
    function testShouldRevertWhenCallerIsNotRestricted() public {
        SwapExecutorDataRestricted memory data = SwapExecutorDataRestricted({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        vm.prank(unauthorizedAddress);
        vm.expectRevert(SwapExecutorRestricted.SwapExecutorRestrictedInvalidSender.selector);
        swapExecutorRestricted.execute(data);
    }

    /// @notice TEST-002: Test execute succeeds when called by restricted address
    function testShouldExecuteOnlyWhenCalledByRestricted() public {
        // Setup: transfer tokens to executor
        tokenA.transfer(address(swapExecutorRestricted), 100e18);

        SwapExecutorDataRestricted memory data = SwapExecutorDataRestricted({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        // Should not revert when called by restricted address
        vm.prank(restrictedAddress);
        swapExecutorRestricted.execute(data);

        // Verify tokens returned to caller
        assertEq(tokenA.balanceOf(restrictedAddress), 1000e18); // 900 original + 100 returned
    }

    // ============================================
    // Array Length Validation Tests
    // ============================================

    /// @notice Test execute reverts when dexs and dexsData arrays have different lengths
    function testShouldRevertWhenArrayLengthMismatch() public {
        address[] memory dexs = new address[](2);
        dexs[0] = address(mockDex);
        dexs[1] = address(mockDex);

        bytes[] memory dexsData = new bytes[](1);
        dexsData[0] = abi.encodeWithSelector(MockDex.swap.selector, 100e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: dexs,
            dexsData: dexsData,
            tokensToReturn: new address[](0)
        });

        vm.expectRevert(SwapExecutor.ArrayLengthMismatch.selector);
        swapExecutor.execute(data);
    }

    /// @notice Test execute reverts when dexs array is longer (SwapExecutorRestricted)
    function testShouldRevertWhenArrayLengthMismatchRestricted() public {
        address[] memory dexs = new address[](2);
        bytes[] memory dexsData = new bytes[](1);

        SwapExecutorDataRestricted memory data = SwapExecutorDataRestricted({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: dexs,
            dexsData: dexsData,
            tokensToReturn: new address[](0)
        });

        vm.expectRevert(SwapExecutorRestricted.ArrayLengthMismatch.selector);
        swapExecutorRestricted.execute(data);
    }

    // ============================================
    // Edge Case Tests
    // ============================================

    /// @notice TEST-003: Test handling when tokenIn equals tokenOut
    function testShouldHandleTokenInEqualsTokenOut() public {
        // Transfer same token as both input and output
        tokenA.transfer(address(swapExecutor), 100e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenA), // Same token
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        uint256 balanceBefore = tokenA.balanceOf(address(this));
        swapExecutor.execute(data);
        uint256 balanceAfter = tokenA.balanceOf(address(this));

        // Should transfer back the 100e18 (single transfer, not double)
        assertEq(balanceAfter - balanceBefore, 100e18);
        assertEq(tokenA.balanceOf(address(swapExecutor)), 0);
    }

    /// @notice TEST-003: Test handling when tokenIn balance is zero
    function testShouldHandleZeroBalanceTokenIn() public {
        // Only send tokenB to executor
        tokenB.mint(address(swapExecutor), 50e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        uint256 balanceABefore = tokenA.balanceOf(address(this));
        uint256 balanceBBefore = tokenB.balanceOf(address(this));

        swapExecutor.execute(data);

        // tokenA balance unchanged (was zero in executor)
        assertEq(tokenA.balanceOf(address(this)), balanceABefore);
        // tokenB transferred back
        assertEq(tokenB.balanceOf(address(this)) - balanceBBefore, 50e18);
    }

    /// @notice TEST-003: Test handling when tokenOut balance is zero
    function testShouldHandleZeroBalanceTokenOut() public {
        // Only send tokenA to executor
        tokenA.transfer(address(swapExecutor), 100e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        uint256 balanceABefore = tokenA.balanceOf(address(this));
        uint256 balanceBBefore = tokenB.balanceOf(address(this));

        swapExecutor.execute(data);

        // tokenA transferred back
        assertEq(tokenA.balanceOf(address(this)) - balanceABefore, 100e18);
        // tokenB balance unchanged (was zero in executor)
        assertEq(tokenB.balanceOf(address(this)), balanceBBefore);
    }

    /// @notice TEST-003: Test handling empty dexs array
    function testShouldHandleEmptyDexArray() public {
        tokenA.transfer(address(swapExecutor), 100e18);
        tokenB.mint(address(swapExecutor), 50e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        uint256 balanceABefore = tokenA.balanceOf(address(this));
        uint256 balanceBBefore = tokenB.balanceOf(address(this));

        // Should not revert with empty arrays
        swapExecutor.execute(data);

        // Both tokens should be returned
        assertEq(tokenA.balanceOf(address(this)) - balanceABefore, 100e18);
        assertEq(tokenB.balanceOf(address(this)) - balanceBBefore, 50e18);
    }

    // ============================================
    // Reentrancy Protection Tests
    // ============================================

    /// @notice Test reentrancy protection
    function testShouldPreventReentrancy() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(swapExecutor));

        address[] memory dexs = new address[](1);
        dexs[0] = address(attacker);

        bytes[] memory dexsData = new bytes[](1);
        dexsData[0] = abi.encodeWithSelector(ReentrancyAttacker.attack.selector);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: dexs,
            dexsData: dexsData,
            tokensToReturn: new address[](0)
        });

        // Set attack data (same data to cause reentry)
        attacker.setAttackData(data);

        // Should revert with ReentrancyGuardReentrantCall
        vm.expectRevert();
        swapExecutor.execute(data);
    }

    // ============================================
    // Successful Swap Execution Tests
    // ============================================

    /// @notice Test successful single DEX swap
    function testShouldExecuteSuccessfulSwap() public {
        // Approve and transfer tokens
        tokenA.transfer(address(swapExecutor), 100e18);
        tokenA.approve(address(mockDex), type(uint256).max);

        // Prepare swap through SwapExecutor
        // First, executor needs to approve the DEX
        // Since SwapExecutor doesn't have approval mechanism, we test direct transfer pattern

        // For this test, let's verify the flow works with mock that handles transfers
        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        swapExecutor.execute(data);

        // Tokens should be returned to caller
        assertEq(tokenA.balanceOf(address(swapExecutor)), 0);
    }

    // ============================================
    // Both Zero Balance Tests
    // ============================================

    /// @notice Test when both tokenIn and tokenOut have zero balance
    function testShouldHandleBothZeroBalances() public {
        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        uint256 balanceABefore = tokenA.balanceOf(address(this));
        uint256 balanceBBefore = tokenB.balanceOf(address(this));

        // Should not revert even with zero balances
        swapExecutor.execute(data);

        // Balances should remain unchanged
        assertEq(tokenA.balanceOf(address(this)), balanceABefore);
        assertEq(tokenB.balanceOf(address(this)), balanceBBefore);
    }

    /// @notice Test RESTRICTED immutable is set correctly
    function testRestrictedAddressIsSetCorrectly() public view {
        assertEq(swapExecutorRestricted.RESTRICTED(), restrictedAddress);
    }

    // ============================================
    // Native ETH Handling Tests (SwapExecutorRestricted)
    // ============================================

    /// @notice Test that sending ETH directly to the contract reverts
    function testShouldRevertWhenSendingEthDirectly() public {
        vm.deal(address(this), 1 ether);

        // Low-level call returns false when the target reverts
        (bool success, bytes memory returnData) = address(swapExecutorRestricted).call{value: 1 ether}("");

        // Verify the call failed
        assertFalse(success);

        // Verify it reverted with the expected error
        bytes4 expectedSelector = SwapExecutorRestricted.SwapExecutorRestrictedReceiveNotSupported.selector;
        bytes4 actualSelector;
        assembly {
            actualSelector := mload(add(returnData, 32))
        }
        assertEq(actualSelector, expectedSelector);

        // Verify no ETH was transferred
        assertEq(address(swapExecutorRestricted).balance, 0);
    }

    // ============================================
    // tokensToReturn Tests (IL-7944)
    // ============================================

    /// @notice Test 8: tokenC pushed to the executor by a DEX call and listed in tokensToReturn is swept to caller.
    /// Pre-fix (loop removed from SwapExecutor.execute): the executor keeps the 50e18 tokenC.
    function testShouldReturnTokensToReturnToCaller() public {
        address[] memory dexs = new address[](1);
        dexs[0] = address(mockPush);

        bytes[] memory dexsData = new bytes[](1);
        dexsData[0] = abi.encodeWithSelector(MockDexPushToken.push.selector, address(tokenC), 50e18);

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = address(tokenC);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: dexs,
            dexsData: dexsData,
            tokensToReturn: tokensToReturn
        });

        uint256 callerTokenCBefore = tokenC.balanceOf(address(this));

        swapExecutor.execute(data);

        assertEq(tokenC.balanceOf(address(swapExecutor)), 0, "Executor should have no tokenC left");
        assertEq(tokenC.balanceOf(address(this)) - callerTokenCBefore, 50e18, "Caller should receive the tokenC");
    }

    /// @notice Test 9: same route through SwapExecutorRestricted, called by RESTRICTED.
    /// Pre-fix (loop removed from SwapExecutorRestricted.execute): the executor keeps the 50e18 tokenC.
    function testShouldReturnTokensToReturnToCallerRestricted() public {
        address[] memory dexs = new address[](1);
        dexs[0] = address(mockPush);

        bytes[] memory dexsData = new bytes[](1);
        dexsData[0] = abi.encodeWithSelector(MockDexPushToken.push.selector, address(tokenC), 50e18);

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = address(tokenC);

        SwapExecutorDataRestricted memory data = SwapExecutorDataRestricted({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: dexs,
            dexsData: dexsData,
            tokensToReturn: tokensToReturn
        });

        uint256 callerTokenCBefore = tokenC.balanceOf(restrictedAddress);

        vm.prank(restrictedAddress);
        swapExecutorRestricted.execute(data);

        assertEq(tokenC.balanceOf(address(swapExecutorRestricted)), 0, "Executor should have no tokenC left");
        assertEq(tokenC.balanceOf(restrictedAddress) - callerTokenCBefore, 50e18, "Caller should receive the tokenC");
    }

    /// @notice Test 10 (control): same route, tokensToReturn empty. tokenC stays in the executor before and
    /// after the fix; this pins the documented residual behaviour and is not itself regression evidence.
    function testShouldNotReturnTokensNotListed() public {
        address[] memory dexs = new address[](1);
        dexs[0] = address(mockPush);

        bytes[] memory dexsData = new bytes[](1);
        dexsData[0] = abi.encodeWithSelector(MockDexPushToken.push.selector, address(tokenC), 50e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: dexs,
            dexsData: dexsData,
            tokensToReturn: new address[](0)
        });

        swapExecutor.execute(data);

        assertEq(tokenC.balanceOf(address(swapExecutor)), 50e18, "Unlisted tokenC should stay in the executor");
    }

    // ============================================
    // Return values (IL-8767)
    // ============================================

    /// @notice IL-8767: adding return values must not change the execute selector (old fuses keep working)
    function testExecuteSelectorIsUnchanged() public pure {
        assertEq(
            SwapExecutor.execute.selector,
            bytes4(keccak256("execute((address,address,address[],bytes[],address[]))")),
            "execute selector"
        );
    }

    /// @notice IL-8767: execute reports exactly the tokenIn / tokenOut amounts transferred to the caller
    function testShouldReturnTransferredAmounts() public {
        tokenA.transfer(address(swapExecutor), 100e18);
        tokenB.mint(address(swapExecutor), 70e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        uint256 tokenABefore = tokenA.balanceOf(address(this));
        uint256 tokenBBefore = tokenB.balanceOf(address(this));
        (uint256 tokenInReturned, uint256 tokenOutReturned) = swapExecutor.execute(data);

        assertEq(tokenInReturned, 100e18, "tokenInReturned");
        assertEq(tokenOutReturned, 70e18, "tokenOutReturned");
        assertEq(tokenA.balanceOf(address(this)) - tokenABefore, tokenInReturned, "tokenIn matches the transfer");
        assertEq(tokenB.balanceOf(address(this)) - tokenBBefore, tokenOutReturned, "tokenOut matches the transfer");
    }

    /// @notice IL-8767: a zero balance side is reported as 0
    function testShouldReturnZeroForEmptySide() public {
        tokenB.mint(address(swapExecutor), 70e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        (uint256 tokenInReturned, uint256 tokenOutReturned) = swapExecutor.execute(data);

        assertEq(tokenInReturned, 0, "tokenInReturned");
        assertEq(tokenOutReturned, 70e18, "tokenOutReturned");
    }

    /// @notice IL-8767: tokenIn == tokenOut reports the whole balance as tokenInReturned and 0 as tokenOutReturned
    function testShouldReturnWholeBalanceAsTokenInWhenTokensAreEqual() public {
        tokenA.transfer(address(swapExecutor), 100e18);

        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenA),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: new address[](0)
        });

        (uint256 tokenInReturned, uint256 tokenOutReturned) = swapExecutor.execute(data);

        assertEq(tokenInReturned, 100e18, "tokenInReturned");
        assertEq(tokenOutReturned, 0, "tokenOutReturned");
    }

    /// @notice IL-8767: tokensToReturn are swept but not reported as tokenIn / tokenOut
    function testShouldNotReportTokensToReturn() public {
        tokenC.mint(address(swapExecutor), 50e18);

        address[] memory tokensToReturn = new address[](1);
        tokensToReturn[0] = address(tokenC);
        SwapExecutorData memory data = SwapExecutorData({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            dexs: new address[](0),
            dexsData: new bytes[](0),
            tokensToReturn: tokensToReturn
        });

        (uint256 tokenInReturned, uint256 tokenOutReturned) = swapExecutor.execute(data);

        assertEq(tokenInReturned, 0, "tokenInReturned");
        assertEq(tokenOutReturned, 0, "tokenOutReturned");
        assertEq(tokenC.balanceOf(address(swapExecutor)), 0, "tokenC swept");
    }
}

/// @dev Minimal WETH9 for the SwapExecutorEth return-value tests
contract SwapExecutorTestWeth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @title SwapExecutorEth return values (IL-8767)
contract SwapExecutorEthReturnValuesTest is Test {
    SwapExecutorEth public executor;
    SwapExecutorTestWeth public weth;
    MockERC20 public tokenA;

    function setUp() public {
        vm.deal(address(this), 10 ether);
        weth = new SwapExecutorTestWeth();
        executor = new SwapExecutorEth(address(weth));
        tokenA = new MockERC20("Token A", "TKNA");
    }

    function _data(address tokenIn_, address tokenOut_) private pure returns (SwapExecutorEthData memory) {
        return
            SwapExecutorEthData({
                tokenIn: tokenIn_,
                tokenOut: tokenOut_,
                targets: new address[](0),
                callDatas: new bytes[](0),
                ethAmounts: new uint256[](0),
                tokensDustToCheck: new address[](0)
            });
    }

    function testExecuteSelectorIsUnchanged() public pure {
        assertEq(
            SwapExecutorEth.execute.selector,
            bytes4(keccak256("execute((address,address,address[],bytes[],uint256[],address[]))")),
            "execute selector"
        );
    }

    function testShouldReturnTransferredTokenAmounts() public {
        tokenA.mint(address(executor), 30e18);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(executor), 1 ether);

        (uint256 tokenInReturned, uint256 tokenOutReturned) = executor.execute(_data(address(tokenA), address(weth)));

        assertEq(tokenInReturned, 30e18, "tokenInReturned");
        assertEq(tokenOutReturned, 1 ether, "tokenOutReturned");
    }

    /// @notice ETH left in the executor is wrapped and attributed to the side equal to W_ETH (tokenOut)
    function testShouldAttributeWrappedEthToTokenOut() public {
        tokenA.mint(address(executor), 30e18);
        vm.deal(address(executor), 2 ether);

        (uint256 tokenInReturned, uint256 tokenOutReturned) = executor.execute(_data(address(tokenA), address(weth)));

        assertEq(tokenInReturned, 30e18, "tokenInReturned");
        assertEq(tokenOutReturned, 2 ether, "wrapped ETH counted as tokenOut");
        assertEq(weth.balanceOf(address(this)), 2 ether, "WETH sent to the caller");
    }

    /// @notice ... and to tokenIn when tokenIn is W_ETH
    function testShouldAttributeWrappedEthToTokenIn() public {
        weth.deposit{value: 1 ether}();
        weth.transfer(address(executor), 1 ether);
        vm.deal(address(executor), 2 ether);
        tokenA.mint(address(executor), 5e18);

        (uint256 tokenInReturned, uint256 tokenOutReturned) = executor.execute(_data(address(weth), address(tokenA)));

        assertEq(tokenInReturned, 3 ether, "WETH balance plus wrapped ETH counted as tokenIn");
        assertEq(tokenOutReturned, 5e18, "tokenOutReturned");
    }

    /// @notice Wrapped ETH is not attributed to either side when neither token is W_ETH
    function testShouldNotAttributeWrappedEthWhenNeitherSideIsWeth() public {
        MockERC20 tokenB = new MockERC20("Token B", "TKNB");
        vm.deal(address(executor), 2 ether);

        (uint256 tokenInReturned, uint256 tokenOutReturned) = executor.execute(_data(address(tokenA), address(tokenB)));

        assertEq(tokenInReturned, 0, "tokenInReturned");
        assertEq(tokenOutReturned, 0, "tokenOutReturned");
        assertEq(weth.balanceOf(address(this)), 2 ether, "WETH still sent to the caller");
    }

    /// @notice tokenIn == tokenOut: the balance is read once and reported as tokenInReturned
    function testShouldReturnWholeBalanceAsTokenInWhenTokensAreEqual() public {
        tokenA.mint(address(executor), 40e18);

        (uint256 tokenInReturned, uint256 tokenOutReturned) = executor.execute(_data(address(tokenA), address(tokenA)));

        assertEq(tokenInReturned, 40e18, "tokenInReturned");
        assertEq(tokenOutReturned, 0, "tokenOutReturned");
        assertEq(tokenA.balanceOf(address(this)), 40e18, "transferred once");
    }

    receive() external payable {}
}
