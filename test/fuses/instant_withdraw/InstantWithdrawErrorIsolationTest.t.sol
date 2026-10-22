// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultMarketsLib} from "../../../contracts/vaults/lib/PlasmaVaultMarketsLib.sol";
import {PlasmaVaultLib, InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FusesLib} from "../../../contracts/libraries/FusesLib.sol";
import {CurveChildLiquidityGaugeSupplyFuse} from "../../../contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {
    YieldBasisLtSupplyFuse,
    YieldBasisLtSupplyFuseExitData
} from "../../../contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";

contract MintableToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev ERC4626-like LP token, only previewWithdraw is used by the gauge fuse (1:1)
contract MockCurveLp {
    function previewWithdraw(uint256 assets_) external pure returns (uint256) {
        return assets_;
    }
}

/// @dev Simplified gauge: unstaking pays the underlying 1:1 so the vault balance reflects what the gauge released
contract MockChildGauge {
    MintableToken public immutable UNDERLYING;
    address public immutable LP;
    mapping(address => uint256) public balanceOf;

    constructor(MintableToken underlying_, address lp_) {
        UNDERLYING = underlying_;
        LP = lp_;
    }

    function lp_token() external view returns (address) {
        return LP;
    }

    function setStake(address account_, uint256 amount_) external {
        balanceOf[account_] = amount_;
    }

    function withdraw(uint256 value_, address user_, bool) external {
        balanceOf[msg.sender] -= value_;
        UNDERLYING.mint(user_, value_);
    }
}

contract MockYieldBasisLt {
    MintableToken public immutable UNDERLYING;
    mapping(address => uint256) public balanceOf;
    bool public withdrawReverts;

    error MockYieldBasisLtWithdrawFailed();

    constructor(MintableToken underlying_) {
        UNDERLYING = underlying_;
    }

    function setBalance(address account_, uint256 amount_) external {
        balanceOf[account_] = amount_;
    }

    function setWithdrawReverts(bool value_) external {
        withdrawReverts = value_;
    }

    function pricePerShare() external pure returns (uint256) {
        return 1e18;
    }

    function withdraw(uint256 shares_, uint256, address receiver_) external returns (uint256) {
        if (withdrawReverts) {
            revert MockYieldBasisLtWithdrawFailed();
        }
        balanceOf[msg.sender] -= shares_;
        UNDERLYING.mint(receiver_, shares_);
        return shares_;
    }
}

/// @dev Instant withdrawal fuse that always delivers the requested amount
contract HealthyInstantWithdrawFuse {
    uint256 public immutable MARKET_ID;
    MintableToken public immutable UNDERLYING;

    constructor(uint256 marketId_, MintableToken underlying_) {
        MARKET_ID = marketId_;
        UNDERLYING = underlying_;
    }

    function instantWithdraw(bytes32[] calldata params_) external {
        UNDERLYING.mint(address(this), uint256(params_[0]));
    }
}

