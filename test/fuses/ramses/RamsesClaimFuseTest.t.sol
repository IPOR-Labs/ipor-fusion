// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, FeeConfig, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RamsesV2Balance} from "../../../contracts/fuses/ramses/RamsesV2Balance.sol";
import {RamsesV2NewPositionFuse, RamsesV2NewPositionFuseEnterData} from "../../../contracts/fuses/ramses/RamsesV2NewPositionFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {RamsesClaimFuse} from "../../../contracts/rewards_fuses/ramses/RamsesClaimFuse.sol";
import {IporFusionAccessManagerInitializerLibV1, PlasmaVaultAddress, InitializationData} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {DataForInitialization} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";

interface IGAUGE {
    function rewards(uint256 index) external view returns (address);
    /// @notice Returns the amount of rewards earned for an NFP.
    /// @param token The address of the token for which to retrieve the earned rewards.
    /// @param tokenId The identifier of the specific NFP for which to retrieve the earned rewards.
    /// @return reward The amount of rewards earned for the specified NFP and tokens.
    function earned(address token, uint256 tokenId) external view returns (uint256 reward);

    /// @notice Returns an array of reward token addresses.
    /// @return An array of reward token addresses.
    function getRewardTokens() external view returns (address[] memory);
}

contract RamsesClaimFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address private constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    address private constant _NONFUNGIBLE_POSITION_MANAGER = 0xAA277CB7914b7e5514946Da92cb9De332Ce610EF;
    address private constant _RAMSES_FACTORY = 0xAA2cd7477c451E703f3B9Ba5663334914763edF8;

    address private constant GAUGE = 0xfaD965bD9e64A211cC38AE9E8F5317cd91155e91;

    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = -MIN_TICK;
    int24 private constant TICK_SPACING = 60;

    address private _userOne;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _claimRewardsManager;
    address private _claimFuse;
    RamsesV2NewPositionFuse private _ramsesV2NewPositionFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 254261635);
        _userOne = address(0x1222);

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;

        address[] memory assetsDai = new address[](1);
        assetsDai[0] = DAI;
        address[] memory sourcesDai = new address[](1);
        sourcesDai[0] = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;

        vm.prank(PriceOracleMiddleware(_priceOracle).owner());
        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assetsDai, sourcesDai);

        // plasma vault
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "pvUSDC",
                    USDC,
                    _priceOracle,
                    _setupMarketConfigs(),
                    _setupFuses(),
                    _setupBalanceFuses(),
                    _setupFeeConfig(),
                    _createAccessManager(),
                    address(new PlasmaVaultBase()),
                    type(uint256).max,
                    address(0)
                )
            )
        );
        _createClaimRewardsManager();
        _setupPlasmaVault();
        _createClaimFuse();
        _addClaimFuseToClaimRewardsManager();
        _initAccessManager();
        _setupDependenceBalance();

        vm.prank(0xC6962004f452bE9203591991D15f6b388e09E8D0);
        ERC20(USDC).transfer(_userOne, 100_000e6);

        vm.prank(_userOne);
        ERC20(USDC).approve(_plasmaVault, 100_000e6);

        vm.prank(_userOne);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _userOne);

        deal(USDT, _userOne, 100_000e6);

        vm.prank(_userOne);
        ERC20(USDT).transfer(_plasmaVault, 10_000e6);
    }

    function testShouldClaimRewards() external {
        // given
        address rem = 0xAAA6C1E32C55A7Bfa8066A6FAE9b42650F262418;
        address xRem = 0xAAA1eE8DC1864AE49185C368e8c64Dd780a50Fb7;

        RamsesV2NewPositionFuseEnterData memory mintParams = RamsesV2NewPositionFuseEnterData({
            token0: USDC,
            token1: USDT,
            fee: 50,
            tickLower: -1,
            tickUpper: 1,
            amount0Desired: 1_000e6,
            amount1Desired: 1_000e6,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            veRamTokenId: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_ramsesV2NewPositionFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
                mintParams
            )
        );

        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(enterCalls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _extractMarketIdsFromEvent(entries);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        address[][] memory tokenRewards = new address[][](1);
        tokenRewards[0] = new address[](2);
        tokenRewards[0][0] = rem;
        tokenRewards[0][1] = xRem;

        FuseAction[] memory claimCalls = new FuseAction[](1);
        claimCalls[0] = FuseAction(
            address(_claimFuse),
            abi.encodeWithSignature("claim(uint256[],address[][])", tokenIds, tokenRewards)
        );

        uint256 remBalanceBefore = ERC20(rem).balanceOf(_claimRewardsManager);
        uint256 xRemBalanceBefore = ERC20(xRem).balanceOf(_claimRewardsManager);

        vm.warp(block.timestamp + 30 days);

        // when
        RewardsClaimManager(_claimRewardsManager).claimRewards(claimCalls);

        // then

        uint256 remBalanceAfter = ERC20(rem).balanceOf(_claimRewardsManager);
        uint256 xRemBalanceAfter = ERC20(xRem).balanceOf(_claimRewardsManager);

        assertEq(remBalanceBefore, 0, "remBalanceBefore");
        assertEq(xRemBalanceBefore, 0, "xRemBalanceBefore");

        assertGt(remBalanceAfter, 0, "remBalanceAfter > 0");
        assertEq(xRemBalanceAfter, 0, "xRemBalanceAfter");
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0));
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
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, _plasmaVault, IporFusionAccessManager(_accessManager));
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](2);

        bytes32[] memory ramsesTokens = new bytes32[](3);
        ramsesTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        ramsesTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        ramsesTokens[2] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.RAMSES_V2_POSITIONS, ramsesTokens);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, ramsesTokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _ramsesV2NewPositionFuse = new RamsesV2NewPositionFuse(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER
        );

        fuses = new address[](1);
        fuses[0] = address(_ramsesV2NewPositionFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        RamsesV2Balance ramsesBalance = new RamsesV2Balance(
            IporFusionMarkets.RAMSES_V2_POSITIONS,
            _NONFUNGIBLE_POSITION_MANAGER,
            _RAMSES_FACTORY
        );
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.RAMSES_V2_POSITIONS, address(ramsesBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.RAMSES_V2_POSITIONS;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    function _extractMarketIdsFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].topics[0] ==
                keccak256(
                    "RamsesV2NewPositionFuseEnter(address,uint256,uint128,uint256,uint256,address,address,uint24,int24,int24)"
                )
            ) {
                (version, tokenId, liquidity, amount0, amount1, , , , , ) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint128, uint256, uint256, address, address, uint24, int24, int24)
                );
                break;
            }
        }
    }

    function _extractIncreaseLiquidityFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].topics[0] ==
                keccak256("RamsesV2ModifyPositionFuseEnter(address,uint256,uint128,uint256,uint256)")
            ) {
                (version, tokenId, liquidity, amount0, amount1) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint128, uint256, uint256)
                );
                break;
            }
        }
    }
    function _extractDecreaseLiquidityFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("RamsesV2ModifyPositionFuseExit(address,uint256,uint256,uint256)")) {
                (version, tokenId, amount0, amount1) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint256, uint256)
                );
                break;
            }
        }
    }

    function _extractCollectFeesFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId, uint256 amount0, uint256 amount1) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("RamsesV2CollectFuseEnter(address,uint256,uint256,uint256)")) {
                (version, tokenId, amount0, amount1) = abi.decode(
                    entries[i].data,
                    (address, uint256, uint256, uint256)
                );
                break;
            }
        }
    }

    function _extractClosePositionFromEvent(
        Vm.Log[] memory entries
    ) private view returns (address version, uint256 tokenId) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("RamsesV2NewPositionFuseExit(address,uint256)")) {
                (version, tokenId) = abi.decode(entries[i].data, (address, uint256));
                break;
            }
        }
    }

    function _createClaimRewardsManager() private {
        _claimRewardsManager = address(new RewardsClaimManager(_accessManager, _plasmaVault));
    }

    function _setupPlasmaVault() private {
        PlasmaVaultGovernance(_plasmaVault).setRewardsClaimManagerAddress(_claimRewardsManager);
    }

    function _createClaimFuse() private {
        _claimFuse = address(new RamsesClaimFuse(_NONFUNGIBLE_POSITION_MANAGER));
    }

    function _addClaimFuseToClaimRewardsManager() private {
        address[] memory fuses = new address[](1);
        fuses[0] = _claimFuse;
        RewardsClaimManager(_claimRewardsManager).addRewardFuses(fuses);
    }

    function _initAccessManager() private {
        IporFusionAccessManager accessManager = IporFusionAccessManager(_accessManager);
        address[] memory initAddress = new address[](1);
        initAddress[0] = address(this);

        address[] memory whitelist = new address[](2);
        whitelist[0] = address(this);
        whitelist[1] = _userOne;

        DataForInitialization memory data = DataForInitialization({
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: _claimRewardsManager,
                withdrawManager: address(0),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER()
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        accessManager.initialize(initializationData);
    }
}
