// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SiloV2BalanceFuse} from "../../../contracts/fuses/silo_v2/SiloV2BalanceFuse.sol";
import {ISilo} from "../../../contracts/fuses/silo_v2/ext/ISilo.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @dev Token with configurable decimals
contract SiloMockToken is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(uint8 decimals_) ERC20("Mock", "MOCK") {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @dev Fixed price source with a settable USD price (8 decimals) per asset
contract SiloMockPriceOracle {
    mapping(address => uint256) public prices;

    function setPrice(address asset_, uint256 price_) external {
        prices[asset_] = price_;
    }

    function getAssetPrice(address asset_) external view returns (uint256, uint256) {
        return (prices[asset_], 8);
    }
}

/// @dev Share token whose balance is set directly
contract SiloMockShareToken {
    mapping(address => uint256) public balanceOf;

    function setBalance(address account_, uint256 amount_) external {
        balanceOf[account_] = amount_;
    }
}

/// @dev Silo with 1:1 share to asset conversion for every asset type
contract SiloMockSilo {
    address public immutable ASSET;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function convertToAssets(uint256 shares_, ISilo.AssetType) external pure returns (uint256) {
        return shares_;
    }
}

/// @dev SiloConfig of one isolated market: two silos with their protected, collateral and debt share tokens
contract SiloMockConfig {
    address[2] public silos;
    mapping(address => address[3]) public shareTokens;

    constructor(address asset0_, address asset1_) {
        for (uint256 i; i < 2; ++i) {
            address silo = address(new SiloMockSilo(i == 0 ? asset0_ : asset1_));
            silos[i] = silo;
            shareTokens[silo] = [
                address(new SiloMockShareToken()),
                address(new SiloMockShareToken()),
                address(new SiloMockShareToken())
            ];
        }
    }

    function getSilos() external view returns (address, address) {
        return (silos[0], silos[1]);
    }

    function getShareTokens(address silo_) external view returns (address, address, address) {
        address[3] memory tokens = shareTokens[silo_];
        return (tokens[0], tokens[1], tokens[2]);
    }

    /// @dev siloIndex_ 0 or 1; amounts are asset units of that silo (shares convert 1:1)
    function setPosition(
        uint256 siloIndex_,
        address account_,
        uint256 protected_,
        uint256 collateral_,
        uint256 debt_
    ) external {
        address[3] memory tokens = shareTokens[silos[siloIndex_]];
        SiloMockShareToken(tokens[0]).setBalance(account_, protected_);
        SiloMockShareToken(tokens[1]).setBalance(account_, collateral_);
        SiloMockShareToken(tokens[2]).setBalance(account_, debt_);
    }
}

/// @title SiloV2BalanceFuseMarketFloorTest
/// @notice IL-9554 (IL-9528 follow-up): SiloV2BalanceFuse floors each SiloConfig (one isolated market, two silos)
///         at zero before summing, so an underwater market contributes 0 instead of charging its shortfall to the
///         healthy markets. Silos and share tokens are mocked; the fuse runs in the storage context of
///         PlasmaVaultMock through a delegatecall, as in a Plasma Vault.
contract SiloV2BalanceFuseMarketFloorTest is Test {
    uint256 private constant _ONE_USD = 1e8;
    uint256 private constant _WETH_PRICE_USD = 2_000e8;

    SiloMockPriceOracle private _oracle;
    SiloMockToken private _usdc;
    SiloMockToken private _weth;

    SiloV2BalanceFuse private _balanceFuse;
    PlasmaVaultMock private _plasmaVault;

    function setUp() public {
        _oracle = new SiloMockPriceOracle();
        _usdc = new SiloMockToken(6);
        _weth = new SiloMockToken(18);
        _oracle.setPrice(address(_usdc), _ONE_USD);
        _oracle.setPrice(address(_weth), _WETH_PRICE_USD);

        _balanceFuse = new SiloV2BalanceFuse(IporFusionMarkets.SILO_V2);
        _plasmaVault = new PlasmaVaultMock(address(0), address(_balanceFuse));
        _plasmaVault.setPriceOracleMiddleware(address(_oracle));
    }

    /// @notice PoC of IL-9554: market X holds 250k of WETH collateral and 300k USDC of debt (-50k), market Y holds
    ///         1.0M USDC of deposits. X contributes 0, so the vault holds 1.0M. Netting across markets gave 950k.
    function testShouldNotChargeShortfallOfUnderwaterMarketToHealthyMarket() external {
        // given
        SiloMockConfig marketX = _underwaterMarketX();
        SiloMockConfig marketY = _healthyMarketY();
        _grant(marketX, marketY);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_000_000e18, "underwater market X contributes 0, market Y counts in full");
    }

    /// @notice The result does not depend on the order of the granted SiloConfigs
    function testShouldNotDependOnSubstrateOrder() external {
        // given
        SiloMockConfig marketX = _underwaterMarketX();
        SiloMockConfig marketY = _healthyMarketY();
        _grant(marketY, marketX);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_000_000e18, "order of markets does not matter");
    }

    /// @notice Only the underwater market is granted: the market is worth 0 and there is no revert
    function testShouldReturnZeroWhenOnlyMarketIsUnderwater() external {
        // given
        _grant(_underwaterMarketX());

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 0, "underwater market is floored at zero");
    }

    /// @notice Several underwater markets next to one healthy market: each is floored on its own
    function testShouldFloorEveryUnderwaterMarket() external {
        // given
        SiloMockConfig marketX1 = _underwaterMarketX();
        SiloMockConfig marketX2 = _underwaterMarketX();
        SiloMockConfig marketY = _healthyMarketY();
        _grant(marketX1, marketY, marketX2);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_000_000e18, "two underwater markets contribute 0 each");
    }

    /// @notice Inside one market the two silos are still netted: collateral in silo0 and debt in silo1 of the same
    ///         SiloConfig give net value, and a healthy market adds to it
    function testShouldNetSilosOfOneMarket() external {
        // given
        // market Z: 100 WETH collateral (200k) vs 50k USDC debt in the other silo -> +150k
        SiloMockConfig marketZ = new SiloMockConfig(address(_weth), address(_usdc));
        marketZ.setPosition(0, address(_plasmaVault), 0, 100e18, 0);
        marketZ.setPosition(1, address(_plasmaVault), 0, 0, 50_000e6);
        _grant(marketZ, _healthyMarketY());

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_150_000e18, "silos of one market are netted, markets are summed");
    }

    /// @notice Protected and collateral deposits of both silos count in full when there is no debt
    function testShouldCountAllDepositsOfHealthyMarkets() external {
        // given
        SiloMockConfig marketY = _healthyMarketY();
        marketY.setPosition(1, address(_plasmaVault), 10e18, 5e18, 0); // 15 WETH = 30k
        _grant(marketY);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 1_030_000e18, "protected + collateral of both silos");
    }

    function _underwaterMarketX() private returns (SiloMockConfig market) {
        market = new SiloMockConfig(address(_weth), address(_usdc));
        // 125 WETH of collateral = 250k USD in silo0, 300k USDC of debt in silo1
        market.setPosition(0, address(_plasmaVault), 0, 125e18, 0);
        market.setPosition(1, address(_plasmaVault), 0, 0, 300_000e6);
    }

    function _healthyMarketY() private returns (SiloMockConfig market) {
        market = new SiloMockConfig(address(_usdc), address(_weth));
        // 400k protected + 600k collateral USDC, no debt
        market.setPosition(0, address(_plasmaVault), 400_000e6, 600_000e6, 0);
    }

    function _grant(SiloMockConfig a_) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(a_));
        _plasmaVault.grantMarketSubstrates(IporFusionMarkets.SILO_V2, substrates);
    }

    function _grant(SiloMockConfig a_, SiloMockConfig b_) private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(a_));
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(address(b_));
        _plasmaVault.grantMarketSubstrates(IporFusionMarkets.SILO_V2, substrates);
    }

    function _grant(SiloMockConfig a_, SiloMockConfig b_, SiloMockConfig c_) private {
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(a_));
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(address(b_));
        substrates[2] = PlasmaVaultConfigLib.addressToBytes32(address(c_));
        _plasmaVault.grantMarketSubstrates(IporFusionMarkets.SILO_V2, substrates);
    }
}
