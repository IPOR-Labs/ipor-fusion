// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

/// @dev Plain ERC-20 used as the underlying of the Euler vault stand-in
contract BatchExecutedEventToken is ERC20 {
    constructor() ERC20("U", "U") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev EVC stand-in: `batch` executes nothing, the event is emitted by the fuse after it returns
contract BatchExecutedEventEvc {
    function batch(IEVC.BatchItem[] calldata) external payable {}
}

/// @dev Euler vault stand-in that reports its asset
contract BatchExecutedEventEulerVault {
    address public immutable ASSET;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }
}

/// @title EulerV2BatchExecutedEventTest
/// @notice Unit test (IL-9274, Pete D-012): `EulerV2BatchFuseExecuted(address version, uint256 batchSize,
///         address[] assets, address[] vaults)` carries the fuse version, has no indexed parameter (all four values
///         in the data section) and replaces `BatchExecuted(uint256 indexed, address[], address[])`.
///         The fuse runs by delegatecall in this contract (the Plasma Vault), so the log emitter is this contract.
contract EulerV2BatchExecutedEventTest is Test {
    event EulerV2BatchFuseExecuted(address version, uint256 batchSize, address[] assets, address[] vaults);

    BatchExecutedEventToken private _underlying;
    BatchExecutedEventEvc private _evc;
    BatchExecutedEventEulerVault private _eulerVault;
    EulerV2BatchFuse private _fuse;

    function setUp() public {
        _underlying = new BatchExecutedEventToken();
        _evc = new BatchExecutedEventEvc();
        _fuse = new EulerV2BatchFuse(IporFusionMarkets.EULER_V2, address(_evc));
        _eulerVault = new BatchExecutedEventEulerVault(address(_underlying));

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: address(_eulerVault), isCollateral: false, canBorrow: false, subAccounts: 0x00})
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        _underlying.mint(address(this), 1_000e18);
    }

    /// @notice Runs `enter` in this contract's context, as PlasmaVault.execute does
    function enterAsVault(EulerV2BatchFuseData memory data_) external {
        Address.functionDelegateCall(address(_fuse), abi.encodeCall(EulerV2BatchFuse.enter, (data_)));
    }

    function testShouldEmitExecutedEventWithVersionAndData() public {
        EulerV2BatchFuseData memory data = _data();

        vm.expectEmit(true, true, true, true, address(this));
        emit EulerV2BatchFuseExecuted(address(_fuse), 1, data.assetsForApprovals, data.eulerVaultsForApprovals);

        this.enterAsVault(data);

        assertEq(_fuse.VERSION(), address(_fuse), "version is the fuse address");
    }

    function testShouldEmitExecutedEventWithoutIndexedTopics() public {
        EulerV2BatchFuseData memory data = _data();

        vm.recordLogs();
        this.enterAsVault(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 expectedTopic0 = keccak256("EulerV2BatchFuseExecuted(address,uint256,address[],address[])");
        uint256 matches;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == expectedTopic0) {
                matches++;
                assertEq(logs[i].topics.length, 1, "only topic0, no indexed parameter");
                assertEq(logs[i].emitter, address(this), "emitted in the vault context");
                assertEq(
                    logs[i].data,
                    abi.encode(address(_fuse), uint256(1), data.assetsForApprovals, data.eulerVaultsForApprovals),
                    "all four values in the data section"
                );
            }
            assertTrue(
                logs[i].topics.length == 0 ||
                    logs[i].topics[0] != keccak256("BatchExecuted(uint256,address[],address[])"),
                "old event is not emitted"
            );
        }
        assertEq(matches, 1, "exactly one new event");
    }

    function _data() private view returns (EulerV2BatchFuseData memory data) {
        EulerV2BatchItem[] memory items = new EulerV2BatchItem[](1);
        items[0] = EulerV2BatchItem(
            address(_eulerVault),
            bytes1(0x00),
            abi.encodeWithSelector(ERC4626Upgradeable.deposit.selector, 1e18, address(this))
        );
        address[] memory assets = new address[](1);
        assets[0] = address(_underlying);
        address[] memory vaults = new address[](1);
        vaults[0] = address(_eulerVault);
        data = EulerV2BatchFuseData({batchItems: items, assetsForApprovals: assets, eulerVaultsForApprovals: vaults});
    }
}
