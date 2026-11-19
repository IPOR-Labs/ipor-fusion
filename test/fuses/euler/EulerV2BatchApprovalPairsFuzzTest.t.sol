// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    EulerV2BatchFuse,
    EulerV2BatchItem,
    EulerV2BatchFuseData
} from "../../../contracts/fuses/euler/EulerV2BatchFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";

/// @dev Plain ERC-20 used as the underlying of the granted Euler vault stand-ins
contract ApprovalPairsFuzzToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Ungranted contract that counts every call it receives, whatever the selector: it plays a malicious "token"
///      and a malicious "spender" of an approval pair. Any call at all is a failure of the pair validation.
contract ApprovalPairsFuzzProbe {
    uint256 public calls;

    fallback(bytes calldata) external returns (bytes memory) {
        calls += 1;
        return abi.encode(uint256(0));
    }
}

/// @dev EVC stand-in: `batch` executes nothing; the checked behaviour is in the fuse before and after this call
contract ApprovalPairsFuzzEvc {
    uint256 public batchCalls;

    function batch(IEVC.BatchItem[] calldata) external payable {
        batchCalls += 1;
    }
}

/// @dev Euler vault stand-in that reports its asset
contract ApprovalPairsFuzzEulerVault {
    address public immutable ASSET;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }
}

