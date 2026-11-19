// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultMockMarketsTestBase} from "../vaults/PlasmaVaultMockMarketsTestBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";

/// @title PlasmaVaultLibStaleEntriesRedeemTest
/// @notice Olympix scan 2026-11-06, finding 5.2.26 (IL-9657, L26): a vault that still holds instant-withdrawal params
///         left by an older build under a key that is no longer listed appended the new params to the stale ones when
///         the key was reused, so the instant withdraw read a stale substrate and a user redeem that has to pull from
///         the market reverted. IL-9467 resets the key before the write. This test pins the whole redeem path after
///         the reconfiguration, on a locally built vault with real ERC-4626 markets and no fork.
/// @dev The stale entry is planted with `vm.store` under the key (supplyFuseB, 1), the way an older build left it:
///      the vault is first reconfigured to the list [A], which deletes the key of B, then the leftover is written.
contract PlasmaVaultLibStaleEntriesRedeemTest is PlasmaVaultMockMarketsTestBase {
    /// @dev CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS of PlasmaVaultStorageLib
    bytes32 private constant INSTANT_WITHDRAWAL_FUSES_PARAMS_SLOT =
        0x45a704819a9dcb1bb5b8cff129eda642cf0e926a9ef104e27aa53f1d1fa47b00;
    /// @dev a vault that is not a substrate of market B (the revoked substrate of the finding)
    address private constant REVOKED_VAULT = address(0xDEAD0001);

    uint256 internal constant USER_DEPOSIT = 1_000e6;
    uint256 internal constant OTHER_DEPOSIT = 9_000e6;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function testShouldRedeemFromMarketAfterReconfigurationReusedStaleKey() public {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT);
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "premise: no idle cash, the redeem must pull from market B");

        // the current list is only [A]; the leftover of an older build sits under the unlisted key (B, 1)
        _configure(_listA());
        _plantStaleParams(address(supplyFuseB), 1);

        // the new write reuses the key (B, 1)
        _configure(_listAB());

        uint256 shares = plasmaVault.balanceOf(user) / 2;
        uint256 expected = plasmaVault.previewRedeem(shares);
        uint256 before = asset.balanceOf(user);

        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        assertGt(assets, 0, "assets redeemed from market B");
        assertEq(asset.balanceOf(user) - before, assets, "user received the assets");
        assertApproxEqAbs(assets, expected, 2, "payout matches the preview");
    }

    /// @dev The write replaces the leftover instead of appending to it
    function testShouldReplaceStaleParamsWhenReconfigurationReusesKey() public {
        _configure(_listA());
        _plantStaleParams(address(supplyFuseB), 1);

        _configure(_listAB());

        bytes32[] memory paramsB = PlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFusesParams(
            address(supplyFuseB),
            1
        );
        assertEq(paramsB.length, 2, "stale params must not remain after the key is reused");
        assertEq(paramsB[1], PlasmaVaultConfigLib.addressToBytes32(address(marketB)), "market B substrate");
    }

    /// @dev Control: the same flow without a leftover, so the stale-key case above is the only difference
    function testShouldRedeemFromMarketAfterReconfigurationWithoutStaleKey() public {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, OTHER_DEPOSIT);
        _allocate(address(marketB), USER_DEPOSIT + OTHER_DEPOSIT);

        _configure(_listA());
        _configure(_listAB());

        uint256 shares = plasmaVault.balanceOf(user) / 2;
        vm.prank(user);
        uint256 assets = plasmaVault.redeem(shares, user, user);

        assertGt(assets, 0, "assets redeemed from market B");
    }

    function _configure(InstantWithdrawalFusesParamsStruct[] memory list_) private {
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(list_);
    }

    function _listA() private view returns (InstantWithdrawalFusesParamsStruct[] memory list) {
        list = new InstantWithdrawalFusesParamsStruct[](1);
        list[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuseA), params: _params(address(marketA))});
    }

    function _listAB() private view returns (InstantWithdrawalFusesParamsStruct[] memory list) {
        list = new InstantWithdrawalFusesParamsStruct[](2);
        list[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuseA), params: _params(address(marketA))});
        list[1] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuseB), params: _params(address(marketB))});
    }

    /// @dev [amount placeholder, vault substrate], the layout read by Erc4626SupplyFuse.instantWithdraw
    function _params(address market_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(market_);
    }

    /// @dev Plants [0, REVOKED_VAULT] under the key (fuse_, index_)
    function _plantStaleParams(address fuse_, uint256 index_) private {
        bytes32 arraySlot = keccak256(
            abi.encode(keccak256(abi.encodePacked(fuse_, index_)), INSTANT_WITHDRAWAL_FUSES_PARAMS_SLOT)
        );
        vm.store(address(plasmaVault), arraySlot, bytes32(uint256(2)));
        bytes32 dataSlot = keccak256(abi.encode(arraySlot));
        vm.store(address(plasmaVault), dataSlot, bytes32(uint256(0)));
        vm.store(
            address(plasmaVault),
            bytes32(uint256(dataSlot) + 1),
            PlasmaVaultConfigLib.addressToBytes32(REVOKED_VAULT)
        );
    }
}
