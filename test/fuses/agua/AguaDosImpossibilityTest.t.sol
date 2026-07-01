// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AguaSupplyFuse} from "../../../contracts/fuses/agua/AguaSupplyFuse.sol";
import {AguaRequestRedemptionFuse} from "../../../contracts/fuses/agua/AguaRequestRedemptionFuse.sol";
import {AguaClaimRedemptionFuse} from "../../../contracts/fuses/agua/AguaClaimRedemptionFuse.sol";
import {AguaRedeemEarlyFuse} from "../../../contracts/fuses/agua/AguaRedeemEarlyFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

/// @title AguaDosImpossibilityTest
/// @notice Structural guarantee: no Agua fuse exposes `instantWithdraw(bytes32[])`, so a
///         PlasmaVault.withdraw can never route an instant-withdraw through Agua (redemption DoS
///         impossible). Exits are async-only via the redemption fuse set.
contract AguaDosImpossibilityTest is Test {
    uint256 public constant MARKET_ID = IporFusionMarkets.AGUA_GLOBAL_CARRY;

    AguaSupplyFuse public supplyFuse;
    AguaRequestRedemptionFuse public requestFuse;
    AguaClaimRedemptionFuse public claimFuse;
    AguaRedeemEarlyFuse public redeemEarlyFuse;

    function setUp() public {
        supplyFuse = new AguaSupplyFuse(MARKET_ID);
        requestFuse = new AguaRequestRedemptionFuse(MARKET_ID);
        claimFuse = new AguaClaimRedemptionFuse(MARKET_ID);
        redeemEarlyFuse = new AguaRedeemEarlyFuse(MARKET_ID);
    }

    function _assertNoInstantWithdraw(address fuse_, string memory name_) internal {
        (bool success, ) = fuse_.call(abi.encodeWithSignature("instantWithdraw(bytes32[])", new bytes32[](0)));
        assertFalse(success, name_);
    }

    function testRedemptionDosImpossibleSupplyFuse() public {
        _assertNoInstantWithdraw(address(supplyFuse), "AguaSupplyFuse must NOT expose instantWithdraw(bytes32[])");
    }

    function testRedemptionDosImpossibleRequestFuse() public {
        _assertNoInstantWithdraw(
            address(requestFuse),
            "AguaRequestRedemptionFuse must NOT expose instantWithdraw(bytes32[])"
        );
    }

    function testRedemptionDosImpossibleClaimFuse() public {
        _assertNoInstantWithdraw(
            address(claimFuse),
            "AguaClaimRedemptionFuse must NOT expose instantWithdraw(bytes32[])"
        );
    }

    function testRedemptionDosImpossibleRedeemEarlyFuse() public {
        _assertNoInstantWithdraw(
            address(redeemEarlyFuse),
            "AguaRedeemEarlyFuse must NOT expose instantWithdraw(bytes32[])"
        );
    }
}
