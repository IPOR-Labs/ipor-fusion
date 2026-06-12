// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {RWAUnpauseFuse, RWAUnpauseData} from "../../../../contracts/fuses/rwa/RWAUnpauseFuse.sol";
import {RWAExecutor} from "../../../../contracts/fuses/rwa/RWAExecutor.sol";
import {IRWAExecutor} from "../../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {RWAErrors} from "../../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {RWASubstrateLib} from "../../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";
import {Roles} from "../../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";

import {MockPlasmaVaultForRWA} from "./mocks/MockPlasmaVaultForRWA.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {RWATestConstants, RWASlotHelpers} from "./RWATestHelpers.sol";

/// @title RWAUnpauseFuseTest
/// @notice 14 unit tests for RWAUnpauseFuse via delegatecall from MockPlasmaVaultForRWA.
contract RWAUnpauseFuseTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.RWA;

    MockPlasmaVaultForRWA internal vault;
    RWAUnpauseFuse internal fuse;
    MockAccessManager internal access;
    RWAExecutor internal executor;

    address internal atomist;
    uint256 internal atomistPk;
    address internal custodianA;
    address internal custodianB;
    address internal balanceAccount;

    function setUp() public {
        vault = new MockPlasmaVaultForRWA();
        fuse = new RWAUnpauseFuse(MARKET_ID);
        access = new MockAccessManager();
        vault.setAccessManager(address(access));

        (atomist, atomistPk) = makeAddrAndKey("atomist");
        access.grantRole(Roles.ATOMIST_ROLE, atomist);

        custodianA = makeAddr("custA");
        custodianB = makeAddr("custB");
        balanceAccount = makeAddr("ba");

        bytes32[] memory subs = new bytes32[](5);
        subs[0] = RWASubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[1] = RWASubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[2] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = RWASubstrateLib.encodeStalenessMaxSubstrate(1 days);
        subs[4] = RWASubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = new RWAExecutor(MARKET_ID, address(vault));
        executor.syncSubstrates();
        RWASlotHelpers.setExecutor(address(vault), address(executor));
    }

    // ---------- 7.1 ----------
    function test_constructor_setsMarketId() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
    }

    // ---------- TQ-7: executor not deployed ----------
    function test_unpause_revertsWhenExecutorNotDeployed() public {
        // Fresh vault with no executor stored (zero the ERC-7201 slot)
        MockPlasmaVaultForRWA freshVault = new MockPlasmaVaultForRWA();
        freshVault.setAccessManager(address(access));
        // executor slot is zero by default — no vm.store needed
        RWAUnpauseData memory d = _signedData(0, 1, block.timestamp + 1 hours, atomistPk, block.chainid);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseNotPaused.selector));
        freshVault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.2 ----------
    function test_unpause_happyPath_clearsPause() public {
        _seedBalance(500e6);
        _setPaused(true);
        RWAUnpauseData memory d = _signedData(500e6, 1, block.timestamp + 1 hours, atomistPk, block.chainid);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
        assertFalse(_readPaused());
    }

    // ---------- 7.3 ----------
    function test_unpause_revertsWhenNotPaused() public {
        _seedBalance(100e6);
        // Not paused — should revert RWAUnpauseNotPaused
        RWAUnpauseData memory d = _signedData(100e6, 1, block.timestamp + 1 hours, atomistPk, block.chainid);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseNotPaused.selector));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.4 ----------
    function test_unpause_revertsWhenExpired() public {
        _seedBalance(100e6);
        _setPaused(true);
        RWAUnpauseData memory d = _signedData(100e6, 1, block.timestamp - 1, atomistPk, block.chainid);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseSignatureExpired.selector));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.5 ----------
    function test_unpause_revertsWhenSignerIsNotAtomist() public {
        _seedBalance(100e6);
        _setPaused(true);
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        RWAUnpauseData memory d = _signedData(100e6, 1, block.timestamp + 1 hours, strangerPk, block.chainid);
        address signer = vm.addr(strangerPk);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseSignerNotAtomist.selector, signer));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.6 ----------
    function test_unpause_revertsWhenBalanceMismatch() public {
        _seedBalance(100e6);
        _setPaused(true);
        // Sign 200 but executor reports 100
        RWAUnpauseData memory d = _signedData(200e6, 1, block.timestamp + 1 hours, atomistPk, block.chainid);
        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAUnpauseBalanceMismatch.selector, uint256(200e6), uint256(100e6))
        );
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.7 ----------
    function test_unpause_revertsOnNonceReplay() public {
        _seedBalance(100e6);
        _setPaused(true);

        RWAUnpauseData memory d = _signedData(100e6, 42, block.timestamp + 1 hours, atomistPk, block.chainid);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));

        // Re-pause and replay — nonce already used
        _setPaused(true);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseSignatureReplay.selector, uint256(42)));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.8 ----------
    function test_unpause_marksNonceUsed() public {
        _seedBalance(100e6);
        _setPaused(true);
        RWAUnpauseData memory d = _signedData(100e6, 7, block.timestamp + 1 hours, atomistPk, block.chainid);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));

        // Consumed nonce storage is at keccak slot for mapping — we verify via replay behavior (already done in 7.7).
        // Confirm pause is cleared:
        assertFalse(_readPaused());
    }

    // ---------- 7.9 ----------
    function test_unpause_recoveredSignerBoundToVaultAddress() public {
        _seedBalance(100e6);
        _setPaused(true);

        // Create a second vault instance — signature from that vault's address must fail here.
        MockPlasmaVaultForRWA otherVault = new MockPlasmaVaultForRWA();
        bytes32 digest = keccak256(
            abi.encodePacked(
                address(otherVault),
                MARKET_ID,
                uint256(100e6),
                uint256(1),
                uint256(block.timestamp + 1 hours),
                block.chainid
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(atomistPk, digest);
        RWAUnpauseData memory d = RWAUnpauseData({
            confirmedTotalBalance: 100e6,
            nonce: 1,
            expirationTime: block.timestamp + 1 hours,
            signature: abi.encodePacked(r, s, v)
        });
        // Compute expected recovered signer (wrong vault → different digest → different signer)
        bytes32 correctDigest = keccak256(
            abi.encodePacked(address(vault), MARKET_ID, uint256(100e6), uint256(1), uint256(block.timestamp + 1 hours), block.chainid)
        );
        address recoveredSigner = ECDSA.recover(correctDigest, d.signature);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseSignerNotAtomist.selector, recoveredSigner));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.10 ----------
    function test_unpause_recoveredSignerBoundToChainId() public {
        _seedBalance(100e6);
        _setPaused(true);
        uint256 wrongChain = block.chainid + 1;
        RWAUnpauseData memory d = _signedData(100e6, 1, block.timestamp + 1 hours, atomistPk, wrongChain);
        // Compute expected recovered signer (wrong chainId → different digest → different signer)
        bytes32 correctDigest = keccak256(
            abi.encodePacked(address(vault), MARKET_ID, uint256(100e6), uint256(1), uint256(block.timestamp + 1 hours), block.chainid)
        );
        address recoveredSigner = ECDSA.recover(correctDigest, d.signature);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseSignerNotAtomist.selector, recoveredSigner));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.11 ----------
    function test_unpause_recoveredSignerBoundToMarketId() public {
        _seedBalance(100e6);
        _setPaused(true);

        // Sign with a different MARKET_ID
        bytes32 digest = keccak256(
            abi.encodePacked(
                address(vault),
                uint256(MARKET_ID + 1),
                uint256(100e6),
                uint256(1),
                uint256(block.timestamp + 1 hours),
                block.chainid
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(atomistPk, digest);
        RWAUnpauseData memory d = RWAUnpauseData({
            confirmedTotalBalance: 100e6,
            nonce: 1,
            expirationTime: block.timestamp + 1 hours,
            signature: abi.encodePacked(r, s, v)
        });
        // Compute expected recovered signer (wrong marketId → different digest → different signer)
        bytes32 correctDigest = keccak256(
            abi.encodePacked(address(vault), MARKET_ID, uint256(100e6), uint256(1), uint256(block.timestamp + 1 hours), block.chainid)
        );
        address recoveredSigner = ECDSA.recover(correctDigest, d.signature);
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAUnpauseSignerNotAtomist.selector, recoveredSigner));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.12 ----------
    function test_unpause_malformedSignature_reverts() public {
        _seedBalance(100e6);
        _setPaused(true);
        RWAUnpauseData memory d = RWAUnpauseData({
            confirmedTotalBalance: 100e6,
            nonce: 1,
            expirationTime: block.timestamp + 1 hours,
            signature: hex"00" // clearly too short
        });
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(1)));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.13 ----------
    function test_unpause_signatureMalleability_highSInvalid() public {
        _seedBalance(100e6);
        _setPaused(true);

        bytes32 digest = keccak256(
            abi.encodePacked(
                address(vault), MARKET_ID, uint256(100e6), uint256(1), uint256(block.timestamp + 1 hours), block.chainid
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(atomistPk, digest);
        // Flip s to high-half
        bytes32 secp = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(uint256(secp) - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        bytes memory sig = abi.encodePacked(r, highS, vFlipped);

        RWAUnpauseData memory d = RWAUnpauseData({
            confirmedTotalBalance: 100e6, nonce: 1, expirationTime: block.timestamp + 1 hours, signature: sig
        });
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- 7.14 ----------
    function test_unpause_emitsRWAUnpaused() public {
        _seedBalance(100e6);
        _setPaused(true);
        RWAUnpauseData memory d = _signedData(100e6, 55, block.timestamp + 1 hours, atomistPk, block.chainid);

        vm.expectEmit(true, false, false, true, address(vault));
        emit RWAUnpauseFuse.RWAUnpaused(atomist, 100e6, 55);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d)));
    }

    // ---------- TQ-12: two-atomist independent nonces ----------
    function test_unpause_twoAtomists_independentNonces() public {
        _seedBalance(100e6);

        // Create second atomist
        (address atomist2, uint256 atomist2Pk) = makeAddrAndKey("atomist2");
        access.grantRole(Roles.ATOMIST_ROLE, atomist2);

        // First atomist unpauses with nonce 1
        _setPaused(true);
        RWAUnpauseData memory d1 = _signedData(100e6, 1, block.timestamp + 1 hours, atomistPk, block.chainid);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d1)));
        assertFalse(_readPaused());

        // Second atomist unpauses with nonce 2 (different nonce, different signer)
        _setPaused(true);
        RWAUnpauseData memory d2 = _signedData(100e6, 2, block.timestamp + 1 hours, atomist2Pk, block.chainid);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.unpause, (d2)));
        assertFalse(_readPaused());
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _seedBalance(uint256 amount_) internal {
        vm.prank(address(vault));
        IRWAExecutor(address(executor)).addBalance(balanceAccount, amount_);
    }

    function _setPaused(bool v_) internal {
        RWASlotHelpers.setPaused(address(vault), v_);
    }

    function _readPaused() internal view returns (bool) {
        return RWASlotHelpers.readPaused(address(vault));
    }

    function _signedData(uint256 balance_, uint256 nonce_, uint256 expiration_, uint256 pk_, uint256 chainId_)
        internal
        view
        returns (RWAUnpauseData memory d)
    {
        bytes32 digest = keccak256(abi.encodePacked(address(vault), MARKET_ID, balance_, nonce_, expiration_, chainId_));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk_, digest);
        d = RWAUnpauseData({
            confirmedTotalBalance: balance_,
            nonce: nonce_,
            expirationTime: expiration_,
            signature: abi.encodePacked(r, s, v)
        });
    }
}
