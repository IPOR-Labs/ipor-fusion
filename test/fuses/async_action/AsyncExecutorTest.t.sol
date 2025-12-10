// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AsyncExecutor, SwapExecutorEthData} from "../../../contracts/fuses/async_action/AsyncExecutor.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title MockPriceOracle
/// @notice Mock price oracle for testing AsyncExecutor
contract MockPriceOracle is IPriceOracleMiddleware {
    address public QUOTE_CURRENCY;
    uint256 public QUOTE_CURRENCY_DECIMALS;
    mapping(address => uint256) public prices;
    mapping(address => uint256) public priceDecimals;

    constructor() {
        QUOTE_CURRENCY = address(0x0000000000000000000000000000000000000348); // USD
        QUOTE_CURRENCY_DECIMALS = 8;
    }

    function setAssetPrice(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = price_;
        priceDecimals[asset_] = decimals_;
    }

    function getAssetPrice(address asset_) external view override returns (uint256, uint256) {
        return (prices[asset_], priceDecimals[asset_]);
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external view override returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        uint256 len = assets_.length;
        assetPrices = new uint256[](len);
        decimalsList = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            assetPrices[i] = prices[assets_[i]];
            decimalsList[i] = priceDecimals[assets_[i]];
        }
    }

    function getSourceOfAssetPrice(address) external pure override returns (address) {
        return address(0);
    }

    function setAssetsPricesSources(address[] calldata, address[] calldata) external override {}
}

/// @title MockPlasmaVault
/// @notice Mock Plasma Vault that implements IERC4626 for testing AsyncExecutor
contract MockPlasmaVault is MockERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) MockERC4626(asset_, name_, symbol_) {}

    /// @notice Allows this contract to call AsyncExecutor functions
    function callExecutorExecute(AsyncExecutor executor_, SwapExecutorEthData calldata data_) external {
        executor_.execute(data_);
    }

    /// @notice Allows this contract to call AsyncExecutor fetchAssets
    function callExecutorFetchAssets(
        AsyncExecutor executor_,
        address[] calldata assets_,
        address priceOracle_,
        uint256 slippage_
    ) external {
        executor_.fetchAssets(assets_, priceOracle_, slippage_);
    }
}

/// @title MockTarget
/// @notice Mock target contract for testing execute calls
contract MockTarget {
    event CallReceived(address caller, bytes data, uint256 value);

    function execute() external payable {
        emit CallReceived(msg.sender, msg.data, msg.value);
    }
}