/// @dev Minimal vault storage context running the real PlasmaVaultMarketsLib.withdrawFromMarkets loop
contract InstantWithdrawVaultHarness {
    address public immutable UNDERLYING;

    constructor(address underlying_) {
        UNDERLYING = underlying_;
    }

    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function addFuse(address fuse_) external {
        FusesLib.addFuse(fuse_);
    }

    function grantSubstrate(uint256 marketId_, address substrate_) external {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(substrate_);
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates);
    }

    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) external {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses_);
    }

    function withdrawFromMarkets(uint256 assets_) external returns (uint256[] memory) {
        return
            PlasmaVaultMarketsLib.withdrawFromMarkets(UNDERLYING, assets_, ERC20(UNDERLYING).balanceOf(address(this)));
    }

    function yieldBasisExit(address fuse_, YieldBasisLtSupplyFuseExitData calldata data_) external {
        (bool success, bytes memory result) = fuse_.delegatecall(abi.encodeCall(YieldBasisLtSupplyFuse.exit, (data_)));
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @notice Regression tests for IL-8329: an instant withdrawal fuse that cannot cover the remaining amount
/// (or whose protocol call fails) must not revert, so PlasmaVaultMarketsLib.withdrawFromMarkets falls through
/// to the next configured fuse instead of blocking every user withdraw/redeem.
contract InstantWithdrawErrorIsolationTest is Test {
    uint256 internal constant GAUGE_MARKET_ID = 1001;
    uint256 internal constant YIELD_BASIS_MARKET_ID = 1002;
    uint256 internal constant HEALTHY_MARKET_ID = 1003;

    event YieldBasisLtSupplyFuseExitFailed(address version, address ltAddress, uint256 ltSharesAmount);

    MintableToken internal underlying;
    InstantWithdrawVaultHarness internal vault;
    HealthyInstantWithdrawFuse internal healthyFuse;

    CurveChildLiquidityGaugeSupplyFuse internal gaugeFuse;
    MockChildGauge internal gauge;

    YieldBasisLtSupplyFuse internal yieldBasisFuse;
    MockYieldBasisLt internal lt;

    function setUp() public {
        underlying = new MintableToken();
        vault = new InstantWithdrawVaultHarness(address(underlying));
        healthyFuse = new HealthyInstantWithdrawFuse(HEALTHY_MARKET_ID, underlying);

        gaugeFuse = new CurveChildLiquidityGaugeSupplyFuse(GAUGE_MARKET_ID);
        gauge = new MockChildGauge(underlying, address(new MockCurveLp()));

        yieldBasisFuse = new YieldBasisLtSupplyFuse(YIELD_BASIS_MARKET_ID);
        lt = new MockYieldBasisLt(underlying);

        vault.addFuse(address(healthyFuse));
        vault.addFuse(address(gaugeFuse));
        vault.addFuse(address(yieldBasisFuse));
        vault.grantSubstrate(GAUGE_MARKET_ID, address(gauge));
        vault.grantSubstrate(YIELD_BASIS_MARKET_ID, address(lt));
    }

    function testShouldFallThroughToNextFuseWhenGaugeStakeIsBelowRemainingAmount() public {
        // given
        gauge.setStake(address(vault), 100e18);
        _configure(address(gaugeFuse), address(gauge));

        // when
        uint256[] memory markets = vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18, "withdrawal fully covered");
        assertEq(gauge.balanceOf(address(vault)), 0, "gauge stake fully unstaked");
        assertEq(markets[0], GAUGE_MARKET_ID);
        assertEq(markets[1], HEALTHY_MARKET_ID);
    }

    function testShouldFallThroughToNextFuseWhenGaugeStakeIsZero() public {
        // given
        _configure(address(gaugeFuse), address(gauge));

        // when
        vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18, "healthy fuse covers the full amount");
    }

    function testShouldWithdrawOnlyRequestedAmountFromGaugeWhenStakeIsSufficient() public {
        // given
        gauge.setStake(address(vault), 5_000e18);
        _configure(address(gaugeFuse), address(gauge));

        // when
        vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18);
        assertEq(gauge.balanceOf(address(vault)), 4_000e18, "only the requested amount unstaked");
    }

    function testShouldFallThroughToNextFuseWhenYieldBasisWithdrawReverts() public {
        // given
        lt.setBalance(address(vault), 500e18);
        lt.setWithdrawReverts(true);
        _configure(address(yieldBasisFuse), address(lt));

        // when
        vm.expectEmit(true, true, true, true, address(vault));
        emit YieldBasisLtSupplyFuseExitFailed(address(yieldBasisFuse), address(lt), 500e18);
        vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18, "healthy fuse covers the full amount");
        assertEq(lt.balanceOf(address(vault)), 500e18, "LT position untouched");
    }

    function testShouldWithdrawFromYieldBasisWhenWithdrawSucceeds() public {
        // given
        lt.setBalance(address(vault), 500e18);
        _configure(address(yieldBasisFuse), address(lt));

        // when
        vault.withdrawFromMarkets(1_000e18);

        // then
        assertEq(underlying.balanceOf(address(vault)), 1_000e18);
        assertEq(lt.balanceOf(address(vault)), 0, "LT position fully withdrawn");
    }

    function testShouldStillRevertOnYieldBasisExitWhenWithdrawReverts() public {
        // given
        lt.setBalance(address(vault), 500e18);
        lt.setWithdrawReverts(true);

        // then
        vm.expectRevert(MockYieldBasisLt.MockYieldBasisLtWithdrawFailed.selector);
        // when
        vault.yieldBasisExit(address(yieldBasisFuse), YieldBasisLtSupplyFuseExitData(address(lt), 500e18, 0));
    }

    function _configure(address firstFuse_, address firstSubstrate_) internal {
        InstantWithdrawalFusesParamsStruct[] memory fuses = new InstantWithdrawalFusesParamsStruct[](2);

        bytes32[] memory firstParams = new bytes32[](2);
        firstParams[1] = PlasmaVaultConfigLib.addressToBytes32(firstSubstrate_);
        fuses[0] = InstantWithdrawalFusesParamsStruct({fuse: firstFuse_, params: firstParams});

        fuses[1] = InstantWithdrawalFusesParamsStruct({fuse: address(healthyFuse), params: new bytes32[](1)});

        vault.configureInstantWithdrawalFuses(fuses);
    }
}
