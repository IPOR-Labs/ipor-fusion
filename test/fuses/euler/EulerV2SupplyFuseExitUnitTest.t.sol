// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title EulerV2SupplyFuseExitUnitTest
/// @notice Unit tests for the success path of the normal (non-catching) EulerV2SupplyFuse.exit
contract EulerV2SupplyFuseExitUnitTest is Test {
    uint256 public constant MARKET_ID = 1;
    address public constant MOCK_EVC = address(0x1234);
    address public constant MOCK_EULER_VAULT = address(0x5678);
    bytes1 public constant SUB_ACCOUNT = 0x01;

    EulerV2SupplyFuse public fuse;
    PlasmaVaultMock public vault;
    address public subAccountAddress;

    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);

    function setUp() public {
        fuse = new EulerV2SupplyFuse(MARKET_ID, MOCK_EVC);
        vault = new PlasmaVaultMock(address(fuse), address(0));
        subAccountAddress = EulerFuseLib.generateSubAccountAddress(address(vault), SUB_ACCOUNT);
    }

    function testShouldExitThroughEvcCallAndEmitEventWithRequestedAmount() public {
        // given - 900e18 shares worth 1000e18 assets, request 600e18 (below the position)
        uint256 requested = 600e18;
        _mockPosition(900e18, 1000e18);

        bytes memory withdrawCall = _withdrawCall(requested);
        vm.mockCall(
            MOCK_EVC,
            abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)),
            abi.encode("")
        );

        // then - EVC.call receives the exact withdraw(assets, plasmaVault, subAccount) and the event carries the amount
        vm.expectCall(MOCK_EVC, abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, requested, subAccountAddress);

        // when
        _exit(requested);
    }

    function testShouldClampExitToConvertedBalanceWhenRequestExceedsPosition() public {
        // given - 900e18 shares convert to 1000e18 assets, request 5000e18
        _mockPosition(900e18, 1000e18);

        bytes memory withdrawCall = _withdrawCall(1000e18);
        vm.mockCall(
            MOCK_EVC,
            abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)),
            abi.encode("")
        );

        // then - the withdrawn amount is convertToAssets(balanceOf), not the request and not the share balance
        vm.expectCall(MOCK_EVC, abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)));
        vm.expectEmit(true, true, true, true, address(vault));
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, 1000e18, subAccountAddress);

        // when
        _exit(5000e18);
    }

    function testShouldNotCapNormalExitAtEulerVaultCash() public {
        // given - position 1000e18 but the EVault only has 100e18 of free cash
        _mockPosition(1000e18, 1000e18);
        vm.mockCall(MOCK_EULER_VAULT, abi.encodeWithSignature("cash()"), abi.encode(uint256(100e18)));

        bytes memory withdrawCall = _withdrawCall(1000e18);
        vm.mockCall(
            MOCK_EVC,
            abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)),
            abi.encode("")
        );

        // then - the normal exit never reads cash() and withdraws the full position amount
        vm.expectCall(MOCK_EULER_VAULT, abi.encodeWithSignature("cash()"), 0);
        vm.expectCall(MOCK_EVC, abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)), 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, 1000e18, subAccountAddress);

        // when
        _exit(1000e18);
    }

    function _mockPosition(uint256 shares_, uint256 assets_) internal {
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(shares_)
        );
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", shares_),
            abi.encode(assets_)
        );
    }

    function _withdrawCall(uint256 assets_) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                bytes4(keccak256("withdraw(uint256,address,address)")),
                assets_,
                address(vault),
                subAccountAddress
            );
    }

    function _exit(uint256 maxAmount_) internal {
        vault.execute(
            address(fuse),
            abi.encodeWithSelector(
                EulerV2SupplyFuse.exit.selector,
                EulerV2SupplyFuseExitData({
                    eulerVault: MOCK_EULER_VAULT,
                    maxAmount: maxAmount_,
                    subAccount: SUB_ACCOUNT
                })
            )
        );
    }
}
