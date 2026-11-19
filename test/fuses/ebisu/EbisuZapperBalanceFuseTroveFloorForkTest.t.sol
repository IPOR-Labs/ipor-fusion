// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {EbisuZapperBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol";
import {ITroveManager} from "../../../contracts/fuses/ebisu/ext/ITroveManager.sol";
import {ILeverageZapper} from "../../../contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {IAddressesRegistry} from "../../../contracts/fuses/ebisu/ext/IAddressesRegistry.sol";
import {ICollSurplusPool} from "../../../contracts/fuses/ebisu/ext/ICollSurplusPool.sol";
import {
    EbisuZapperSubstrateLib,
    EbisuZapperSubstrate,
    EbisuZapperSubstrateType
} from "../../../contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";
import {FuseStorageLib} from "../../../contracts/libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";

/// @dev Stand-in for a Plasma Vault: holds the Ebisu market config and trove ids in its own storage and runs the fuse
///      by delegatecall exactly like PlasmaVault does.
contract EbisuFloorVaultHarness {
    address public immutable FUSE;

    constructor(address fuse_) {
        FUSE = fuse_;
    }

    function configure(
        address oracle_,
        bytes32[] calldata substrates_,
        address[] calldata zappers_,
        uint256[] calldata troveIds_
    ) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
        PlasmaVaultConfigLib.grantMarketSubstrates(IporFusionMarkets.EBISU, substrates_);
        FuseStorageLib.EbisuTroveIds storage troves = FuseStorageLib.getEbisuTroveIds();
        for (uint256 i; i < zappers_.length; ++i) {
            troves.troveIds[zappers_[i]] = troveIds_[i];
        }
    }

    function balanceOf() external returns (uint256) {
        (bool ok, bytes memory data) = FUSE.delegatecall(abi.encodeWithSignature("balanceOf()"));
        require(ok, "balanceOf reverted");
        return abi.decode(data, (uint256));
    }
}

