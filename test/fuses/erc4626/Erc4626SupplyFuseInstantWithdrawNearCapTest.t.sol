// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";

/// @dev Models a nested PlasmaVault with a pending performance fee: `maxWithdraw` reports the pre-fee value, while
///      `withdraw` (which crystallizes the fee first) and `redeem` are paid net of the fee. A `withdraw` above the
///      net value reverts with `ERC4626ExceededMaxWithdraw`, `redeem` of the same shares succeeds.
contract PendingFeeVault is ERC4626 {
    using Math for uint256;

    uint256 public immutable FEE_BPS;
    bool public redeemReverts;

    constructor(IERC20 asset_, uint256 feeBps_) ERC4626(asset_) ERC20("Pending Fee Vault", "pfVLT") {
        FEE_BPS = feeBps_;
    }

    function setRedeemReverts(bool value_) external {
        redeemReverts = value_;
    }

    function previewRedeem(uint256 shares_) public view override returns (uint256) {
        return super.previewRedeem(shares_).mulDiv(10_000 - FEE_BPS, 10_000, Math.Rounding.Floor);
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) public override returns (uint256) {
        uint256 netMax = previewRedeem(balanceOf(owner_));
        if (assets_ > netMax) {
            revert ERC4626ExceededMaxWithdraw(owner_, assets_, netMax);
        }
        return super.withdraw(assets_, receiver_, owner_);
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        require(!redeemReverts, "redeem disabled");
        return super.redeem(shares_, receiver_, owner_);
    }
}

/// @notice IL-9643: in `instantWithdraw` a request just below the cap fails on `withdraw` when a nested PlasmaVault
///         crystallizes a pending fee; the fuse retries through `redeem` instead of skipping the market.
contract Erc4626SupplyFuseInstantWithdrawNearCapTest is Test {
    uint256 private constant MARKET_ID = 1;
    uint256 private constant DEPOSIT_AMOUNT = 1_000e18;
    uint256 private constant FEE_BPS = 100; // 1%

    MockERC20 private underlyingToken;
    PendingFeeVault private pendingFeeVault;
    Erc4626SupplyFuse private fuse;
    PlasmaVaultMock private vaultMock;

    function setUp() public {
        underlyingToken = new MockERC20("Mock Token", "MTK", 18);
        pendingFeeVault = new PendingFeeVault(underlyingToken, FEE_BPS);
        fuse = new Erc4626SupplyFuse(MARKET_ID);
        vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory assets = new address[](1);
        assets[0] = address(pendingFeeVault);
        vaultMock.grantAssetsToMarket(MARKET_ID, assets);

        underlyingToken.mint(address(vaultMock), DEPOSIT_AMOUNT);
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({
                vault: address(pendingFeeVault),
                vaultAssetAmount: DEPOSIT_AMOUNT,
                minSharesOut: 0
            })
        );
    }

    function testShouldPayThroughRedeemWhenInstantWithdrawJustBelowCapFailsOnWithdraw() external {
        // given - the cap is the pre-fee value, the request is 1 wei below it
        uint256 requested = pendingFeeVault.maxWithdraw(address(vaultMock)) - 1;
        assertEq(requested, DEPOSIT_AMOUNT - 1, "request just below the cap");
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));
        uint256 sharesBefore = pendingFeeVault.balanceOf(address(vaultMock));
        uint256 expectedShares = pendingFeeVault.previewWithdraw(requested);
        uint256 expectedAssets = pendingFeeVault.previewRedeem(expectedShares);

        // when
        vaultMock.instantWithdraw(_params(requested));

        // then - the position paid net of the fee instead of nothing
        uint256 received = underlyingToken.balanceOf(address(vaultMock)) - balanceBefore;
        assertEq(received, expectedAssets, "assets received through redeem");
        assertGt(received, 0, "something was paid");
        assertLt(received, requested, "payout is below the request by the fee share");
        assertEq(sharesBefore - pendingFeeVault.balanceOf(address(vaultMock)), expectedShares, "shares burned");
    }

    function testShouldEmitExitAndNoExitFailedWhenRetryThroughRedeemSucceeds() external {
        // given
        uint256 requested = DEPOSIT_AMOUNT - 1;
        uint256 expectedShares = pendingFeeVault.previewWithdraw(requested);
        uint256 expectedAssets = pendingFeeVault.previewRedeem(expectedShares);

        // when
        vm.recordLogs();
        vaultMock.instantWithdraw(_params(requested));

        // then
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 exitTopic = keccak256("Erc4626SupplyFuseExit(address,address,address,uint256,uint256)");
        bytes32 failedTopic = keccak256("Erc4626SupplyFuseExitFailed(address,address,address,uint256)");
        bool exitSeen;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != failedTopic, "no ExitFailed");
            if (logs[i].topics[0] == exitTopic) {
                exitSeen = true;
                (, , , uint256 assets, uint256 shares) = abi.decode(
                    logs[i].data,
                    (address, address, address, uint256, uint256)
                );
                assertEq(assets, expectedAssets, "event assets");
                assertEq(shares, expectedShares, "event shares");
            }
        }
        assertTrue(exitSeen, "Exit emitted");
    }

    function testShouldEmitExitFailedWhenRedeemRetryFailsToo() external {
        // given
        pendingFeeVault.setRedeemReverts(true);
        uint256 requested = DEPOSIT_AMOUNT - 1;
        uint256 sharesBefore = pendingFeeVault.balanceOf(address(vaultMock));

        // when
        vm.expectEmit(false, false, false, true, address(vaultMock));
        emit Erc4626SupplyFuse.Erc4626SupplyFuseExitFailed(
            address(fuse),
            address(underlyingToken),
            address(pendingFeeVault),
            requested
        );
        vaultMock.instantWithdraw(_params(requested));

        // then
        assertEq(pendingFeeVault.balanceOf(address(vaultMock)), sharesBefore, "no shares burned");
    }

    function testShouldKeepPartialWithdrawWhenItSucceeds() external {
        // given - well below the net value, withdraw succeeds and pays exactly the request
        uint256 requested = 100e18;
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when
        vaultMock.instantWithdraw(_params(requested));

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, requested, "exact amount");
    }

    function _params(uint256 amount_) private view returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(amount_);
        params[1] = bytes32(uint256(uint160(address(pendingFeeVault))));
    }
}
