// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SiloV2BalanceFuse} from "../../../contracts/fuses/silo_v2/SiloV2BalanceFuse.sol";
import {ISilo} from "../../../contracts/fuses/silo_v2/ext/ISilo.sol";
import {ISiloConfig} from "../../../contracts/fuses/silo_v2/ext/ISiloConfig.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {SiloMockPriceOracle, SiloMockToken, SiloMockConfig} from "./SiloV2BalanceFuseMarketFloorTest.t.sol";

/// @title SiloV2BalanceFuseMarketFloorForkTest
/// @notice IL-9554 on an Ethereum mainnet fork with the real weETH/WETH SiloConfig. The vault supplies weETH to silo0
///         and borrows WETH from silo1 (real Silo V2 accounting). The vault price oracle is a mock so that the
///         position can be pushed underwater by repricing weETH, while Silo itself keeps its own solvency oracle.
///         A second, healthy market (mock SiloConfig with USDC deposits) must keep its full value.
///         Simplification against a variant where the vault also deposits in the debt silo of the same market:
///         such deposits are counted inside the same SiloConfig unit and are not liquidation-proof.
contract SiloV2BalanceFuseMarketFloorForkTest is Test {
    /// @dev Own fork block of this suite
    uint256 private constant _FORK_BLOCK = 23_432_022;

    address private constant _SILO_CONFIG_WEETH_WETH = 0xeC7C5CAaEA12A1a6952F3a3D0e3ca5B678433934;
    address private constant _WE_ETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    uint256 private constant _COLLATERAL_WE_ETH = 75e18;
    uint256 private constant _BORROW_WETH = 50e18;

    uint256 private constant _WETH_PRICE_USD = 4_000e8;
    uint256 private constant _WE_ETH_PRICE_HEALTHY_USD = 4_200e8;
    /// @dev 75 weETH worth 75k USD against 200k USD of debt
    uint256 private constant _WE_ETH_PRICE_UNDERWATER_USD = 1_000e8;

    SiloMockPriceOracle private _oracle;
    SiloV2BalanceFuse private _balanceFuse;
    PlasmaVaultMock private _plasmaVault;
    SiloMockConfig private _healthyMarket;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        _oracle = new SiloMockPriceOracle();
        SiloMockToken usdc = new SiloMockToken(6);
        _oracle.setPrice(address(usdc), 1e8);
        _oracle.setPrice(_WETH, _WETH_PRICE_USD);
        _oracle.setPrice(_WE_ETH, _WE_ETH_PRICE_HEALTHY_USD);

        _balanceFuse = new SiloV2BalanceFuse(IporFusionMarkets.SILO_V2);
        _plasmaVault = new PlasmaVaultMock(address(0), address(_balanceFuse));
        _plasmaVault.setPriceOracleMiddleware(address(_oracle));

        // real position: weETH collateral in silo0, WETH debt in silo1
        (address silo0, address silo1) = ISiloConfig(_SILO_CONFIG_WEETH_WETH).getSilos();
        deal(_WE_ETH, address(_plasmaVault), _COLLATERAL_WE_ETH);
        vm.startPrank(address(_plasmaVault));
        ERC20(_WE_ETH).approve(silo0, _COLLATERAL_WE_ETH);
        ISilo(silo0).deposit(_COLLATERAL_WE_ETH, address(_plasmaVault), ISilo.CollateralType.Collateral);
        ISilo(silo1).borrow(_BORROW_WETH, address(_plasmaVault), address(_plasmaVault));
        vm.stopPrank();

        // healthy second market: 10 000 USDC of deposits
        _healthyMarket = new SiloMockConfig(address(usdc), _WETH);
        _healthyMarket.setPosition(0, address(_plasmaVault), 4_000e6, 6_000e6, 0);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_SILO_CONFIG_WEETH_WETH);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(address(_healthyMarket));
        _plasmaVault.grantMarketSubstrates(IporFusionMarkets.SILO_V2, substrates);
    }

    /// @notice While the real weETH/WETH market is healthy for the vault, the two markets are summed
    function testShouldSumRealMarketAndHealthyMarketWhenRealMarketIsHealthy() external {
        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        // collateral ~ 75 weETH * 4200 = 315k, debt ~ 50 WETH * 4000 = 200k, plus 10k of the second market
        assertGt(balance, 10_000e18 + 100_000e18, "real market adds its positive net value to the second market");
    }

    /// @notice Real market underwater by repricing weETH in the vault oracle: it contributes 0 and the second
    ///         market keeps exactly its value (netting gave 10k - ~125k, floored to 0 as a total)
    function testShouldNotChargeUnderwaterRealMarketToHealthyMarket() external {
        // given
        _oracle.setPrice(_WE_ETH, _WE_ETH_PRICE_UNDERWATER_USD);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 10_000e18, "underwater real market contributes 0, second market counts in full");
    }

    /// @notice Only the underwater real market is granted: 0, no revert
    function testShouldReturnZeroWhenOnlyRealMarketIsUnderwater() external {
        // given
        _oracle.setPrice(_WE_ETH, _WE_ETH_PRICE_UNDERWATER_USD);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_SILO_CONFIG_WEETH_WETH);
        _plasmaVault.grantMarketSubstrates(IporFusionMarkets.SILO_V2, substrates);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 0, "underwater real market is floored at zero");
    }
}
