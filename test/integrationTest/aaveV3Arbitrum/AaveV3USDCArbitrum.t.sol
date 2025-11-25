// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";

contract AaveV3USDCArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    uint256 public constant MARKET_ID = 1;
    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public constant AAVE_PRICE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        init();
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x47c031236e19d024b42f8AE6780E44A573170703);
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[0] = MarketSubstratesConfig(MARKET_ID, assets);
    }

    function setupFuses() public override {
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(MARKET_ID, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(MARKET_ID, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(aaveV3Balances));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        AaveV3SupplyFuseEnterData memory enterData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: amount_,
            userEModeCategoryId: 300
        });
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("enter((address,uint256,uint256))", enterData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        AaveV3SupplyFuseExitData memory exitData = AaveV3SupplyFuseExitData({asset: asset, amount: amount_});
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("exit((address,uint256))", exitData);
        fusesSetup = fuses;
    }

    /// @notice Test that constructor reverts when initialized with zero market ID
    function testShouldRevertWhenInitializingWithZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new AaveV3SupplyFuse(0, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
    }

    /// @notice Test that constructor reverts when initialized with zero address
    function testShouldRevertWhenInitializingWithZeroAddress() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new AaveV3SupplyFuse(MARKET_ID, address(0));
    }

    /// @notice Test that enter function reverts when asset is not supported
    function testShouldRevertWhenEnteringWithUnsupportedAsset() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(1000e6, accounts[1]);

        address unsupportedAsset = address(0x123);
        AaveV3SupplyFuseEnterData memory enterData = AaveV3SupplyFuseEnterData({
            asset: unsupportedAsset,
            amount: 100e6,
            userEModeCategoryId: 300
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256,uint256))", enterData));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3SupplyFuse.AaveV3SupplyFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test that exit function reverts when asset is not supported
    function testShouldRevertWhenExitingWithUnsupportedAsset() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(1000e6, accounts[1]);

        address unsupportedAsset = address(0x123);
        AaveV3SupplyFuseExitData memory exitData = AaveV3SupplyFuseExitData({asset: unsupportedAsset, amount: 100e6});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("exit((address,uint256))", exitData));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3SupplyFuse.AaveV3SupplyFuseUnsupportedAsset.selector, "exit", unsupportedAsset)
        );
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test that exit function returns early (no-op) when amount is zero
    function testShouldReturnWhenExitingWithZeroAmount() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(1000e6, accounts[1]);

        AaveV3SupplyFuseExitData memory exitData = AaveV3SupplyFuseExitData({asset: asset, amount: 0});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("exit((address,uint256))", exitData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }

    /// @notice Test that exit function returns early (no-op) when balance is zero
    function testShouldReturnWhenExitingWithZeroBalance() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(1000e6, accounts[1]);

        // Try to exit more than what's available (which will result in zero finalAmount)
        AaveV3SupplyFuseExitData memory exitData = AaveV3SupplyFuseExitData({asset: asset, amount: type(uint256).max});

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("exit((address,uint256))", exitData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }

    /// @notice Test that instantWithdraw works correctly with valid parameters
    /// @dev The catch block in _performWithdraw is hard to test in integration tests as it requires
    ///      the actual Aave pool withdraw to fail, which is rare. This test ensures instantWithdraw works correctly.
    function testShouldHandleInstantWithdrawFailure() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(1000e6, accounts[1]);

        // Supply first to have something to withdraw
        AaveV3SupplyFuseEnterData memory enterData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: 500e6,
            userEModeCategoryId: 300
        });

        FuseAction[] memory supplyCalls = new FuseAction[](1);
        supplyCalls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256,uint256))", enterData));
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyCalls);

        // Now test instantWithdraw with valid asset
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(100e6));
        params[1] = PlasmaVaultConfigLib.addressToBytes32(asset);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("instantWithdraw(bytes32[])", params));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
    }
}
