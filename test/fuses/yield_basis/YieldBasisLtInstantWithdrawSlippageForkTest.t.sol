// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    YieldBasisLtSupplyFuse,
    YieldBasisLtSupplyFuseEnterData,
    YieldBasisLtSupplyFuseExitData
} from "../../../contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";
import {IYieldBasisLT} from "../../../contracts/fuses/yield_basis/ext/IYieldBasisLT.sol";
import {FullMath} from "../../../contracts/fuses/ramses/ext/FullMath.sol";

interface ICurveTwoCryptoPool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external returns (uint256);
}

/// @dev Minimal vault storage context that delegatecalls the Yield Basis supply fuse
contract YieldBasisForkVaultHarness {
    address public immutable UNDERLYING;

    constructor(address underlying_) {
        UNDERLYING = underlying_;
    }

    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function grantSubstrate(uint256 marketId_, address substrate_) external {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(substrate_);
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates);
    }

    function enter(address fuse_, YieldBasisLtSupplyFuseEnterData calldata data_) external {
        _delegate(fuse_, abi.encodeCall(YieldBasisLtSupplyFuse.enter, (data_)));
    }

    function exit(address fuse_, YieldBasisLtSupplyFuseExitData calldata data_) external {
        _delegate(fuse_, abi.encodeCall(YieldBasisLtSupplyFuse.exit, (data_)));
    }

    function instantWithdraw(address fuse_, bytes32[] calldata params_) external {
        _delegate(fuse_, abi.encodeCall(YieldBasisLtSupplyFuse.instantWithdraw, (params_)));
    }

    function _delegate(address fuse_, bytes memory data_) private {
        (bool success, bytes memory result) = fuse_.delegatecall(data_);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @notice IL-8367 fork tests against the live WBTC LT: LT.withdraw unwinds through the Curve crvUSD/WBTC pool at its
/// spot state, so a skewed pool delivers far less than the oracle-based pricePerShare. The instant withdrawal floor
/// must let honest withdrawals through and skip the market when the pool is skewed.
contract YieldBasisLtInstantWithdrawSlippageForkTest is Test {
    uint256 internal constant MARKET_ID = 37;

    address internal constant YIELD_BASIS_LT_WBTC = 0x6095a220C5567360d459462A25b1AD5aEAD45204;
    address internal constant CURVE_POOL_CRVUSD_WBTC = 0xD9FF8396554A0d18B2CFbeC53e1979b7ecCe8373;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    uint256 internal constant SUPPLY_WBTC = 0.0005e8;
    uint256 internal constant SUPPLY_DEBT = 59e18;
    uint256 internal constant WITHDRAW_WBTC = 0.00025e8;
    /// @dev Dumping 80 WBTC into the ~84 WBTC / 10M crvUSD pool cuts the single-sided withdrawal by ~60%
    uint256 internal constant SKEW_WBTC = 80e8;

    event YieldBasisLtSupplyFuseExitFailed(address version, address ltAddress, uint256 ltSharesAmount);

    YieldBasisLtSupplyFuse internal fuse;
    YieldBasisForkVaultHarness internal vault;
    IYieldBasisLT internal lt = IYieldBasisLT(YIELD_BASIS_LT_WBTC);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23527830);

        fuse = new YieldBasisLtSupplyFuse(MARKET_ID);
        vault = new YieldBasisForkVaultHarness(WBTC);
        vault.grantSubstrate(MARKET_ID, YIELD_BASIS_LT_WBTC);

        deal(WBTC, address(vault), SUPPLY_WBTC);
        vault.enter(
            address(fuse),
            YieldBasisLtSupplyFuseEnterData({
                ltAddress: YIELD_BASIS_LT_WBTC,
                ltAssetAmount: SUPPLY_WBTC,
                debt: SUPPLY_DEBT,
                minSharesToReceive: 0
            })
        );
        vm.warp(block.timestamp + 1);
    }

    function testForkShouldInstantWithdrawWithinDefaultTolerance() public {
        // given
        uint256 sharesBefore = lt.balanceOf(address(vault));
        uint256 pricePerShare = lt.pricePerShare();

        // when
        vault.instantWithdraw(address(fuse), _params(WITHDRAW_WBTC));

        // then
        uint256 sharesBurned = sharesBefore - lt.balanceOf(address(vault));
        uint256 oracleValue = (sharesBurned * pricePerShare) / 1e18 / 1e10;
        uint256 received = IERC20(WBTC).balanceOf(address(vault));
        assertGt(sharesBurned, 0, "LT shares burned");
        assertGe(received, (oracleValue * 99) / 100, "received within the default 1% tolerance");
        assertApproxEqRel(received, WITHDRAW_WBTC, 1e16, "requested amount delivered");
    }

    function testForkShouldSkipInstantWithdrawWhenPoolIsSkewed() public {
        // given
        uint256 sharesBefore = lt.balanceOf(address(vault));
        _skewPool();
        /// @dev swap fees raise the pool virtual price, so pricePerShare can only go up within the block
        uint256 sharesToWithdraw = FullMath.mulDiv(WITHDRAW_WBTC * 1e10, 1e18, lt.pricePerShare());

        // then
        vm.expectEmit(true, true, true, true, address(vault));
        emit YieldBasisLtSupplyFuseExitFailed(address(fuse), YIELD_BASIS_LT_WBTC, sharesToWithdraw);

        // when
        vault.instantWithdraw(address(fuse), _params(WITHDRAW_WBTC));

        assertEq(IERC20(WBTC).balanceOf(address(vault)), 0, "nothing withdrawn from the skewed pool");
        assertEq(lt.balanceOf(address(vault)), sharesBefore, "LT position untouched");
    }

    /// @dev Evidence that the floor matters: without it the same skewed withdrawal realizes a loss against the
    ///      oracle value that the vault's NAV would absorb
    function testForkSkewedPoolDeliversBelowOracleValueWithoutFloor() public {
        // given
        uint256 sharesToWithdraw = lt.balanceOf(address(vault)) / 2;
        uint256 oracleValue = (sharesToWithdraw * lt.pricePerShare()) / 1e18 / 1e10;
        _skewPool();

        // when
        vault.exit(address(fuse), YieldBasisLtSupplyFuseExitData(YIELD_BASIS_LT_WBTC, sharesToWithdraw, 0));

        // then
        uint256 received = IERC20(WBTC).balanceOf(address(vault));
        emit log_named_uint("oracle value (WBTC)", oracleValue);
        emit log_named_uint("received (WBTC)", received);
        assertLt(received, oracleValue / 2, "skewed pool delivers less than half of the oracle value");
    }

    function _skewPool() private {
        address attacker = makeAddr("attacker");
        deal(WBTC, attacker, SKEW_WBTC);
        vm.startPrank(attacker);
        IERC20(WBTC).approve(CURVE_POOL_CRVUSD_WBTC, SKEW_WBTC);
        ICurveTwoCryptoPool(CURVE_POOL_CRVUSD_WBTC).exchange(1, 0, SKEW_WBTC, 0);
        vm.stopPrank();
    }

    function _params(uint256 amount_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(amount_);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(YIELD_BASIS_LT_WBTC);
    }
}
