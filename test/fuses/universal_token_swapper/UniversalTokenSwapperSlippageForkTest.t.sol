// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";

import {SwapExecutor} from "contracts/fuses/universal_token_swapper/SwapExecutor.sol";
import {UniversalTokenSwapperFuse, UniversalTokenSwapperEnterData, UniversalTokenSwapperData} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {UniversalTokenSwapperSubstrateLib} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperSubstrateLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

/// @title UniversalTokenSwapperSlippageForkTest
/// @notice Fork integration tests for configurable slippage and minAmountOut protection
contract UniversalTokenSwapperSlippageForkTest is Test {
    using SafeERC20 for ERC20;

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address private constant _UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;
    address private constant USDC_WHALE = 0xDa9CE944a37d218c3302F6B82a094844C6ECEb17;

    address private _plasmaVault;
    address private _withdrawManager;
    address private _priceOracle;
    address private _accessManager;

    UniversalTokenSwapperFuse private _universalTokenSwapperFuse;

    uint256 private constant _V3_SWAP_EXACT_IN = 0x00;
    address private constant _INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER = address(1);

    // Slippage values for testing
    uint256 private _configuredSlippage;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20590113);
    }

    // ==================== Test: Slippage from Substrate ====================

    /// @notice Test swap using 2% slippage configured in substrate
    function testShouldSwapWithConfiguredSlippageFromSubstrate() external {
        // Configure 2% slippage
        _configuredSlippage = 2e16; // 2%
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // Swap USDC -> USDT (stablecoin to stablecoin, minimal real slippage)
        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, 0);

        uint256 plasmaVaultUsdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceBefore = ERC20(USDT).balanceOf(_plasmaVault);

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);

        assertEq(plasmaVaultUsdcBalanceBefore, depositAmount, "USDC balance before should equal deposit");
        assertEq(plasmaVaultUsdcBalanceAfter, 0, "USDC balance after should be zero");
        assertEq(plasmaVaultUsdtBalanceBefore, 0, "USDT balance before should be zero");
        assertGt(plasmaVaultUsdtBalanceAfter, 0, "USDT balance after should be greater than zero");

        // Verify slippage is within 2% (stablecoin swap should be ~1:1)
        // USDC has 6 decimals, USDT has 6 decimals
        uint256 expectedMinOutput = (depositAmount * (1e18 - _configuredSlippage)) / 1e18;
        assertGe(plasmaVaultUsdtBalanceAfter, expectedMinOutput, "Output should be within 2% slippage");
    }

    /// @notice Test swap using default 1% slippage when substrate doesn't configure slippage
    function testShouldSwapWithDefaultSlippageWhenNotConfigured() external {
        // No slippage substrate configured - should use DEFAULT_SLIPPAGE_WAD (1%)
        _configuredSlippage = 0; // Indicates no slippage substrate
        _setupVaultWithoutSlippageSubstrate();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // Swap USDC -> USDT
        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, 0);

        uint256 plasmaVaultUsdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);

        assertEq(plasmaVaultUsdcBalanceBefore, depositAmount, "USDC balance before should equal deposit");
        assertEq(plasmaVaultUsdcBalanceAfter, 0, "USDC balance after should be zero");

        // With 1% default slippage, output should be at least 99% of input
        uint256 expectedMinOutput = (depositAmount * 99) / 100;
        assertGe(plasmaVaultUsdtBalanceAfter, expectedMinOutput, "Output should be within 1% default slippage");
    }

    // ==================== Test: minAmountOut Protection ====================

    /// @notice Test that swap reverts when minAmountOut is not reached
    function testShouldRevertWhenMinAmountOutNotReached() external {
        _configuredSlippage = 10e16; // 10% - very permissive
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // Set minAmountOut higher than what swap will return
        // Real swap USDC->USDT ~1:1, so setting 1100 USDT min (impossible)
        uint256 impossibleMinAmountOut = 1_100e6;

        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, impossibleMinAmountOut);

        // when/then - should revert (we don't check exact values as they vary)
        vm.expectRevert();
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that swap passes when minAmountOut is zero (disabled)
    function testShouldPassWhenMinAmountOutIsZero() external {
        _configuredSlippage = 5e16; // 5%
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // minAmountOut = 0 disables the check
        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, 0);

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - swap should succeed
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);
        assertGt(plasmaVaultUsdtBalanceAfter, 0, "Swap should succeed with minAmountOut = 0");
    }

    /// @notice Test that swap passes when minAmountOut is exactly met
    function testShouldPassWhenMinAmountOutExactlyMet() external {
        _configuredSlippage = 5e16; // 5%
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // Set a reasonable minAmountOut that will be met
        // Stablecoin swap ~1:1, so 990 USDT is safe
        uint256 safeMinAmountOut = 990e6;

        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, safeMinAmountOut);

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);
        assertGe(plasmaVaultUsdtBalanceAfter, safeMinAmountOut, "Output should meet minAmountOut");
    }

    // ==================== Test: USD Slippage Validation ====================

    /// @notice Test that USD-based slippage check reverts on excessive loss
    function testShouldRevertWhenUsdSlippageExceedsLimit() external {
        // Configure very tight slippage - 0.01%
        _configuredSlippage = 1e14; // 0.01%
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 10_000e6; // Large amount to see slippage effect

        _depositToVault(userOne, depositAmount);

        // Swap USDC -> USDT with very tight slippage
        // Real swap has ~0.05% slippage, so 0.01% should fail
        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, 0);

        // when/then - should revert due to USD slippage check
        vm.expectRevert(UniversalTokenSwapperFuse.UniversalTokenSwapperFuseSlippageFail.selector);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    /// @notice Test that swap passes when USD slippage is within configured limit
    function testShouldPassWhenUsdSlippageWithinLimit() external {
        // Configure reasonable slippage - 1%
        _configuredSlippage = 1e16; // 1%
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // Swap USDC -> USDT (stablecoin, <1% real slippage)
        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, 0);

        // when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then - should succeed
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);
        assertGt(plasmaVaultUsdtBalanceAfter, 0, "Swap should succeed within slippage limit");
    }

    // ==================== Test: Combined Protection ====================

    /// @notice Test that both protections work together - minAmountOut takes precedence
    function testShouldUseMinAmountOutWhenMoreRestrictive() external {
        // Configure permissive USD slippage - 10%
        _configuredSlippage = 10e16; // 10%
        _setupVault();

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        _depositToVault(userOne, depositAmount);

        // Set strict minAmountOut - more restrictive than 10% USD slippage
        uint256 strictMinAmountOut = 999e6; // 99.9% - very strict

        FuseAction[] memory enterCalls = _createSwapAction(USDC, USDT, depositAmount, strictMinAmountOut);

        // when/then - should revert due to minAmountOut even though USD slippage would pass
        vm.expectRevert();
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    // ==================== Helper Functions ====================

    function _setupVault() private {
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        _withdrawManager = address(new WithdrawManager(address(_accessManager)));

        // plasma vault
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                _withdrawManager
            )
        );
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigsWithSlippage()
        );
        _setupRoles();
    }

    function _setupVaultWithoutSlippageSubstrate() private {
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        _withdrawManager = address(new WithdrawManager(address(_accessManager)));

        // plasma vault
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                _withdrawManager
            )
        );
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigsWithoutSlippage()
        );
        _setupRoles();
    }

    function _depositToVault(address user, uint256 amount) private {
        vm.prank(USDC_WHALE);
        ERC20(USDC).transfer(user, amount);

        vm.prank(user);
        ERC20(USDC).approve(_plasmaVault, amount);
        vm.prank(user);
        PlasmaVault(_plasmaVault).deposit(amount, user);
    }

    function _createSwapAction(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) private view returns (FuseAction[] memory) {
        bytes memory path = abi.encodePacked(tokenIn, uint24(3000), tokenOut);

        address[] memory targets = new address[](2);
        targets[0] = tokenIn;
        targets[1] = _UNIVERSAL_ROUTER;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(_INDICATOR_OF_SENDER_FROM_UNIVERSAL_ROUTER, amountIn, 0, path, false);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", _UNIVERSAL_ROUTER, amountIn);
        data[1] = abi.encodeWithSignature(
            "execute(bytes,bytes[])",
            abi.encodePacked(bytes1(uint8(_V3_SWAP_EXACT_IN))),
            inputs
        );

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,(address[],bytes[])))", enterData)
        );

        return enterCalls;
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        _accessManager = accessManager_;
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            _plasmaVault,
            IporFusionAccessManager(_accessManager),
            _withdrawManager
        );
    }

    function _setupMarketConfigsWithSlippage() private view returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory universalSwapSubstrates = new bytes32[](6);
        // Token substrates
        universalSwapSubstrates[0] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDC);
        universalSwapSubstrates[1] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDT);
        universalSwapSubstrates[2] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(DAI);
        // Target substrates
        universalSwapSubstrates[3] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(_UNIVERSAL_ROUTER);
        universalSwapSubstrates[4] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(USDC);
        // Slippage substrate - use configured value
        universalSwapSubstrates[5] = UniversalTokenSwapperSubstrateLib.encodeSlippageSubstrate(_configuredSlippage);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, universalSwapSubstrates);
    }

    function _setupMarketConfigsWithoutSlippage() private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        // No slippage substrate - fuse should use DEFAULT_SLIPPAGE_WAD (1%)
        bytes32[] memory universalSwapSubstrates = new bytes32[](5);
        // Token substrates
        universalSwapSubstrates[0] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDC);
        universalSwapSubstrates[1] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(USDT);
        universalSwapSubstrates[2] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(DAI);
        // Target substrates
        universalSwapSubstrates[3] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(_UNIVERSAL_ROUTER);
        universalSwapSubstrates[4] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(USDC);
        // NO slippage substrate

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, universalSwapSubstrates);
    }

    function _setupFuses() private returns (address[] memory fuses_) {
        _universalTokenSwapperFuse = new UniversalTokenSwapperFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);

        fuses_ = new address[](1);
        fuses_[0] = address(_universalTokenSwapperFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
    }
}
