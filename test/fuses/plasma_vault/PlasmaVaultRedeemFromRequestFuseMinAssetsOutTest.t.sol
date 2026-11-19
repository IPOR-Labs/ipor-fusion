// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {RequestBackingTestBase} from "../../vaults/request_backing/RequestBackingTestBase.sol";
import {PlasmaVaultRedeemFromRequestFuse} from "../../../contracts/fuses/plasma_vault/PlasmaVaultRedeemFromRequestFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";

/// @dev Mirror of `PlasmaVaultRedeemFromRequestFuseEnterData` after IL-9622. It is declared here, and the fuse is
///      called by signature, so that this file compiles against the pre-IL-9622 fuse too.
struct EnterDataWithMin {
    uint256 sharesAmount;
    address plasmaVault;
    uint256 minAssetsOut;
}

/// @dev Target vault whose `redeemFromRequest` pays `paid` assets and reports `reported` assets
contract MisreportingRequestVault {
    address public immutable ASSET;
    uint256 public paid;
    uint256 public reported;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function setBalance(address account_, uint256 shares_) external {
        balanceOf[account_] = shares_;
    }

    function setPayout(uint256 paid_, uint256 reported_) external {
        paid = paid_;
        reported = reported_;
    }

    function redeemFromRequest(uint256 shares_, address receiver_, address owner_) external returns (uint256) {
        balanceOf[owner_] -= shares_;
        IERC20(ASSET).transfer(receiver_, paid);
        return reported;
    }
}