/// @notice IL-9556: the Ebisu balance is floored per trove, an underwater trove does not reduce the healthy ones
contract EbisuZapperBalanceFuseTroveFloorForkTest is Test {
    address internal constant EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant WEETH_ZAPPER = 0x54965fD4Dacbc5Ab969C2F52E866c1a37AD66923;
    address internal constant SUSDE_ZAPPER = 0x10C14374104f9FC2dAE4b38F945ff8a52f48151d;
    address internal constant SUSDE_REGISTRY = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f;

    uint256 internal constant TROVE_X = 111;
    uint256 internal constant TROVE_Y = 222;
    uint256 internal constant USD = 1e18;

    PriceOracleMiddleware internal priceOracle;
    EbisuFloorVaultHarness internal vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23277699);

        address[] memory assets = new address[](4);
        assets[0] = EBUSD;
        assets[1] = WEETH;
        assets[2] = SUSDE;
        assets[3] = WETH;
        address[] memory feeds = new address[](4);
        feeds[0] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
        feeds[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        feeds[2] = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099;
        feeds[3] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        priceOracle = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        priceOracle.initialize(address(this));
        priceOracle.setAssetsPricesSources(assets, feeds);

        vault = new EbisuFloorVaultHarness(address(new EbisuZapperBalanceFuse(IporFusionMarkets.EBISU)));

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate(EbisuZapperSubstrateType.ZAPPER, SUSDE_ZAPPER)
        );
        substrates[1] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate(EbisuZapperSubstrateType.ZAPPER, WEETH_ZAPPER)
        );
        substrates[2] = EbisuZapperSubstrateLib.substrateToBytes32(
            EbisuZapperSubstrate(EbisuZapperSubstrateType.REGISTRY, SUSDE_REGISTRY)
        );
        address[] memory zappers = new address[](2);
        zappers[0] = SUSDE_ZAPPER;
        zappers[1] = WEETH_ZAPPER;
        uint256[] memory ids = new uint256[](2);
        ids[0] = TROVE_X;
        ids[1] = TROVE_Y;
        vault.configure(address(priceOracle), substrates, zappers, ids);
    }

    function testShouldFloorUnderwaterTroveAndKeepHealthyTroveFull() public {
        // given: X (sUSDe zapper) 250k collateral / 300k debt (-50k), Y (weETH zapper) 1.2M / 200k (+1.0M)
        _mockTrove(SUSDE_ZAPPER, SUSDE, TROVE_X, 250_000 * USD, 300_000 * USD);
        _mockTrove(WEETH_ZAPPER, WEETH, TROVE_Y, 1_200_000 * USD, 200_000 * USD);

        // when
        uint256 balance = vault.balanceOf();

        // then: the shortfall of X is not charged against Y
        assertApproxEqRel(balance, 1_000_000 * USD, 1e9, "underwater trove contributes 0, healthy trove its full net");
    }

    function testShouldNotDependOnTroveOrder() public {
        // given: the healthy trove sits on the sUSDe zapper and the underwater one on weETH
        _mockTrove(SUSDE_ZAPPER, SUSDE, TROVE_X, 1_200_000 * USD, 200_000 * USD);
        _mockTrove(WEETH_ZAPPER, WEETH, TROVE_Y, 250_000 * USD, 300_000 * USD);

        // when
        uint256 balance = vault.balanceOf();

        // then
        assertApproxEqRel(balance, 1_000_000 * USD, 1e9, "result must not depend on the order of the troves");
    }

    function testShouldReturnZeroWhenAllTrovesUnderwater() public {
        // given
        _mockTrove(SUSDE_ZAPPER, SUSDE, TROVE_X, 250_000 * USD, 300_000 * USD);
        _mockTrove(WEETH_ZAPPER, WEETH, TROVE_Y, 100_000 * USD, 400_000 * USD);

        // when / then
        assertEq(vault.balanceOf(), 0, "all troves underwater must give zero, never revert");
    }

    function testShouldSumHealthyTrovesUnchanged() public {
        // given
        _mockTrove(SUSDE_ZAPPER, SUSDE, TROVE_X, 500_000 * USD, 100_000 * USD);
        _mockTrove(WEETH_ZAPPER, WEETH, TROVE_Y, 300_000 * USD, 200_000 * USD);

        // when / then
        assertApproxEqRel(vault.balanceOf(), 500_000 * USD, 1e9, "healthy troves are summed as before");
    }

    function testShouldAddCollateralSurplusOutsideTroveFloor() public {
        // given: one underwater and one healthy trove, plus a surplus left by a liquidation on the sUSDe branch
        _mockTrove(SUSDE_ZAPPER, SUSDE, TROVE_X, 250_000 * USD, 300_000 * USD);
        _mockTrove(WEETH_ZAPPER, WEETH, TROVE_Y, 1_200_000 * USD, 200_000 * USD);
        uint256 surplus = _collAmount(SUSDE, 10_000 * USD);
        vm.mockCall(
            address(IAddressesRegistry(SUSDE_REGISTRY).collSurplusPool()),
            abi.encodeWithSelector(ICollSurplusPool.getCollateral.selector, address(vault)),
            abi.encode(surplus)
        );

        // when
        uint256 balance = vault.balanceOf();

        // then: the surplus is counted in full and is not netted with the underwater trove
        assertApproxEqRel(balance, 1_010_000 * USD, 1e9, "surplus is added on top of the floored troves");
    }

    function _mockTrove(
        address zapper_,
        address collToken_,
        uint256 troveId_,
        uint256 collUsd_,
        uint256 debtUsd_
    ) internal {
        ITroveManager.LatestTroveData memory data;
        data.entireColl = _collAmount(collToken_, collUsd_);
        data.entireDebt = _collAmount(EBUSD, debtUsd_);
        vm.mockCall(
            ILeverageZapper(zapper_).troveManager(),
            abi.encodeWithSelector(ITroveManager.getLatestTroveData.selector, troveId_),
            abi.encode(data)
        );
    }

    /// @dev token amount worth usdWad_ (WAD) at the vault oracle price
    function _collAmount(address token_, uint256 usdWad_) internal view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = priceOracle.getAssetPrice(token_);
        uint256 tokenDecimals = ERC20(token_).decimals();
        return IporMath.division(usdWad_ * 10 ** (tokenDecimals + priceDecimals), price * 1e18);
    }
}
