// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPool} from "../../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract AaveV3SupplyFuseArbitrumTest is Test {
    using Address for address;

    struct SupportedToken {
        address asset;
        string name;
    }

    IPool public constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7F23D86Ee20D869112572136221e173428DD740B);
    address public constant ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    SupportedToken private activeTokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 267197808);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when

        vaultMock.enterAaveV3Supply(
            AaveV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount, userEModeCategoryId: uint256(300)})
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.asset);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)) >= amount,
            "aToken balance should be increased by amount"
        );
        assertEq(stableDebtTokenAddress, address(0), "stableDebtTokenAddress");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        uint256 dustOnAToken = 10;
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterAaveV3Supply(
            AaveV3SupplyFuseEnterData({
                asset: activeTokens.asset,
                amount: enterAmount,
                userEModeCategoryId: uint256(300)
            })
        );

        // when

        vaultMock.exitAaveV3Supply(AaveV3SupplyFuseExitData({asset: activeTokens.asset, amount: exitAmount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.asset);

        assertEq(balanceAfter + enterAmount - exitAmount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)) >= enterAmount - exitAmount - dustOnAToken,
            "aToken balance should be decreased by amount"
        );
        assertEq(stableDebtTokenAddress, address(0), "stableDebtTokenAddress");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    function _getSupportedAssets() private pure returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](1);

        supportedTokensTemp[0] = SupportedToken(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, "USDC");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831) {
            // USDC
            vm.prank(0x05e3a758FdD29d28435019ac453297eA37b61b62); // holder
            ERC20(asset).transfer(to, amount);
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

    /// @notice Test that enterTransient function successfully supplies assets using transient storage
    function testShouldEnterSupplyUsingTransientStorage() external iterateSupportedTokens {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;
        uint256 userEModeCategoryId = 300;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        // Grant assets to market for fuse using vaultMock
        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // Set transient storage inputs for fuse (VERSION points to fuse)
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(amount);
        inputs[2] = TypeConversionLib.toBytes32(userEModeCategoryId);
        vaultMock.setInputs(address(fuse), inputs);

        // when - call through vaultMock so that address(this) in fuse points to vaultMock
        vaultMock.enterAaveV3SupplyTransient();

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.asset);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)) >= amount,
            "aToken balance should be increased by amount"
        );
        assertEq(stableDebtTokenAddress, address(0), "stableDebtTokenAddress");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    /// @notice Test that exitTransient function successfully withdraws assets using transient storage
    function testShouldExitSupplyUsingTransientStorage() external iterateSupportedTokens {
        // given
        uint256 dustOnAToken = 10;
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterAaveV3Supply(
            AaveV3SupplyFuseEnterData({
                asset: activeTokens.asset,
                amount: enterAmount,
                userEModeCategoryId: uint256(300)
            })
        );

        // Set transient storage inputs for fuse (VERSION is immutable and points to fuse)
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(exitAmount);
        vaultMock.setInputs(address(fuse), inputs);

        // when - call through vaultMock so that address(this) in fuse points to vaultMock
        vaultMock.exitAaveV3SupplyTransient();

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(vaultMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.asset);

        assertEq(balanceAfter + enterAmount - exitAmount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)) >= enterAmount - exitAmount - dustOnAToken,
            "aToken balance should be decreased by amount"
        );
        assertEq(stableDebtTokenAddress, address(0), "stableDebtTokenAddress");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    /// @notice Test that enterTransient function returns early when amount is zero
    function testShouldReturnWhenEnteringTransientWithZeroAmount() external iterateSupportedTokens {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 0;
        uint256 userEModeCategoryId = 300;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // Set transient storage inputs for fuse (VERSION points to fuse)
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(amount);
        inputs[2] = TypeConversionLib.toBytes32(userEModeCategoryId);
        vaultMock.setInputs(address(fuse), inputs);

        // when - call through vaultMock so that address(this) in fuse points to vaultMock
        vaultMock.enterAaveV3SupplyTransient();

        // then
        // Execution without revert confirms that function returned early
    }

    /// @notice Test that enterTransient function reverts when asset is not supported
    function testShouldRevertWhenEnteringTransientWithUnsupportedAsset() external {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));
        address unsupportedAsset = address(0x123);
        uint256 amount = 100 * 10 ** 18;
        uint256 userEModeCategoryId = 300;

        // Set transient storage inputs for vaultMock (VERSION points to vaultMock in delegatecall context)
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
        inputs[1] = TypeConversionLib.toBytes32(amount);
        inputs[2] = TypeConversionLib.toBytes32(userEModeCategoryId);
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3SupplyFuse.AaveV3SupplyFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        vaultMock.enterAaveV3SupplyTransient();
    }

    /// @notice Test that exitTransient function returns early when amount is zero
    function testShouldReturnWhenExitingTransientWithZeroAmount() external iterateSupportedTokens {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 0;

        _supplyTokensToMockVault(activeTokens.asset, address(vaultMock), 1_000 * 10 ** decimals);

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        vaultMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        vaultMock.enterAaveV3Supply(
            AaveV3SupplyFuseEnterData({
                asset: activeTokens.asset,
                amount: enterAmount,
                userEModeCategoryId: uint256(300)
            })
        );

        // Set transient storage inputs for fuse (VERSION is immutable and points to fuse)
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(activeTokens.asset);
        inputs[1] = TypeConversionLib.toBytes32(exitAmount);
        vaultMock.setInputs(address(fuse), inputs);

        // when - call through vaultMock so that address(this) in fuse points to vaultMock
        vaultMock.exitAaveV3SupplyTransient();

        // then
        // Execution without revert confirms that function returned early
    }

    /// @notice Test that exitTransient function reverts when asset is not supported
    function testShouldRevertWhenExitingTransientWithUnsupportedAsset() external {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0x0));
        address unsupportedAsset = address(0x123);
        uint256 amount = 100 * 10 ** 18;

        // Set transient storage inputs for vaultMock (VERSION points to vaultMock in delegatecall context)
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
        inputs[1] = TypeConversionLib.toBytes32(amount);
        vaultMock.setInputs(address(fuse), inputs);

        // when
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3SupplyFuse.AaveV3SupplyFuseUnsupportedAsset.selector, "exit", unsupportedAsset)
        );
        vaultMock.exitAaveV3SupplyTransient();
    }
}
