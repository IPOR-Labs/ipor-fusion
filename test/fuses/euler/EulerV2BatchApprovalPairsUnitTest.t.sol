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
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {
    EulerV2BatchFuse,
    EulerV2BatchItem,
    EulerV2BatchFuseData
} from "../../../contracts/fuses/euler/EulerV2BatchFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";

/// @dev Plain ERC-20 used as the vault underlying and as a token that no granted Euler vault holds
contract ApprovalPairsUnitToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev EVC stand-in: `batch` executes nothing and records the allowance the caller gave the watched spender. The
///      checked behaviour (pair validation and approvals) happens in the fuse before and after this call.
contract ApprovalPairsUnitEvc {
    address public watchedToken;
    address public watchedSpender;
    uint256 public allowanceDuringBatch;
    uint256 public batchCalls;

    function watch(address token_, address spender_) external {
        watchedToken = token_;
        watchedSpender = spender_;
    }

    function batch(IEVC.BatchItem[] calldata) external payable {
        batchCalls += 1;
        if (watchedToken != address(0)) {
            allowanceDuringBatch = IERC20(watchedToken).allowance(msg.sender, watchedSpender);
        }
    }
}

/// @dev Euler vault stand-in that reports its asset; deposits never execute because the EVC stand-in runs nothing
contract ApprovalPairsUnitEulerVault {
    address public immutable ASSET;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }
}

/// @dev Ungranted contract whose `asset()` reverts: proves the grant check runs before `asset()` is called
contract ApprovalPairsUnitRevertingVault {
    error ApprovalPairsUnitAssetCalled();

    function asset() external pure returns (address) {
        revert ApprovalPairsUnitAssetCalled();
    }
}

/// @dev Regression helper (Codex C-006): `approve` spends the allowance the caller granted it in an earlier pair
contract ApprovalPairsUnitAttacker {
    address public immutable UNDERLYING;
    address public immutable RECEIVER;

    constructor(address underlying_, address receiver_) {
        UNDERLYING = underlying_;
        RECEIVER = receiver_;
    }

    function approve(address, uint256 value_) external returns (bool) {
        if (value_ != 0) {
            IERC20(UNDERLYING).transferFrom(msg.sender, RECEIVER, IERC20(UNDERLYING).balanceOf(msg.sender));
        }
        return true;
    }
}