/// @title EulerV2BatchApprovalPairsFuzzTest
/// @notice Pinning fuzz test (IL-9593, finding M03; fixed on base by IL-9244): for any array of
///         `(token, spender)` approval pairs, `EulerV2BatchFuse.enter` either rejects the batch with
///         `EulerV2BatchFuseInvalidApprovalPair` before any approval, EVC call or call to an ungranted address, or
///         every pair was `(asset(), granted Euler vault)` and every allowance is 0 after the batch. It complements the
///         hand-picked cases of `EulerV2BatchApprovalPairsUnitTest`. Passes on base 8692fbe5.
/// @dev Dropping the grant check in `EulerV2BatchFuse._validateApprovalPair` makes the property fail: an ungranted
///      probe would be called by `forceApprove` or `asset()`.
contract EulerV2BatchApprovalPairsFuzzTest is Test {
    uint256 private constant _VAULT_BALANCE = 1_000e18;
    uint256 private constant _DEPOSIT = 1e18;
    uint256 private constant _MAX_PAIRS = 5;

    ApprovalPairsFuzzToken private _tokenA;
    ApprovalPairsFuzzToken private _tokenB;
    ApprovalPairsFuzzEvc private _evc;
    ApprovalPairsFuzzEulerVault private _vaultA;
    ApprovalPairsFuzzEulerVault private _vaultB;
    ApprovalPairsFuzzProbe private _probeToken;
    ApprovalPairsFuzzProbe private _probeSpender;
    EulerV2BatchFuse private _fuse;

    function setUp() public {
        _tokenA = new ApprovalPairsFuzzToken("A");
        _tokenB = new ApprovalPairsFuzzToken("B");
        _evc = new ApprovalPairsFuzzEvc();
        _fuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, address(_evc));
        _vaultA = new ApprovalPairsFuzzEulerVault(address(_tokenA));
        _vaultB = new ApprovalPairsFuzzEulerVault(address(_tokenB));
        _probeToken = new ApprovalPairsFuzzProbe();
        _probeSpender = new ApprovalPairsFuzzProbe();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: address(_vaultA), isCollateral: false, canBorrow: false, subAccounts: 0x00})
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: address(_vaultB), isCollateral: false, canBorrow: false, subAccounts: 0x00})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);

        _tokenA.mint(address(this), _VAULT_BALANCE);
        _tokenB.mint(address(this), _VAULT_BALANCE);
    }

    /// @notice Runs `enter` in this contract's context, as PlasmaVault.execute does
    function enterAsVault(EulerV2BatchFuseData memory data_) external {
        Address.functionDelegateCall(address(_fuse), abi.encodeCall(EulerV2BatchFuse.enter, (data_)));
    }

    /// @notice Property: arbitrary approval pairs are either rejected as an invalid pair with no side effect, or all
    ///         of them are valid and every allowance is 0 after the batch
    /// @param seed_ Selects, per pair, the token and the spender from a pool of granted, ungranted and random addresses
    /// @param randomA_ Random address added to the token pool
    /// @param randomB_ Random address added to the spender pool
    /// @param length_ Number of pairs (bounded to 0..5)
    function testFuzzApprovalPairsAreValidatedBeforeAnyCall(
        uint256 seed_,
        address randomA_,
        address randomB_,
        uint8 length_
    ) public {
        uint256 length = bound(length_, 0, _MAX_PAIRS);
        address[] memory tokens = new address[](length);
        address[] memory spenders = new address[](length);
        bool allValid = true;
        for (uint256 i; i < length; ++i) {
            uint256 pick = uint256(keccak256(abi.encode(seed_, i)));
            // Bias towards valid pairs so that both outcomes are exercised: 1 of 3 pairs is a granted pair
            if (pick % 3 == 0) {
                bool second = (pick >> 8) % 2 == 0;
                tokens[i] = second ? address(_tokenB) : address(_tokenA);
                spenders[i] = second ? address(_vaultB) : address(_vaultA);
            } else {
                tokens[i] = _pickToken((pick >> 16) % 6, randomA_);
                spenders[i] = _pickSpender((pick >> 24) % 6, randomB_);
            }
            if (!_isGrantedPair(tokens[i], spenders[i])) {
                allValid = false;
            }
        }

        bool reverted;
        bytes memory reason;
        try this.enterAsVault(_data(tokens, spenders)) {} catch (bytes memory reason_) {
            reverted = true;
            reason = reason_;
        }

        assertEq(_probeToken.calls(), 0, "ungranted token probe never called");
        assertEq(_probeSpender.calls(), 0, "ungranted spender probe never called");
        assertEq(_tokenA.balanceOf(address(this)), _VAULT_BALANCE, "token A balance unchanged");
        assertEq(_tokenB.balanceOf(address(this)), _VAULT_BALANCE, "token B balance unchanged");
        // Whatever the outcome, no allowance of this vault stays open (read only on the real tokens, never on a probe)
        for (uint256 i; i < length; ++i) {
            if (tokens[i] == address(_tokenA) || tokens[i] == address(_tokenB)) {
                assertEq(IERC20(tokens[i]).allowance(address(this), spenders[i]), 0, "allowance is 0 after the batch");
            }
        }

        if (allValid) {
            assertFalse(reverted, "a batch with only valid pairs succeeds");
            assertEq(_evc.batchCalls(), 1, "EVC batch called once");
        } else {
            assertTrue(reverted, "a batch with an invalid pair reverts");
            assertEq(bytes4(reason), EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector, "invalid pair");
            assertEq(_evc.batchCalls(), 0, "EVC batch not called");
        }
    }

    /// @notice Property: a granted Euler vault paired with any token other than its `asset()` is always rejected
    function testFuzzGrantedVaultWithForeignTokenIsRejected(address token_, bool useSecondVault_) public {
        address vault = useSecondVault_ ? address(_vaultB) : address(_vaultA);
        address ownAsset = useSecondVault_ ? address(_tokenB) : address(_tokenA);
        vm.assume(token_ != ownAsset);

        address[] memory tokens = new address[](1);
        address[] memory spenders = new address[](1);
        tokens[0] = token_;
        spenders[0] = vault;

        vm.expectRevert(
            abi.encodeWithSelector(EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector, token_, vault)
        );
        this.enterAsVault(_data(tokens, spenders));

        assertEq(_evc.batchCalls(), 0, "EVC batch not called");
    }

    /// @notice Property: any ungranted spender is rejected whatever the token, without being called
    function testFuzzUngrantedSpenderIsRejectedWithoutCall(address token_, address spender_) public {
        vm.assume(spender_ != address(_vaultA) && spender_ != address(_vaultB));

        address[] memory tokens = new address[](1);
        address[] memory spenders = new address[](1);
        tokens[0] = token_;
        spenders[0] = spender_;

        vm.expectRevert(
            abi.encodeWithSelector(EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector, token_, spender_)
        );
        this.enterAsVault(_data(tokens, spenders));

        assertEq(_evc.batchCalls(), 0, "EVC batch not called");
    }

    // ------------------------------------------------------------------ helpers

    function _isGrantedPair(address token_, address spender_) private view returns (bool) {
        return
            (token_ == address(_tokenA) && spender_ == address(_vaultA)) ||
            (token_ == address(_tokenB) && spender_ == address(_vaultB));
    }

    function _pickToken(uint256 index_, address random_) private view returns (address) {
        if (index_ == 0) return address(_tokenA);
        if (index_ == 1) return address(_tokenB);
        if (index_ == 2) return address(_probeToken);
        if (index_ == 3) return address(_probeSpender);
        if (index_ == 4) return address(0);
        return random_;
    }

    function _pickSpender(uint256 index_, address random_) private view returns (address) {
        if (index_ == 0) return address(_vaultA);
        if (index_ == 1) return address(_vaultB);
        if (index_ == 2) return address(_probeSpender);
        if (index_ == 3) return address(_probeToken);
        if (index_ == 4) return address(this);
        return random_;
    }

    function _data(
        address[] memory assets_,
        address[] memory vaults_
    ) private view returns (EulerV2BatchFuseData memory) {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            address(_vaultA),
            bytes1(0x00),
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _DEPOSIT, address(this))
        );
        return EulerV2BatchFuseData({batchItems: items, assetsForApprovals: assets_, eulerVaultsForApprovals: vaults_});
    }
}