/// @notice Tests of `minAssetsOut` of `PlasmaVaultRedeemFromRequestFuseEnterData` (IL-9622) against a real
///         PlasmaVault child (no fork): a redeem below the minimum reverts, 0 disables the check.
contract PlasmaVaultRedeemFromRequestFuseMinAssetsOutTest is RequestBackingTestBase {
    uint256 private constant FUSE_MARKET_ID = 1;
    uint256 private constant DEPOSIT = 100_000e6;
    /// @dev Selector from the signature so that this file compiles against the pre-IL-9622 fuse too
    bytes4 private constant INSUFFICIENT_ASSETS_SELECTOR =
        bytes4(keccak256("PlasmaVaultRedeemFromRequestFuseInsufficientAssets(uint256,uint256)"));
    string private constant ENTER_SIGNATURE = "enter((uint256,address,uint256))";

    PlasmaVaultRedeemFromRequestFuse private fuse;
    PlasmaVaultMock private parent;
    uint256 private shares;

    function setUp() public override {
        super.setUp();
        fuse = new PlasmaVaultRedeemFromRequestFuse(FUSE_MARKET_ID);
        parent = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory granted = new address[](1);
        granted[0] = address(vault);
        parent.grantAssetsToMarket(FUSE_MARKET_ID, granted);

        // the parent holds the child's shares and has a released request for all of them
        usdc.mint(HONEST, DEPOSIT);
        vm.startPrank(HONEST);
        usdc.approve(address(vault), DEPOSIT);
        shares = vault.deposit(DEPOSIT, address(parent));
        vm.stopPrank();
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(address(parent));
        wm.requestShares(shares);
        vm.warp(block.timestamp + 1 hours);
        _release(shares);
    }

    function testShouldHaveExpectedEnterSelectorAndErrorSelector() external pure {
        assertEq(bytes4(keccak256(bytes(ENTER_SIGNATURE))), bytes4(0x764e8db7), "enter selector");
        assertEq(INSUFFICIENT_ASSETS_SELECTOR, bytes4(0x97a5a00a), "insufficient assets error selector");
    }

    function testShouldRevertWhenRedeemReceivesLessThanMinAssetsOut() external {
        // given
        uint256 expected = _measureRedeemedAssets(shares);
        uint256 minAssetsOut = expected + 1;

        // when
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, expected, minAssetsOut));
        _enter(shares, address(vault), minAssetsOut);

        // then
        assertEq(vault.balanceOf(address(parent)), shares, "the revert undoes the redeem");
        assertEq(usdc.balanceOf(address(parent)), 0, "no assets received");
    }

    function testShouldRedeemWhenReceivedAssetsEqualMinAssetsOut() external {
        // given
        uint256 expected = _measureRedeemedAssets(shares);
        assertGt(expected, 0, "scenario pays assets");

        // when
        _enter(shares, address(vault), expected);

        // then
        assertEq(vault.balanceOf(address(parent)), 0, "shares redeemed");
        assertEq(usdc.balanceOf(address(parent)), expected, "assets received");
    }

    function testShouldRedeemWithoutExtraBalanceReadWhenMinAssetsOutIsZero() external {
        // given
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.balanceOf, (address(parent))), 0);

        // when
        _enter(shares, address(vault), 0);

        // then
        assertEq(vault.balanceOf(address(parent)), 0, "shares redeemed");
    }

    function testShouldAddTwoBalanceReadsWhenMinAssetsOutIsSet() external {
        // given
        uint256 expected = _measureRedeemedAssets(shares);
        // the fuse reads the balance before and after the redeem
        vm.expectCall(address(usdc), abi.encodeCall(IERC20.balanceOf, (address(parent))), 2);

        // when
        _enter(shares, address(vault), expected);
    }

    function testShouldApplyMinAssetsOutAbsolutelyWhenSharesAreClippedToBalance() external {
        // given
        uint256 expected = _measureRedeemedAssets(shares);

        // when - twice the held shares are requested, the fuse clips to the held balance and redeems `shares`
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, expected, expected + 1));
        _enter(shares * 2, address(vault), expected + 1);

        // then - a minimum that the clipped amount satisfies passes
        _enter(shares * 2, address(vault), expected);
        assertEq(vault.balanceOf(address(parent)), 0, "held shares redeemed");
        assertEq(usdc.balanceOf(address(parent)), expected, "assets received");
    }

    function testShouldNotCheckMinAssetsOutWhenNothingIsRedeemed() external {
        // given - zero shares requested
        // when
        _enter(0, address(vault), type(uint256).max);

        // then
        assertEq(vault.balanceOf(address(parent)), shares, "nothing redeemed");
    }

    function testShouldRevertForUnsupportedVaultRegardlessOfMinAssetsOut() external {
        // given
        address unsupported = address(0xBEEF);

        // when / then
        vm.expectRevert(
            abi.encodeWithSignature(
                "PlasmaVaultRedeemFromRequestFuseUnsupportedVault(string,address)",
                "enter",
                unsupported
            )
        );
        _enter(shares, unsupported, 1);
    }

    function testShouldRejectTheTwoFieldEnterSelectorOfThePreviousBuild() external {
        // given
        bytes memory legacyCall = abi.encodeWithSignature(
            "enter((uint256,address))",
            EnterLegacy({sharesAmount: shares, plasmaVault: address(vault)})
        );

        // when / then - the previous selector no longer exists on this build: the fuse has no fallback, so the
        // delegatecall reverts with empty data, surfaced by Address.functionDelegateCall as FailedInnerCall
        vm.expectRevert(abi.encodeWithSelector(Address.FailedInnerCall.selector));
        parent.execute(address(fuse), legacyCall);
    }

    function testShouldUseMeasuredAssetsNotTheValueReturnedByTheTargetVault() external {
        // given - the target pays 100 and reports 1_000
        MisreportingRequestVault target = new MisreportingRequestVault(address(usdc));
        usdc.mint(address(target), 1_000);
        target.setBalance(address(parent), 10);
        target.setPayout(100, 1_000);
        address[] memory granted = new address[](1);
        granted[0] = address(target);
        parent.grantAssetsToMarket(FUSE_MARKET_ID, granted);

        // when / then - 101 is above what was received, the reported 1_000 does not count
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, 100, 101));
        _enter(10, address(target), 101);

        _enter(10, address(target), 100);
        assertEq(usdc.balanceOf(address(parent)), 100, "received the paid amount");
    }

    function testShouldRevertInTransientModeWhenReceivedAssetsAreBelowMinAssetsOut() external {
        // given
        uint256 expected = _measureRedeemedAssets(shares);
        _setTransientInputs(shares, address(vault), expected + 1);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, expected, expected + 1));
        parent.execute(address(fuse), abi.encodeWithSignature("enterTransient()"));
    }

    function testShouldRedeemInTransientModeWithNonZeroMinAssetsOut() external {
        // given
        uint256 expected = _measureRedeemedAssets(shares);
        _setTransientInputs(shares, address(vault), expected);

        // when
        parent.execute(address(fuse), abi.encodeWithSignature("enterTransient()"));

        // then
        assertEq(vault.balanceOf(address(parent)), 0, "shares redeemed");
        assertEq(usdc.balanceOf(address(parent)), expected, "assets received");
        bytes32[] memory outputs = parent.getOutputs(address(fuse));
        assertEq(TypeConversionLib.toAddress(outputs[0]), address(vault), "output vault");
        assertEq(TypeConversionLib.toUint256(outputs[1]), shares, "output shares");
    }

    function testShouldRedeemInTransientModeWithZeroMinAssetsOut() external {
        // given
        _setTransientInputs(shares, address(vault), 0);

        // when
        parent.execute(address(fuse), abi.encodeWithSignature("enterTransient()"));

        // then
        assertEq(vault.balanceOf(address(parent)), 0, "shares redeemed");
    }

    function _enter(uint256 sharesAmount_, address target_, uint256 minAssetsOut_) private {
        parent.execute(
            address(fuse),
            abi.encodeWithSignature(
                ENTER_SIGNATURE,
                EnterDataWithMin({sharesAmount: sharesAmount_, plasmaVault: target_, minAssetsOut: minAssetsOut_})
            )
        );
    }

    function _setTransientInputs(uint256 sharesAmount_, address target_, uint256 minAssetsOut_) private {
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(sharesAmount_);
        inputs[1] = TypeConversionLib.toBytes32(target_);
        inputs[2] = TypeConversionLib.toBytes32(minAssetsOut_);
        parent.setInputs(address(fuse), inputs);
    }

    /// @dev Assets paid by a redeem of `sharesAmount_`, measured on a snapshot that is reverted afterwards
    function _measureRedeemedAssets(uint256 sharesAmount_) private returns (uint256 received) {
        uint256 snapshot = vm.snapshotState();
        uint256 before = usdc.balanceOf(address(parent));
        _enter(sharesAmount_, address(vault), 0);
        received = usdc.balanceOf(address(parent)) - before;
        vm.revertToState(snapshot);
    }
}

struct EnterLegacy {
    uint256 sharesAmount;
    address plasmaVault;
}
