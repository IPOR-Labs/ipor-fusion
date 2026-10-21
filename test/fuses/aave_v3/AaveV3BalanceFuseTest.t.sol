// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

interface IAddressesProviderAcl {
    function getACLManager() external view returns (address);
    function getACLAdmin() external view returns (address);
    function getPriceOracle() external view returns (address);
}

interface IAclManager {
    function addPoolAdmin(address admin) external;
}

interface IAaveOracleAdmin {
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;
    function setFallbackOracle(address fallbackOracle) external;
    function getFallbackOracle() external view returns (address);
}

/// @dev Chainlink-like source that always reports a dead (zero) price
contract ZeroPriceSource {
    function latestAnswer() external pure returns (int256) {
        return 0;
    }
}

//https://mirror.xyz/unfrigginbelievable.eth/fzvIBwJZQKOP4sNpkrVZGOJEk5cDr6tarimQHTw6C84
contract AaveV3BalanceFuseTest is Test {
    struct SupportedToken {
        address token;
        string name;
    }

    using SafeERC20 for ERC20;

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    /// @dev USDT address - deal() doesn't work with USDT due to proxy storage layout
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @dev Binance wallet - USDT whale
    address private constant USDT_WHALE = 0xF977814e90dA44bFA03b6295A0616a897441aceC;

    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    SupportedToken private activeTokens;

    function testShouldCalculateBalanceWhenSupply() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19508857);

        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(1, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(0x0), address(aaveV3Balances));

        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;

        vaultMock.updateMarketConfiguration(1, assets);

        uint256 balanceBefore = vaultMock.balanceOf();

        // when
        vm.prank(address(vaultMock));
        ERC20(activeTokens.token).forceApprove(address(AAVE_POOL), amount);

        vm.prank(address(vaultMock));
        AAVE_POOL.supply(activeTokens.token, amount, address(vaultMock), 0);

        uint256 balanceAfter = vaultMock.balanceOf();

        // then
        assertTrue(balanceAfter > balanceBefore, "Balance should be greater after supply");
        assertEq(balanceBefore, 0, "Balance before should be 0");
    }

    function testShouldDecreaseBalanceWhenBorrowVariable() external iterateSupportedTokens {
        // given
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19508857);
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(1, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(0x0), address(aaveV3Balances));

        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;
        uint256 borrowAmount = 20 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;
        vaultMock.updateMarketConfiguration(1, assets);

        vm.prank(address(vaultMock));
        ERC20(activeTokens.token).forceApprove(address(AAVE_POOL), amount);
        vm.prank(address(vaultMock));
        AAVE_POOL.supply(activeTokens.token, amount, address(vaultMock), 0);

        uint256 balanceBefore = vaultMock.balanceOf();

        // when
        vm.prank(address(vaultMock));
        AAVE_POOL.borrow(activeTokens.token, borrowAmount, uint256(2), 0, address(vaultMock));

        uint256 balanceAfter = vaultMock.balanceOf();

        // then
        assertTrue(balanceAfter < balanceBefore, "Balance should be greater after supply");
    }

    function testShouldIgnoreAssetWithoutPriceWhenNoPositionInIt() external {
        // given
        (AaveV3BalanceFuse fuse, PlasmaVaultMock vaultMock) = _setUpTwoSubstrates();
        _supplyToAave(address(vaultMock), _WETH, 10 ether);
        uint256 expected = vaultMock.balanceOf();
        assertGt(expected, 0, "position in WETH is priced");

        // when
        vm.mockCall(
            address(AAVE_PRICE_ORACLE),
            abi.encodeWithSelector(IAavePriceOracle.getAssetPrice.selector, _DAI),
            abi.encode(uint256(0))
        );

        // then
        assertEq(vaultMock.balanceOf(), expected, "DAI without price and without position must not matter");
        assertEq(fuse.MARKET_ID(), 1);
    }

    function testShouldIgnoreAssetWhoseAaveOraclePriceReverts() external {
        // given
        (, PlasmaVaultMock vaultMock) = _setUpTwoSubstrates();
        _supplyToAave(address(vaultMock), _WETH, 10 ether);
        uint256 expected = vaultMock.balanceOf();

        // when: Aave governance leaves DAI with a dead source and no fallback oracle
        address acl = IAddressesProviderAcl(ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER).getACLManager();
        address aclAdmin = IAddressesProviderAcl(ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER).getACLAdmin();
        vm.prank(aclAdmin);
        IAclManager(acl).addPoolAdmin(address(this));

        address[] memory assets = new address[](1);
        assets[0] = _DAI;
        address[] memory sources = new address[](1);
        sources[0] = address(new ZeroPriceSource());
        IAaveOracleAdmin(address(AAVE_PRICE_ORACLE)).setAssetSources(assets, sources);
        IAaveOracleAdmin(address(AAVE_PRICE_ORACLE)).setFallbackOracle(address(0));

        // then: the real oracle really cannot price DAI ...
        vm.expectRevert();
        AAVE_PRICE_ORACLE.getAssetPrice(_DAI);
        // ... yet the market balance is still computed
        assertEq(vaultMock.balanceOf(), expected, "balanceOf must not depend on the DAI price");
    }

    function testShouldRevertWhenPositionInAssetWithZeroPrice() external {
        // given
        (, PlasmaVaultMock vaultMock) = _setUpTwoSubstrates();
        _supplyToAave(address(vaultMock), _WETH, 10 ether);
        _supplyToAave(address(vaultMock), _DAI, 1e9); // dust position in DAI

        vm.mockCall(
            address(AAVE_PRICE_ORACLE),
            abi.encodeWithSelector(IAavePriceOracle.getAssetPrice.selector, _DAI),
            abi.encode(uint256(0))
        );

        // when / then
        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);
        vaultMock.balanceOf();
    }

    function _setUpTwoSubstrates() private returns (AaveV3BalanceFuse fuse, PlasmaVaultMock vaultMock) {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19508857);
        fuse = new AaveV3BalanceFuse(1, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        vaultMock = new PlasmaVaultMock(address(0x0), address(fuse));

        address[] memory assets = new address[](2);
        assets[0] = _WETH;
        assets[1] = _DAI;
        vaultMock.updateMarketConfiguration(1, assets);
    }

    function _supplyToAave(address vault, address asset, uint256 amount) private {
        deal(asset, vault, amount);
        vm.startPrank(vault);
        ERC20(asset).forceApprove(address(AAVE_POOL), amount);
        AAVE_POOL.supply(asset, amount, vault, 0);
        vm.stopPrank();
    }

    function _getSupportedAssets() private returns (SupportedToken[] memory supportedTokensTemp) {
        // Note: USDT removed due to non-standard storage layout causing stdStorage issues
        supportedTokensTemp = new SupportedToken[](7);

        supportedTokensTemp[0] = SupportedToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "WETH");
        supportedTokensTemp[1] = SupportedToken(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "WSTETH");
        supportedTokensTemp[2] = SupportedToken(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, "WBTC");
        supportedTokensTemp[3] = SupportedToken(0x6B175474E89094C44Da98b954EedeAC495271d0F, "DAI");
        supportedTokensTemp[4] = SupportedToken(0x514910771AF9Ca656af840dff83E8264EcF986CA, "LINK");
        supportedTokensTemp[5] = SupportedToken(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704, "cbETH");
        supportedTokensTemp[6] = SupportedToken(0xae78736Cd615f374D3085123A210448E74Fc6393, "rETH");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == USDT) {
            // Note: deal() doesn't work with USDT due to proxy storage layout, use whale transfer instead
            vm.prank(USDT_WHALE);
            ERC20(asset).safeTransfer(to, amount);
        } else {
            deal(asset, to, amount);
        }
    }

    modifier iterateSupportedTokens() {
        SupportedToken[] memory supportedTokens = _getSupportedAssets();
        for (uint256 i; i < supportedTokens.length; ++i) {
            activeTokens = supportedTokens[i];
            _;
        }
    }
}