/// @title AsyncExecutorTest
/// @notice Unit tests for AsyncExecutor contract
/// @author IPOR Labs
contract AsyncExecutorTest is Test {
    AsyncExecutor private executor;
    MockERC20 private token;
    MockERC20 private underlyingToken;
    MockPlasmaVault private plasmaVault;
    MockPriceOracle private priceOracle;
    MockTarget private mockTarget;
    address private constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    /// @notice Sets up the test environment
    function setUp() public {
        underlyingToken = new MockERC20("Underlying Token", "UND", 6);
        token = new MockERC20("Test Token", "TEST", 18);
        priceOracle = new MockPriceOracle();
        plasmaVault = new MockPlasmaVault(underlyingToken, "Plasma Vault", "PV");
        mockTarget = new MockTarget();

        executor = new AsyncExecutor(WETH, address(plasmaVault));

        // Set up price oracle with prices
        priceOracle.setAssetPrice(address(token), 1e18, 18); // 1 USD per token
        priceOracle.setAssetPrice(address(underlyingToken), 1e8, 8); // 1 USD per underlying token (8 decimals)
    }

    /// @notice Test that constructor reverts when WETH address is zero
    function testConstructorRevertsWhenWethIsZero() public {
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidWethAddress.selector);
        new AsyncExecutor(address(0), address(plasmaVault));
    }

    /// @notice Test that constructor reverts when Plasma Vault address is zero
    function testConstructorRevertsWhenPlasmaVaultIsZero() public {
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidPlasmaVaultAddress.selector);
        new AsyncExecutor(WETH, address(0));
    }

    /// @notice Test that constructor sets values correctly
    function testConstructorSetsValues() public {
        assertEq(executor.W_ETH(), WETH);
        assertEq(executor.PLASMA_VAULT(), address(plasmaVault));
        assertEq(executor.balance(), 0);
    }

    /// @notice Test that onlyPlasmaVault modifier reverts for unauthorized caller
    function testOnlyPlasmaVaultRevertsForUnauthorizedCaller() public {
        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.expectRevert(AsyncExecutor.AsyncExecutorUnauthorizedCaller.selector);
        executor.execute(data);
    }

    /// @notice Test that execute reverts when array lengths mismatch
    function testExecuteRevertsWhenArrayLengthsMismatch() public {
        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](1),
            callDatas: new bytes[](0), // Different length
            ethAmounts: new uint256[](1),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidArrayLength.selector);
        executor.execute(data);
    }

    /// @notice Test that execute updates balance when balance is zero
    function testExecuteUpdatesBalanceWhenZero() public {
        uint256 amount = 1000e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        executor.execute(data);

        // Balance should be updated (converted to underlying token units)
        assertGt(executor.balance(), 0, "Balance should be updated");
    }

    /// @notice Test that execute does not update balance when balance is greater than zero
    function testExecuteDoesNotUpdateBalanceWhenGreaterThanZero() public {
        uint256 amount = 1000e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        // First execute to set balance
        vm.prank(address(plasmaVault));
        executor.execute(data);

        uint256 balanceAfterFirst = executor.balance();

        // Second execute should not update balance
        vm.prank(address(plasmaVault));
        executor.execute(data);

        uint256 balanceAfterSecond = executor.balance();
        assertEq(balanceAfterSecond, balanceAfterFirst, "Balance should not be updated");
    }

    /// @notice Test that execute calls target with ETH
    function testExecuteCallsTargetWithEth() public {
        uint256 ethAmount = 1 ether;
        vm.deal(address(executor), ethAmount);

        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);

        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockTarget.execute.selector);

        uint256[] memory ethAmounts = new uint256[](1);
        ethAmounts[0] = ethAmount;

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        vm.expectEmit(true, false, false, true);
        emit MockTarget.CallReceived(address(executor), callDatas[0], ethAmount);
        executor.execute(data);
    }

    /// @notice Test that execute calls target without ETH
    function testExecuteCallsTargetWithoutEth() public {
        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);

        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockTarget.execute.selector);

        uint256[] memory ethAmounts = new uint256[](1);
        ethAmounts[0] = 0;

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        vm.expectEmit(true, false, false, true);
        emit MockTarget.CallReceived(address(executor), callDatas[0], 0);
        executor.execute(data);
    }

    /// @notice Test that execute emits AsyncExecutorExecuted event
    function testExecuteEmitsEvent() public {
        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        vm.expectEmit(true, true, false, false);
        emit AsyncExecutor.AsyncExecutorExecuted(address(plasmaVault), address(token));
        executor.execute(data);
    }

    /// @notice Test that fetchAssets reverts when priceOracle is zero
    function testFetchAssetsRevertsWhenPriceOracleIsZero() public {
        address[] memory assets = new address[](1);
        assets[0] = address(token);

        vm.prank(address(plasmaVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidPriceOracleAddress.selector);
        executor.fetchAssets(assets, address(0), 0);
    }

    /// @notice Test that fetchAssets reverts when slippage exceeds WAD
    function testFetchAssetsRevertsWhenSlippageExceedsWad() public {
        address[] memory assets = new address[](1);
        assets[0] = address(token);

        vm.prank(address(plasmaVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidSlippage.selector);
        executor.fetchAssets(assets, address(priceOracle), 2e18); // 200% slippage
    }

    /// @notice Test that fetchAssets succeeds when balance is zero
    function testFetchAssetsSucceedsWhenBalanceIsZero() public {
        uint256 amount = 100e18;
        token.mint(address(executor), amount);

        address[] memory assets = new address[](1);
        assets[0] = address(token);

        uint256 plasmaVaultBalanceBefore = token.balanceOf(address(plasmaVault));

        vm.prank(address(plasmaVault));
        executor.fetchAssets(assets, address(priceOracle), 0);

        uint256 plasmaVaultBalanceAfter = token.balanceOf(address(plasmaVault));
        assertEq(plasmaVaultBalanceAfter, plasmaVaultBalanceBefore + amount, "Tokens should be transferred");
        assertEq(executor.balance(), 0, "Balance should be reset to zero");
    }

    /// @notice Test that fetchAssets reverts when balance is insufficient
    function testFetchAssetsRevertsWhenBalanceInsufficient() public {
        uint256 amount = 1000e18;
        token.mint(address(executor), amount);

        // Set balance by executing first
        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        executor.execute(data);

        // Simulate loss by burning most tokens (using deal to set balance directly)
        uint256 remainingAmount = amount / 10; // 10% remaining
        deal(address(token), address(executor), remainingAmount);

        address[] memory assets = new address[](1);
        assets[0] = address(token);

        vm.prank(address(plasmaVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorBalanceNotEnough.selector);
        executor.fetchAssets(assets, address(priceOracle), 0.01e18); // 1% slippage
    }

    /// @notice Test that fetchAssets transfers multiple assets
    function testFetchAssetsTransfersMultipleAssets() public {
        MockERC20 token2 = new MockERC20("Test Token 2", "TEST2", 18);
        priceOracle.setAssetPrice(address(token2), 1e18, 18);

        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        token.mint(address(executor), amount1);
        token2.mint(address(executor), amount2);

        address[] memory assets = new address[](2);
        assets[0] = address(token);
        assets[1] = address(token2);

        vm.prank(address(plasmaVault));
        executor.fetchAssets(assets, address(priceOracle), 0);

        assertEq(token.balanceOf(address(plasmaVault)), amount1, "Token1 should be transferred");
        assertEq(token2.balanceOf(address(plasmaVault)), amount2, "Token2 should be transferred");
    }

    /// @notice Test that fetchAssets skips assets with zero balance
    function testFetchAssetsSkipsZeroBalanceAssets() public {
        MockERC20 token2 = new MockERC20("Test Token 2", "TEST2", 18);
        priceOracle.setAssetPrice(address(token2), 1e18, 18);

        uint256 amount1 = 100e18;
        token.mint(address(executor), amount1);
        // token2 has zero balance

        address[] memory assets = new address[](2);
        assets[0] = address(token);
        assets[1] = address(token2);

        vm.prank(address(plasmaVault));
        executor.fetchAssets(assets, address(priceOracle), 0);

        assertEq(token.balanceOf(address(plasmaVault)), amount1, "Token1 should be transferred");
        assertEq(token2.balanceOf(address(plasmaVault)), 0, "Token2 should not be transferred");
    }

    /// @notice Test that fetchAssets emits AsyncExecutorAssetsFetched event
    function testFetchAssetsEmitsEvent() public {
        uint256 amount = 100e18;
        token.mint(address(executor), amount);

        address[] memory assets = new address[](1);
        assets[0] = address(token);

        vm.prank(address(plasmaVault));
        vm.expectEmit(false, false, false, true);
        emit AsyncExecutor.AsyncExecutorAssetsFetched(assets);
        executor.fetchAssets(assets, address(priceOracle), 0);
    }

    /// @notice Test that _calculateAssetUsdValue reverts when asset is zero
    function testCalculateAssetUsdValueRevertsWhenAssetIsZero() public {
        // This is tested indirectly through _updateBalance
        uint256 amount = 100e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(0), // Zero address
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidAssetAddress.selector);
        executor.execute(data);
    }

    /// @notice Test that _calculateAssetUsdValue returns zero when balance is zero
    function testCalculateAssetUsdValueReturnsZeroWhenBalanceIsZero() public {
        // Executor has no tokens, so balance should be zero
        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        executor.execute(data);

        // Balance should be zero since executor has no tokens
        assertEq(executor.balance(), 0, "Balance should be zero");
    }

    /// @notice Test that _updateBalance reverts when priceOracle is zero
    function testUpdateBalanceRevertsWhenPriceOracleIsZero() public {
        uint256 amount = 100e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(0) // Zero address
        });

        vm.prank(address(plasmaVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidPriceOracleAddress.selector);
        executor.execute(data);
    }

    /// @notice Test that _convertUsdPortfolioToUnderlying returns zero when balanceInUsd is zero
    function testConvertUsdPortfolioToUnderlyingReturnsZeroWhenBalanceInUsdIsZero() public {
        // Executor has no tokens, so balanceInUsd should be zero
        address[] memory assets = new address[](1);
        assets[0] = address(token);

        vm.prank(address(plasmaVault));
        executor.fetchAssets(assets, address(priceOracle), 0);

        // Should succeed without reverting (balanceInUsd is zero, so no validation)
        assertEq(executor.balance(), 0, "Balance should remain zero");
    }

    /// @notice Test that _resolveUnderlyingAsset reverts when underlying asset is zero
    function testResolveUnderlyingAssetRevertsWhenUnderlyingAssetIsZero() public {
        // Create a mock vault that returns zero for asset()
        MockPlasmaVault zeroAssetVault = new MockPlasmaVault(
            IERC20(address(0)), // Zero address
            "Zero Asset Vault",
            "ZAV"
        );
        AsyncExecutor zeroAssetExecutor = new AsyncExecutor(WETH, address(zeroAssetVault));

        uint256 amount = 100e18;
        token.mint(address(zeroAssetExecutor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(zeroAssetVault));
        vm.expectRevert(AsyncExecutor.AsyncExecutorInvalidUnderlyingAssetAddress.selector);
        zeroAssetExecutor.execute(data);
    }

    /// @notice Test that _convertUsdToUnderlyingAmount handles priceDecimals < 18
    function testConvertUsdToUnderlyingAmountHandlesPriceDecimalsLessThan18() public {
        // Set price with 8 decimals (less than 18)
        priceOracle.setAssetPrice(address(token), 1e8, 8);
        priceOracle.setAssetPrice(address(underlyingToken), 1e8, 8);

        uint256 amount = 1000e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        executor.execute(data);

        // Should succeed and calculate balance correctly
        assertGt(executor.balance(), 0, "Balance should be calculated correctly");
    }

    /// @notice Test that _convertUsdToUnderlyingAmount handles priceDecimals > 18
    function testConvertUsdToUnderlyingAmountHandlesPriceDecimalsGreaterThan18() public {
        // Set price with 20 decimals (greater than 18)
        priceOracle.setAssetPrice(address(token), 1e20, 20);
        priceOracle.setAssetPrice(address(underlyingToken), 1e20, 20);

        uint256 amount = 1000e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        executor.execute(data);

        // Should succeed and calculate balance correctly
        assertGt(executor.balance(), 0, "Balance should be calculated correctly");
    }

    /// @notice Test that _convertUsdToUnderlyingAmount handles priceDecimals == 18
    function testConvertUsdToUnderlyingAmountHandlesPriceDecimalsEqualTo18() public {
        // Set price with 18 decimals (equal to 18)
        priceOracle.setAssetPrice(address(token), 1e18, 18);
        priceOracle.setAssetPrice(address(underlyingToken), 1e18, 18);

        uint256 amount = 1000e18;
        token.mint(address(executor), amount);

        SwapExecutorEthData memory data = SwapExecutorEthData({
            tokenIn: address(token),
            targets: new address[](0),
            callDatas: new bytes[](0),
            ethAmounts: new uint256[](0),
            priceOracle: address(priceOracle)
        });

        vm.prank(address(plasmaVault));
        executor.execute(data);

        // Should succeed and calculate balance correctly
        assertGt(executor.balance(), 0, "Balance should be calculated correctly");
    }

    /// @notice Test that receive() function works correctly
    function testReceiveFunction() public {
        uint256 ethAmount = 1 ether;
        vm.deal(address(this), ethAmount);

        (bool success, ) = address(executor).call{value: ethAmount}("");
        assertTrue(success, "ETH transfer should succeed");
        assertEq(address(executor).balance, ethAmount, "Executor should have received ETH");
    }
}
