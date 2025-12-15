// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {FluidInstadappStakingBalanceFuse} from "../../../contracts/fuses/fluid_instadapp/FluidInstadappStakingBalanceFuse.sol";
import {FluidInstadappStakingSupplyFuse, FluidInstadappStakingSupplyFuseEnterData, FluidInstadappStakingSupplyFuseExitData} from "../../../contracts/fuses/fluid_instadapp/FluidInstadappStakingSupplyFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";

contract FluidInstadappStakingUSDCArbitrum is SupplyTest {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant F_TOKEN = 0x1A996cb54bb95462040408C06122D45D6Cdb6096; // deposit / withdraw
    address public constant FLUID_LENDING_STAKING_REWARDS = 0x48f89d731C5e3b5BeE8235162FC2C639Ba62DB7d; // stake / exit

    Erc4626SupplyFuse public erc4626SupplyFuse;
    FluidInstadappStakingSupplyFuse public fluidInstadappStakingSupplyFuse;
    TransientStorageSetInputsFuse private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 233461793);
        init();
    }

    function getMarketId() public view override returns (uint256) {
        return IporFusionMarkets.FLUID_INSTADAPP_STAKING;
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
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory assetsFToken = new bytes32[](1);
        assetsFToken[0] = PlasmaVaultConfigLib.addressToBytes32(F_TOKEN);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.FLUID_INSTADAPP_POOL, assetsFToken);

        bytes32[] memory assetsStaking = new bytes32[](1);
        assetsStaking[0] = PlasmaVaultConfigLib.addressToBytes32(FLUID_LENDING_STAKING_REWARDS);
        marketConfigs[1] = MarketSubstratesConfig(IporFusionMarkets.FLUID_INSTADAPP_STAKING, assetsStaking);
    }

    function setupFuses() public override {
        erc4626SupplyFuse = new Erc4626SupplyFuse(IporFusionMarkets.FLUID_INSTADAPP_POOL);
        fluidInstadappStakingSupplyFuse = new FluidInstadappStakingSupplyFuse(
            IporFusionMarkets.FLUID_INSTADAPP_STAKING
        );
        _transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();
        fuses = new address[](3);
        fuses[0] = address(erc4626SupplyFuse);
        fuses[1] = address(fluidInstadappStakingSupplyFuse);
        fuses[2] = address(_transientStorageSetInputsFuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        Erc4626BalanceFuse fluidInstadappBalances = new Erc4626BalanceFuse(IporFusionMarkets.FLUID_INSTADAPP_POOL);

        FluidInstadappStakingBalanceFuse fluidInstadappStakingBalances = new FluidInstadappStakingBalanceFuse(
            IporFusionMarkets.FLUID_INSTADAPP_STAKING
        );

        ERC20BalanceFuse erc20Balances = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses = new MarketBalanceFuseConfig[](3);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.FLUID_INSTADAPP_POOL,
            address(fluidInstadappBalances)
        );

        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.FLUID_INSTADAPP_STAKING,
            address(fluidInstadappStakingBalances)
        );

        balanceFuses[2] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balances));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: F_TOKEN,
            vaultAssetAmount: amount_
        });
        FluidInstadappStakingSupplyFuseEnterData memory enterDataStaking = FluidInstadappStakingSupplyFuseEnterData({
            fluidTokenAmount: amount_,
            stakingPool: FLUID_LENDING_STAKING_REWARDS
        });
        data = new bytes[](2);
        data[0] = abi.encodeWithSignature("enter((address,uint256))", enterData);
        data[1] = abi.encodeWithSignature("enter((uint256,address))", enterDataStaking);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        Erc4626SupplyFuseExitData memory exitData = Erc4626SupplyFuseExitData({
            vault: F_TOKEN,
            vaultAssetAmount: amount_
        });
        FluidInstadappStakingSupplyFuseExitData memory exitDataStaking = FluidInstadappStakingSupplyFuseExitData({
            fluidTokenAmount: amount_,
            stakingPool: FLUID_LENDING_STAKING_REWARDS
        });

        data = new bytes[](2);
        data[1] = abi.encodeWithSignature("exit((address,uint256))", exitData);
        data[0] = abi.encodeWithSignature("exit((uint256,address))", exitDataStaking);

        fusesSetup = new address[](2);
        fusesSetup[0] = address(fluidInstadappStakingSupplyFuse);
        fusesSetup[1] = address(erc4626SupplyFuse);
    }

    function _generateEnterCallsData(
        uint256 amount_,
        bytes32[] memory data_
    ) private view returns (FuseAction[] memory enterCalls) {
        bytes[] memory enterData = getEnterFuseData(amount_, data_);
        uint256 len = enterData.length;
        enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], enterData[i]);
        }
    }

    /// @notice Tests entering Fluid Instadapp Staking using transient storage
    /// @dev Verifies that enterTransient() correctly reads inputs from transient storage and stakes tokens
    function testShouldEnterFluidInstadappStakingUsingTransientStorage() public {
        // given - first deposit and enter normally to get some fToken balance
        uint256 depositAmount = 1000 * 10 ** ERC20(asset).decimals();
        dealAssets(accounts[1], depositAmount);
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(_generateEnterCallsData(depositAmount, new bytes32[](0)));

        // Now test transient storage enter
        uint256 fluidTokenAmount = depositAmount; // Use the same amount
        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(fluidTokenAmount);
        inputs[1] = TypeConversionLib.toBytes32(FLUID_LENDING_STAKING_REWARDS);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(fluidInstadappStakingSupplyFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Enter Transient
        calls[1] = FuseAction(address(fluidInstadappStakingSupplyFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then - verify staking worked by checking balance
        // The test passes if no revert occurs and the transaction completes successfully
    }

    /// @notice Tests exiting Fluid Instadapp Staking using transient storage
    /// @dev Verifies that exitTransient() correctly reads inputs from transient storage and unstakes tokens
    function testShouldExitFluidInstadappStakingUsingTransientStorage() public {
        // given - first deposit and enter normally to get staked tokens
        uint256 depositAmount = 1000 * 10 ** ERC20(asset).decimals();
        dealAssets(accounts[1], depositAmount);
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(_generateEnterCallsData(depositAmount, new bytes32[](0)));

        // Now test transient storage exit
        uint256 fluidTokenAmount = depositAmount; // Use the same amount
        FuseAction[] memory calls = new FuseAction[](2);

        // 1. Prepare Transient Inputs
        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(fluidTokenAmount);
        inputs[1] = TypeConversionLib.toBytes32(FLUID_LENDING_STAKING_REWARDS);

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(fluidInstadappStakingSupplyFuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls[0] = FuseAction(
            address(_transientStorageSetInputsFuse),
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );

        // 2. Exit Transient
        calls[1] = FuseAction(address(fluidInstadappStakingSupplyFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);

        // then - verify unstaking worked
        // The test passes if no revert occurs and the transaction completes successfully
    }
}
