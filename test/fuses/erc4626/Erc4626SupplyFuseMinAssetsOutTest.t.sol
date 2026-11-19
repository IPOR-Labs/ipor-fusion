// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockERC4626WithFee} from "../../test_helpers/MockERC4626WithFee.sol";

/// @dev Vault whose `redeem` reports twice the assets it actually paid out
contract LyingRedeemVault is MockERC4626WithFee {
    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint256 feeBps_
    ) MockERC4626WithFee(asset_, name_, symbol_, feeBps_) {}

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        return super.redeem(shares_, receiver_, owner_) * 2;
    }
}

/// @notice Tests of `minAssetsOut` of `Erc4626SupplyFuseExitData` (IL-9619): the full exit (`redeem` branch) reverts
///         when the Plasma Vault receives less than the minimum; 0 disables the check; the partial exit is unchanged.
/// @dev The exit is encoded by signature so that this file compiles against the pre-IL-9619 fuse too.
contract Erc4626SupplyFuseMinAssetsOutTest is Test {
    uint256 private constant MARKET_ID = 1;
    uint256 private constant DEPOSIT_AMOUNT = 1_000e18;
    uint256 private constant FEE_BPS = 500; // 5%, a full exit of 1_000e18 pays 950e18
    uint256 private constant NET_ASSETS = 950e18;
    /// @dev Selector from the signature so that this file compiles against the pre-IL-9619 fuse
    bytes4 private constant INSUFFICIENT_ASSETS_SELECTOR =
        bytes4(keccak256("Erc4626SupplyFuseInsufficientAssets(uint256,uint256)"));
    string private constant EXIT_SIGNATURE = "exit((address,uint256,uint256,uint256))";

    MockERC20 private underlyingToken;
    MockERC4626WithFee private feeVault;
    LyingRedeemVault private lyingVault;
    Erc4626SupplyFuse private fuse;
    PlasmaVaultMock private vaultMock;

    function setUp() public {
        underlyingToken = new MockERC20("Mock Token", "MTK", 18);
        feeVault = new MockERC4626WithFee(underlyingToken, "Fee Vault", "fVLT", FEE_BPS);
        lyingVault = new LyingRedeemVault(underlyingToken, "Lying Vault", "lVLT", FEE_BPS);
        fuse = new Erc4626SupplyFuse(MARKET_ID);
        vaultMock = new PlasmaVaultMock(address(fuse), address(fuse));

        address[] memory assets = new address[](2);
        assets[0] = address(feeVault);
        assets[1] = address(lyingVault);
        vaultMock.grantAssetsToMarket(MARKET_ID, assets);

        _deposit(address(feeVault));
        _deposit(address(lyingVault));
    }

    function testShouldHaveExpectedExitSelectorAndErrorSelector() external pure {
        assertEq(Erc4626SupplyFuse.exit.selector, bytes4(0x73ed602f), "exit selector");
        assertEq(INSUFFICIENT_ASSETS_SELECTOR, bytes4(0x18fd350a), "insufficient assets error selector");
    }

    function testShouldRevertWhenFullExitReceivesLessThanMinAssetsOut() external {
        // given
        uint256 minAssetsOut = NET_ASSETS + 1;
        uint256 shares = feeVault.balanceOf(address(vaultMock));

        // when
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, NET_ASSETS, minAssetsOut));
        _exit(address(feeVault), type(uint256).max, 0, minAssetsOut);

        // then
        assertEq(feeVault.balanceOf(address(vaultMock)), shares, "the revert undoes the redeem");
    }

    function testShouldFullyExitWhenReceivedAssetsEqualMinAssetsOut() external {
        // given
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when
        _exit(address(feeVault), type(uint256).max, 0, NET_ASSETS);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, NET_ASSETS, "assets received");
        assertEq(feeVault.balanceOf(address(vaultMock)), 0, "all shares redeemed");
    }

    function testShouldFullyExitWithoutMinimumAndWithoutExtraBalanceReadWhenMinAssetsOutIsZero() external {
        // given
        vm.expectCall(address(underlyingToken), abi.encodeCall(IERC20.balanceOf, (address(vaultMock))), 0);

        // when
        _exit(address(feeVault), type(uint256).max, 0, 0);

        // then - no balance read of the underlying was made (checked by expectCall); the position is fully redeemed
        assertEq(feeVault.balanceOf(address(vaultMock)), 0, "all shares redeemed");
    }

    function testShouldIgnoreMinAssetsOutOnPartialExit() external {
        // given
        uint256 requested = 100e18;
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));

        // when - a minimum far above the payout does not apply to the withdraw branch
        _exit(address(feeVault), requested, 0, type(uint256).max);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, requested, "requested assets received");
    }

    function testShouldMeasureReceivedAssetsInsteadOfTrustingRedeemReturnValue() external {
        // given - redeem reports 2 * 950e18 but pays 950e18
        uint256 minAssetsOut = 2 * NET_ASSETS;

        // when
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, NET_ASSETS, minAssetsOut));
        _exit(address(lyingVault), type(uint256).max, 0, minAssetsOut);
    }

    function testShouldStillEnforceMaxSharesBurnedOnFullExitWithMinAssetsOut() external {
        // given
        uint256 shares = feeVault.balanceOf(address(vaultMock));

        // when
        vm.expectRevert(
            abi.encodeWithSelector(
                Erc4626SupplyFuse.Erc4626SupplyFuseExcessiveSharesBurned.selector,
                shares,
                shares - 1
            )
        );
        _exit(address(feeVault), type(uint256).max, shares - 1, NET_ASSETS);
    }

    function testShouldRevertOnExitTransientWhenReceivedAssetsAreBelowMinAssetsOut() external {
        // given
        uint256 minAssetsOut = NET_ASSETS + 1;
        vaultMock.setInputs(address(fuse), _exitInputs(address(feeVault), type(uint256).max, 0, minAssetsOut));

        // when
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ASSETS_SELECTOR, NET_ASSETS, minAssetsOut));
        vaultMock.exitErc4626SupplyTransient();
    }

    function testShouldExitTransientWhenReceivedAssetsMeetNonZeroMinAssetsOut() external {
        // given
        uint256 shares = feeVault.balanceOf(address(vaultMock));
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));
        vaultMock.setInputs(address(fuse), _exitInputs(address(feeVault), type(uint256).max, 0, NET_ASSETS));

        // when
        vaultMock.exitErc4626SupplyTransient();

        // then
        bytes32[] memory outputs = vaultMock.getOutputs(address(fuse));
        assertEq(TypeConversionLib.toUint256(outputs[0]), shares, "output is the burned shares");
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, NET_ASSETS, "assets received");
    }

    function testShouldNotApplyMinAssetsOutOnInstantWithdraw() external {
        // given
        uint256 balanceBefore = underlyingToken.balanceOf(address(vaultMock));
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(type(uint256).max);
        params[1] = bytes32(uint256(uint160(address(feeVault))));

        // when
        vaultMock.instantWithdraw(params);

        // then
        assertEq(underlyingToken.balanceOf(address(vaultMock)) - balanceBefore, NET_ASSETS, "assets received");
    }

    function _exit(address vault_, uint256 amount_, uint256 maxSharesBurned_, uint256 minAssetsOut_) private {
        (bool success, bytes memory returndata) = address(vaultMock).call(
            abi.encodeWithSignature(EXIT_SIGNATURE, vault_, amount_, maxSharesBurned_, minAssetsOut_)
        );
        if (!success) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }
    }

    function _exitInputs(
        address vault_,
        uint256 amount_,
        uint256 maxSharesBurned_,
        uint256 minAssetsOut_
    ) private pure returns (bytes32[] memory inputs) {
        inputs = new bytes32[](4);
        inputs[0] = TypeConversionLib.toBytes32(vault_);
        inputs[1] = TypeConversionLib.toBytes32(amount_);
        inputs[2] = TypeConversionLib.toBytes32(maxSharesBurned_);
        inputs[3] = TypeConversionLib.toBytes32(minAssetsOut_);
    }

    function _deposit(address vault_) private {
        underlyingToken.mint(address(vaultMock), DEPOSIT_AMOUNT);
        vaultMock.enterErc4626Supply(
            Erc4626SupplyFuseEnterData({vault: vault_, vaultAssetAmount: DEPOSIT_AMOUNT, minSharesOut: 0})
        );
    }
}
