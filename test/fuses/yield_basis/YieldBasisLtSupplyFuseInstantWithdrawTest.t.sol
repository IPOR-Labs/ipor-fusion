// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {YieldBasisLtSupplyFuse} from "../../../contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";

contract DecimalsToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) ERC20("Underlying", "UND") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev LT mock mirroring the real LT.withdraw slippage check: it pays shares * pricePerShare scaled by
///      deliveryRatio (a sandwiched Curve pool delivers less than the oracle value) and reverts below minAssets
contract SlippageMockYieldBasisLt {
    DecimalsToken public immutable ASSET;
    mapping(address => uint256) public balanceOf;
    uint256 public pricePerShare = 1e18;
    uint256 public deliveryRatio = 1e18;
    uint256 public lastMinAssets;

    constructor(DecimalsToken asset_) {
        ASSET = asset_;
    }

    function setBalance(address account_, uint256 amount_) external {
        balanceOf[account_] = amount_;
    }

    function setPricePerShare(uint256 value_) external {
        pricePerShare = value_;
    }

    function setDeliveryRatio(uint256 value_) external {
        deliveryRatio = value_;
    }

    function withdraw(uint256 shares_, uint256 minAssets_, address receiver_) external returns (uint256 received) {
        lastMinAssets = minAssets_;
        uint256 valueInWad = (((shares_ * pricePerShare) / 1e18) * deliveryRatio) / 1e18;
        received = valueInWad / 10 ** (18 - ASSET.decimals());
        require(received >= minAssets_, "Slippage");
        balanceOf[msg.sender] -= shares_;
        ASSET.mint(receiver_, received);
    }
}

/// @dev Minimal vault storage context that delegatecalls instantWithdraw like PlasmaVaultMarketsLib.withdrawFromMarkets
contract YieldBasisInstantWithdrawHarness {
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

    function instantWithdraw(address fuse_, bytes32[] calldata params_) external {
        (bool success, bytes memory result) = fuse_.delegatecall(
            abi.encodeCall(YieldBasisLtSupplyFuse.instantWithdraw, (params_))
        );
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @notice Regression tests for IL-8367: YieldBasisLtSupplyFuse.instantWithdraw must pass an amount-relative minimum
/// output derived from the oracle-based pricePerShare, so a sandwiched Curve pool cannot drain vault NAV
contract YieldBasisLtSupplyFuseInstantWithdrawTest is Test {
    uint256 internal constant MARKET_ID = 37;

    event YieldBasisLtSupplyFuseExit(
        address version,
        address ltAddress,
        uint256 ltSharesAmount,
        uint256 ltAssetAmountReceived
    );
    event YieldBasisLtSupplyFuseExitFailed(address version, address ltAddress, uint256 ltSharesAmount);

    YieldBasisLtSupplyFuse internal fuse;

    function setUp() public {
        fuse = new YieldBasisLtSupplyFuse(MARKET_ID);
    }

    function testShouldApplyDefaultSlippageWhenParamIsNotConfigured() public {
        // given
        (DecimalsToken token, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt)));

        // then
        assertEq(lt.lastMinAssets(), 99e18, "min out = 100 * (1 - 1%)");
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertEq(lt.balanceOf(address(vault)), 900e18);
    }

    function testShouldApplyConfiguredSlippage() public {
        // given
        (, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt), 2e16));

        // then
        assertEq(lt.lastMinAssets(), 98e18, "min out = 100 * (1 - 2%)");
    }

    function testShouldRequireFullOracleValueWhenSlippageIsZero() public {
        // given
        (, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt), 0));

        // then
        assertEq(lt.lastMinAssets(), 100e18);
    }

    function testShouldCapConfiguredSlippageAtMaximum() public {
        // given
        (, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt), 5e17));

        // then
        assertEq(lt.lastMinAssets(), 95e18, "50% tolerance capped at 5%");
    }

    function testShouldDeriveMinOutFromPricePerShare() public {
        // given
        (, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);
        lt.setPricePerShare(2e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt)));

        // then
        assertEq(lt.balanceOf(address(vault)), 950e18, "50 shares burned at 2 assets per share");
        assertEq(lt.lastMinAssets(), 99e18, "min out = 50 shares * 2 * (1 - 1%)");
    }

    function testShouldScaleMinOutToAssetDecimals() public {
        // given
        (DecimalsToken token, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(8);
        lt.setBalance(address(vault), 10e18);
        lt.setPricePerShare(1.0077e18);

        // when
        vault.instantWithdraw(address(fuse), _params(1e8, address(lt)));

        // then
        uint256 shares = 10e18 - lt.balanceOf(address(vault));
        uint256 expectedInWad = (shares * 1.0077e18) / 1e18;
        assertEq(lt.lastMinAssets(), (expectedInWad * 99) / 100 / 1e10, "min out in 8 decimals");
        assertApproxEqAbs(lt.lastMinAssets(), 0.99e8, 1);
        assertApproxEqAbs(token.balanceOf(address(vault)), 1e8, 1);
    }

    function testShouldSkipWithdrawalWhenPoolDeliversBelowFloor() public {
        // given
        (DecimalsToken token, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);
        lt.setDeliveryRatio(0.7e18);

        // then
        vm.expectEmit(true, true, true, true, address(vault));
        emit YieldBasisLtSupplyFuseExitFailed(address(fuse), address(lt), 100e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt)));

        assertEq(token.balanceOf(address(vault)), 0, "nothing delivered below the floor");
        assertEq(lt.balanceOf(address(vault)), 1_000e18, "LT position untouched");
    }

    function testShouldWithdrawWhenPoolDeliversWithinTolerance() public {
        // given
        (DecimalsToken token, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) = _deploy(18);
        lt.setBalance(address(vault), 1_000e18);
        lt.setDeliveryRatio(0.995e18);

        // then
        vm.expectEmit(true, true, true, true, address(vault));
        emit YieldBasisLtSupplyFuseExit(address(fuse), address(lt), 100e18, 99.5e18);

        // when
        vault.instantWithdraw(address(fuse), _params(100e18, address(lt)));

        assertEq(token.balanceOf(address(vault)), 99.5e18);
        assertEq(lt.balanceOf(address(vault)), 900e18);
    }

    function _deploy(
        uint8 decimals_
    ) private returns (DecimalsToken token, SlippageMockYieldBasisLt lt, YieldBasisInstantWithdrawHarness vault) {
        token = new DecimalsToken(decimals_);
        lt = new SlippageMockYieldBasisLt(token);
        vault = new YieldBasisInstantWithdrawHarness(address(token));
        vault.grantSubstrate(MARKET_ID, address(lt));
    }

    function _params(uint256 amount_, address lt_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(amount_);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(lt_);
    }

    function _params(uint256 amount_, address lt_, uint256 slippage_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](3);
        params[0] = bytes32(amount_);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(lt_);
        params[2] = bytes32(slippage_);
    }
}
