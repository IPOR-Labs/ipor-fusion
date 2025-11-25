// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {AaveV3CollateralFuse} from "../../../contracts/fuses/aave_v3/AaveV3CollateralFuse.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {PlasmaVault, FuseAction, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";

contract AaveV3BorrowAgainstIsolatedCollateralEthereum is BorrowTest {
    address private constant XAUt = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant CHAINLINK_XAU = 0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6;
    address private constant CHAINLINK_USDC = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant variableDebtEthUSDC = 0x72E95b8931767C79bA4EeE721354d6E99a61D004;
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    uint256 internal depositAmount = 5e6;
    uint256 internal borrowAmount = 10e6;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23689066);
        setupBorrowAsset();
        init();
    }

    function setupAsset() public override {
        asset = XAUt;
    }

    function setupBorrowAsset() public override {
        borrowAsset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x785f041A4DAe0C1E5eDcBB081F1a2BB9684eFF76);
        ERC20(asset).transfer(account_, 10e6);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;

        assets[1] = XAUt;
        sources[1] = CHAINLINK_XAU;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(XAUt);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);
    }

    function setupMarketConfigsWithErc20Balance() public returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(XAUt);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), assets);

        bytes32[] memory assets2 = new bytes32[](1);
        assets2[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, assets2);
    }

    function setupFuses() public override {
        AaveV3SupplyFuse fuseSupplyLoc = new AaveV3SupplyFuse(getMarketId(), ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        AaveV3BorrowFuse fuseBorrowLoc = new AaveV3BorrowFuse(getMarketId(), ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER);
        AaveV3CollateralFuse fuseCollateral = new AaveV3CollateralFuse(
            getMarketId(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );
        fuses = new address[](3);
        fuses[0] = address(fuseSupplyLoc);
        fuses[1] = address(fuseBorrowLoc);
        fuses[2] = address(fuseCollateral);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(
            getMarketId(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(aaveV3Balances));
    }

    function setupBalanceFusesWithErc20Balance() public returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        AaveV3BalanceFuse aaveV3Balances = new AaveV3BalanceFuse(
            getMarketId(),
            ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        ERC20BalanceFuse erc20Balances = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(aaveV3Balances));

        balanceFuses[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balances));
    }

    function setupDependencyBalanceGraphsWithErc20BalanceFuse() public {
        uint256[] memory marketIds = new uint256[](1);

        marketIds[0] = IporFusionMarkets.AAVE_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = dependence;

        vm.prank(accounts[0]);
        PlasmaVaultGovernance(plasmaVault).updateDependencyBalanceGraphs(marketIds, dependencies);
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: amount_,
            userEModeCategoryId: 300
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: amount_
        });

        data = new bytes[](2);

        data[0] = abi.encode(enterSupplyData);
        data[1] = abi.encode(enterBorrowData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        fusesSetup = new address[](0);
        data = new bytes[](0);
    }

    function testShouldNotBorrowAgainstIsolatedCollateralWhenNotEnabled() public {
        //given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](2);

        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 0
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: borrowAmount
        });

        address supplyFuse = fuses[0];
        address borrowFuse = fuses[1];

        calls[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));
        calls[1] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        bytes memory error = abi.encodeWithSignature("LtvValidationFailed()");
        vm.expectRevert(error);

        //when
        vm.startPrank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    function testShouldBorrowAgainstIsolatedCollateralWhenEnabled() public {
        //given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](3);

        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 0
        });

        AaveV3BorrowFuseEnterData memory enterBorrowData = AaveV3BorrowFuseEnterData({
            asset: borrowAsset,
            amount: borrowAmount
        });

        address supplyFuse = fuses[0];
        address borrowFuse = fuses[1];
        address collateralFuse = fuses[2];

        calls[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData));
        calls[1] = FuseAction(collateralFuse, abi.encodeWithSignature("enter(address)", XAUt));
        calls[2] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((address,uint256))", enterBorrowData));

        //when
        vm.startPrank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        uint256 borrowBalance = ERC20(variableDebtEthUSDC).balanceOf(plasmaVault);
        assertGe(borrowBalance, 10e6, "usdc debt");
    }

    /// @notice Test that constructor reverts when initialized with zero address
    function testShouldRevertWhenInitializingWithZeroAddress() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new AaveV3CollateralFuse(getMarketId(), address(0));
    }

    /// @notice Test that enter function reverts when asset is not supported
    function testShouldRevertWhenEnteringWithUnsupportedAsset() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        address unsupportedAsset = address(0x123);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter(address)", unsupportedAsset));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3CollateralFuse.AaveV3CollateralFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        PlasmaVault(plasmaVault).execute(calls);
    }

    /// @notice Test that exit function successfully disables isolated collateral
    function testShouldExitCollateralFuse() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory calls = new FuseAction[](2);

        // Enable collateral
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("enter(address)", XAUt));
        // Disable collateral
        calls[1] = FuseAction(fuses[2], abi.encodeWithSignature("exit(address)", XAUt));

        // Add supply to avoid UnderlyingBalanceZero error which checks for non-zero assets in market
        FuseAction[] memory supplyCalls = new FuseAction[](1);
        AaveV3SupplyFuseEnterData memory enterSupplyData = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: depositAmount,
            userEModeCategoryId: 0
        });
        supplyCalls[0] = FuseAction(
            fuses[0],
            abi.encodeWithSignature("enter((address,uint256,uint256))", enterSupplyData)
        );
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyCalls);

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then
        // No state to check directly on fuse, but execution without revert confirms logic
    }

    /// @notice Test that exit function reverts when asset is not supported
    function testShouldRevertWhenExitingWithUnsupportedAsset() public {
        // given
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        address unsupportedAsset = address(0x123);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[2], abi.encodeWithSignature("exit(address)", unsupportedAsset));

        // when
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV3CollateralFuse.AaveV3CollateralFuseUnsupportedAsset.selector,
                "enter",
                unsupportedAsset
            )
        );
        PlasmaVault(plasmaVault).execute(calls);
    }
}
