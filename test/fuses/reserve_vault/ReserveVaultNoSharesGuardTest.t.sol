// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {ReserveVaultSupplyFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultSupplyFuse.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev Both `ReserveVaultSupplyFuseNoShares` guards of the exit, reached through real clones and `C.execute`. The two
///      error arguments tell the sites apart: the start check reports the principal before the exit, the
///      post-condition reports the principal that the exit would leave behind.
contract ReserveVaultNoSharesGuardTest is ReserveVaultTestBase {
    struct Snapshot {
        uint256 principal;
        uint256 boost;
        uint256 sharesOfCInA;
        uint256 supplyA;
        uint256 assetsA;
        uint256 usdcA;
        uint256 usdcC;
        uint256 supplyC;
        uint256 assetsC;
    }

    function testShouldPinReserveVaultMarketIds() public pure {
        assertEq(IporFusionMarkets.RESERVE_VAULT, 61, "reserve vault market id");
        assertEq(IporFusionMarkets.RESERVE_VAULT_BOOST, 62, "reserve vault boost market id");
    }

    /// @dev Start check: C's shares of A leave through the standard ERC4626 fuse, the recorded principal stays
    function testShouldRevertExitWhenReserveVaultHoldsNoSharesAtStart() public {
        // given: C lent PRINCIPAL to A and then pulled every A share out through the standard ERC4626 market
        _setUpPrincipalInA();
        address[] memory memberSubstrate = new address[](1);
        memberSubstrate[0] = address(vaultA);
        _addFuse(vaultC, address(erc4626SupplyFuse));
        _addMarket(vaultC, ERC4626_MARKET, address(erc4626BalanceFuse), _toSubstrates(memberSubstrate));
        _execute(
            vaultC,
            address(erc4626SupplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.exit, (Erc4626SupplyFuseExitData(address(vaultA), PRINCIPAL, 0, 0)))
        );

        assertEq(vaultA.balanceOf(address(vaultC)), 0, "C holds no A shares");
        assertEq(_principal(vaultA), PRINCIPAL, "principal still recorded");
        Snapshot memory before_ = _snapshot();

        // when: C asks the reserve fuse to exit
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseNoShares.selector,
                address(vaultA),
                PRINCIPAL
            )
        );
        _reserveExit(vaultA, 1);

        // then: the start check fired (principal before the exit) and nothing moved
        _assertSame(before_, "start check");
    }

    /// @dev Post-condition: C holds a single share of A, a partial exit rounds its burn up to that share
    function testShouldRevertPartialExitThatWouldBurnLastShareAndLeavePrincipal() public {
        // given: A has 100 shares for 1 asset-wei, then a donation lifts its assets to 199_999_999
        uint256 principal = 1_000_000;
        _userDeposit(1);
        _gain(vaultA, 199_999_998);
        assertEq(vaultA.totalAssets(), 199_999_999, "A assets after donation");

        // and: C lends 1_000_000 and receives exactly one share-wei of A
        _fundC(principal);
        _reserveEnter(vaultA, principal);
        assertEq(vaultA.balanceOf(address(vaultC)), 1, "C holds one share of A");
        assertEq(_principal(vaultA), principal, "principal recorded");
        Snapshot memory before_ = _snapshot();

        // when: C withdraws 999_999, the withdrawal burns the only share and leaves principal 1
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseNoShares.selector,
                address(vaultA),
                uint256(1)
            )
        );
        _reserveExit(vaultA, principal - 1);

        // then: the post-condition fired (principal after the exit) and the whole exit was undone
        _assertSame(before_, "post-condition");

        // and: the same position can still leave with a full exit
        _reserveExit(vaultA, principal);
        assertEq(_principal(vaultA), 0, "principal cleared by the full exit");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "no A shares left after the full exit");
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.principal = _principal(vaultA);
        s.boost = _boost(vaultA);
        s.sharesOfCInA = vaultA.balanceOf(address(vaultC));
        s.supplyA = vaultA.totalSupply();
        s.assetsA = vaultA.totalAssets();
        s.usdcA = usdc.balanceOf(address(vaultA));
        s.usdcC = usdc.balanceOf(address(vaultC));
        s.supplyC = vaultC.totalSupply();
        s.assetsC = vaultC.totalAssets();
    }

    function _assertSame(Snapshot memory before_, string memory label_) internal view {
        Snapshot memory after_ = _snapshot();
        assertEq(after_.principal, before_.principal, string.concat(label_, ": principal"));
        assertEq(after_.boost, before_.boost, string.concat(label_, ": boost"));
        assertEq(after_.sharesOfCInA, before_.sharesOfCInA, string.concat(label_, ": C shares in A"));
        assertEq(after_.supplyA, before_.supplyA, string.concat(label_, ": A supply"));
        assertEq(after_.assetsA, before_.assetsA, string.concat(label_, ": A assets"));
        assertEq(after_.usdcA, before_.usdcA, string.concat(label_, ": A idle"));
        assertEq(after_.usdcC, before_.usdcC, string.concat(label_, ": C idle"));
        assertEq(after_.supplyC, before_.supplyC, string.concat(label_, ": C supply"));
        assertEq(after_.assetsC, before_.assetsC, string.concat(label_, ": C assets"));
    }
}