/// @title EulerV2BatchApprovalPairsUnitTest
/// @notice Unit test (IL-9244, Codex C-006): EulerV2BatchFuse runs by delegatecall in this contract, which plays the
///         Plasma Vault (substrates granted in its storage through PlasmaVaultConfigLib). Every approval pair must have
///         a granted Euler vault and that vault's `asset()` as the token; pairs are checked before the batch items and
///         before any external call, through `enter` and `enterTransient`.
contract EulerV2BatchApprovalPairsUnitTest is Test {
    uint256 private constant _VAULT_BALANCE = 1_000e18;
    uint256 private constant _DEPOSIT = 1e18;
    address private constant _THIEF = address(0xBEEF);

    ApprovalPairsUnitToken private _underlying;
    ApprovalPairsUnitToken private _otherToken;
    ApprovalPairsUnitEvc private _evc;
    ApprovalPairsUnitEulerVault private _eulerVault;
    ApprovalPairsUnitAttacker private _attacker;
    EulerV2BatchFuse private _fuse;

    function setUp() public {
        _underlying = new ApprovalPairsUnitToken("U");
        _otherToken = new ApprovalPairsUnitToken("W");
        _evc = new ApprovalPairsUnitEvc();
        _fuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, address(_evc));
        _eulerVault = new ApprovalPairsUnitEulerVault(address(_underlying));
        _attacker = new ApprovalPairsUnitAttacker(address(_underlying), _THIEF);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: address(_eulerVault), isCollateral: false, canBorrow: false, subAccounts: 0x00})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);

        _underlying.mint(address(this), _VAULT_BALANCE);
        _otherToken.mint(address(this), _VAULT_BALANCE);
    }

    /// @notice Runs `enter` in this contract's context, as PlasmaVault.execute does
    function enterAsVault(
        EulerV2BatchFuseData memory data_
    ) external returns (uint256 batchSize, address[] memory assets, address[] memory vaults) {
        bytes memory result = Address.functionDelegateCall(
            address(_fuse),
            abi.encodeCall(EulerV2BatchFuse.enter, (data_))
        );
        (batchSize, assets, vaults) = abi.decode(result, (uint256, address[], address[]));
    }

    /// @notice Runs `enterTransient` in this contract's context, as PlasmaVault.execute does
    function enterTransientAsVault() external {
        Address.functionDelegateCall(address(_fuse), abi.encodeCall(EulerV2BatchFuse.enterTransient, ()));
    }

    /// @notice Codex C-006: pairs [U, A] / [A, A] with an ungranted attacker are rejected on the first pair
    function testShouldRejectUngrantedSpenderBeforeCallingIt() public {
        vm.expectRevert(_invalidPair(address(_underlying), address(_attacker)));
        this.enterAsVault(
            _data(
                _depositItem(),
                _pair(address(_underlying), address(_attacker)),
                _pair(address(_attacker), address(_attacker))
            )
        );

        _assertNothingMoved(address(_attacker));
    }

    /// @notice Token binding: (U, V) is valid, (W, V) has a granted vault but W is not V's asset()
    function testShouldRejectTokenThatIsNotTheAssetOfTheGrantedVault() public {
        vm.expectRevert(_invalidPair(address(_otherToken), address(_eulerVault)));
        this.enterAsVault(
            _data(
                _depositItem(),
                _pair(address(_underlying), address(_otherToken)),
                _pair(address(_eulerVault), address(_eulerVault))
            )
        );

        _assertNothingMoved(address(_eulerVault));
        assertEq(_otherToken.allowance(address(this), address(_eulerVault)), 0, "no allowance on the wrong token");
    }

    /// @notice The grant is checked first: `asset()` of an ungranted contract is never called
    function testShouldCheckTheGrantBeforeCallingAsset() public {
        ApprovalPairsUnitRevertingVault ungrantedVault = new ApprovalPairsUnitRevertingVault();

        vm.expectRevert(_invalidPair(address(_underlying), address(ungrantedVault)));
        this.enterAsVault(_data(_depositItem(), _one(address(_underlying)), _one(address(ungrantedVault))));

        _assertNothingMoved(address(ungrantedVault));
    }

    /// @notice Pairs are validated before the batch items: an invalid pair is reported even when an item is invalid too
    function testShouldValidatePairsBeforeBatchItems() public {
        EulerV2BatchItem memory zeroTargetItem = EulerV2BatchItem(address(0), bytes1(0x00), "");

        vm.expectRevert(_invalidPair(address(_underlying), address(_attacker)));
        this.enterAsVault(_data(zeroTargetItem, _one(address(_underlying)), _one(address(_attacker))));

        _assertNothingMoved(address(_attacker));
    }

    /// @notice A valid pair is approved for max during the batch and reset to 0 after it
    function testShouldApproveValidPairForTheBatchAndResetIt() public {
        _evc.watch(address(_underlying), address(_eulerVault));

        (uint256 batchSize, address[] memory assets, address[] memory vaults) = this.enterAsVault(
            _data(_depositItem(), _one(address(_underlying)), _one(address(_eulerVault)))
        );

        assertEq(batchSize, 1, "batch size");
        assertEq(assets.length, 1, "assets length");
        assertEq(assets[0], address(_underlying), "asset");
        assertEq(vaults.length, 1, "vaults length");
        assertEq(vaults[0], address(_eulerVault), "vault");
        assertEq(_evc.batchCalls(), 1, "EVC batch called once");
        assertEq(_evc.allowanceDuringBatch(), type(uint256).max, "max allowance during the batch");
        assertEq(_underlying.allowance(address(this), address(_eulerVault)), 0, "allowance reset after the batch");
        assertEq(_underlying.balanceOf(address(this)), _VAULT_BALANCE, "vault balance unchanged");
    }

    /// @notice `enterTransient` reaches the same validation: an invalid pair read from transient inputs is rejected
    function testShouldRejectInvalidPairInEnterTransient() public {
        EulerV2BatchFuseData memory data = _data(
            _depositItem(),
            _pair(address(_underlying), address(_attacker)),
            _pair(address(_attacker), address(_attacker))
        );
        TransientStorageLib.setInputs(address(_fuse), _toChunks(abi.encode(data)));

        vm.expectRevert(_invalidPair(address(_underlying), address(_attacker)));
        this.enterTransientAsVault();

        _assertNothingMoved(address(_attacker));
    }

    // ------------------------------------------------------------------ helpers

    function _assertNothingMoved(address spender_) private view {
        assertEq(_underlying.balanceOf(address(this)), _VAULT_BALANCE, "vault balance unchanged");
        assertEq(_underlying.balanceOf(_THIEF), 0, "thief received nothing");
        assertEq(_underlying.allowance(address(this), spender_), 0, "no allowance left to the spender");
        assertEq(_evc.batchCalls(), 0, "EVC batch not called");
    }

    function _invalidPair(address asset_, address eulerVault_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(EulerV2BatchFuse.EulerV2BatchFuseInvalidApprovalPair.selector, asset_, eulerVault_);
    }

    function _data(
        EulerV2BatchItem memory item_,
        address[] memory assets_,
        address[] memory vaults_
    ) private pure returns (EulerV2BatchFuseData memory) {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = item_;
        return EulerV2BatchFuseData({batchItems: items, assetsForApprovals: assets_, eulerVaultsForApprovals: vaults_});
    }

    /// @dev Valid deposit on sub-account 0x00 (the vault itself is the receiver)
    function _depositItem() private view returns (EulerV2BatchItem memory) {
        return
            EulerV2BatchItem(
                address(_eulerVault),
                bytes1(0x00),
                abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, _DEPOSIT, address(this))
            );
    }

    function _one(address value_) private pure returns (address[] memory values) {
        values = new address[](1);
        values[0] = value_;
    }

    function _pair(address first_, address second_) private pure returns (address[] memory values) {
        values = new address[](2);
        values[0] = first_;
        values[1] = second_;
    }

    function _toChunks(bytes memory encoded_) private pure returns (bytes32[] memory chunks) {
        uint256 count = encoded_.length / 32;
        chunks = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            bytes32 chunk;
            assembly {
                chunk := mload(add(encoded_, add(32, mul(i, 32))))
            }
            chunks[i] = chunk;
        }
    }
}
