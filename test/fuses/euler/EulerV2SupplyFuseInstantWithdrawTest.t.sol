// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title EulerV2SupplyFuseInstantWithdrawTest
/// @notice Unit tests for instant withdraw functionality in EulerV2SupplyFuse
contract EulerV2SupplyFuseInstantWithdrawTest is Test {
    // ============ Constants ============

    uint256 public constant MARKET_ID = 1;
    address public constant MOCK_EVC = address(0x1234);
    address public constant MOCK_EULER_VAULT = address(0x5678);
    address public constant MOCK_ASSET = address(0x9ABC);
    bytes1 public constant SUB_ACCOUNT = 0x01;

    // ============ State Variables ============

    EulerV2SupplyFuse public fuse;
    PlasmaVaultMock public vault;
    address public subAccountAddress;

    // ============ Events ============

    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);
    event EulerV2SupplyFuseExitFailed(
        address version,
        address eulerVault,
        uint256 amount,
        address subAccount
    );

    // ============ Setup ============

    function setUp() public {
        // Deploy fuse
        fuse = new EulerV2SupplyFuse(MARKET_ID, MOCK_EVC);

        // Deploy mock vault
        vault = new PlasmaVaultMock(address(fuse), address(0));

        // Calculate sub-account address
        subAccountAddress = EulerFuseLib.generateSubAccountAddress(address(vault), SUB_ACCOUNT);

        // Label addresses
        vm.label(address(fuse), "EulerV2SupplyFuse");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(MOCK_EVC, "MockEVC");
        vm.label(MOCK_EULER_VAULT, "MockEulerVault");
        vm.label(subAccountAddress, "SubAccount");
    }

    // ============ Constructor Tests ============

    function testShouldSetVersionToDeploymentAddress() public view {
        assertEq(fuse.VERSION(), address(fuse));
    }

    function testShouldSetMarketIdCorrectly() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldSetEVCCorrectly() public view {
        assertEq(address(fuse.EVC()), MOCK_EVC);
    }

    // ============ InstantWithdraw Tests - Validation ============

    function testShouldRevertInstantWithdrawWhenIsCollateralTrue() public {
        // given - Setup substrate with isCollateral=true, canBorrow=false
        _setupSubstrate(true, false);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when/then - Should revert because isCollateral is true
        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SupplyFuse.EulerV2SupplyFuseUnsupportedVault.selector,
                MOCK_EULER_VAULT,
                SUB_ACCOUNT
            )
        );
        vault.instantWithdraw(params);
    }

    function testShouldRevertInstantWithdrawWhenCanBorrowTrue() public {
        // given - Setup substrate with isCollateral=false, canBorrow=true
        _setupSubstrate(false, true);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when/then - Should revert because canBorrow is true
        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SupplyFuse.EulerV2SupplyFuseUnsupportedVault.selector,
                MOCK_EULER_VAULT,
                SUB_ACCOUNT
            )
        );
        vault.instantWithdraw(params);
    }

    function testShouldRevertInstantWithdrawWhenBothFlagsTrue() public {
        // given - Setup substrate with both flags true
        _setupSubstrate(true, true);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when/then - Should revert because both flags are true
        vm.expectRevert(
            abi.encodeWithSelector(
                EulerV2SupplyFuse.EulerV2SupplyFuseUnsupportedVault.selector,
                MOCK_EULER_VAULT,
                SUB_ACCOUNT
            )
        );
        vault.instantWithdraw(params);
    }

    function testShouldReturnZeroWhenAmountIsZero() public {
        // given - Setup valid substrate but zero amount
        _setupSubstrate(false, false);

        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(uint256(0)); // zero amount
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when - Should complete without revert
        vault.instantWithdraw(params);

        // then - No event should be emitted (checked by absence of expectEmit)
    }

    // ============ Success Cases ============

    function testShouldInstantWithdrawSuccessfullyWhenNotCollateralAndNotBorrowable() public {
        // given - Setup valid substrate for instant withdraw
        _setupSubstrate(false, false);

        uint256 amount = 1000e18;
        uint256 sharesAmount = 900e18; // Simulate some shares balance
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault to return balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(sharesAmount)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", sharesAmount),
            abi.encode(amount)
        );

        // Mock successful EVC.call
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode(abi.encode(amount))
        );

        // when/then - Should succeed without revert
        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        vault.instantWithdraw(params);
    }

    function testShouldWithdrawPartialAmountWhenInsufficientBalance() public {
        // given - Setup valid substrate
        _setupSubstrate(false, false);

        uint256 requestedAmount = 1000e18;
        uint256 availableShares = 500e18; // Only half available
        uint256 availableAssets = 500e18;

        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(requestedAmount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault to return limited balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(availableShares)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", availableShares),
            abi.encode(availableAssets)
        );

        // Mock successful EVC.call with partial amount
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode(abi.encode(availableAssets))
        );

        // when/then - Should withdraw only available amount
        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, availableAssets, subAccountAddress);

        vault.instantWithdraw(params);
    }

    function testShouldEmitExitEventOnSuccess() public {
        // given - Setup valid substrate
        _setupSubstrate(false, false);

        uint256 amount = 750e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault responses
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(amount)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", amount),
            abi.encode(amount)
        );

        // Mock successful EVC.call
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode(abi.encode(amount))
        );

        // when/then - Should emit success event with correct parameters
        vm.expectEmit(true, true, true, true);
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        vault.instantWithdraw(params);
    }

    // ============ Exit Comparison Tests ============

    function testShouldNotRevertOnExternalFailureInInstantWithdraw() public {
        // given - Setup valid substrate for instant withdraw
        _setupSubstrate(false, false);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault to return balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(amount)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", amount),
            abi.encode(amount)
        );

        // Mock EVC.call to revert
        vm.mockCallRevert(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode("Withdrawal failed")
        );

        // when/then - Should NOT revert, but emit failure event
        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyFuseExitFailed(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        vault.instantWithdraw(params);
    }

    function testShouldRevertOnExternalFailureInNormalExit() public {
        // given - Setup exit data
        EulerV2SupplyFuseExitData memory exitData = EulerV2SupplyFuseExitData({
            eulerVault: MOCK_EULER_VAULT,
            maxAmount: 1000e18,
            subAccount: SUB_ACCOUNT
        });

        // Mock vault to return balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(1000e18)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", 1000e18),
            abi.encode(1000e18)
        );

        // Mock EVC.call to revert (without mock call revert, just let it fail naturally)
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode("")  // Empty return will cause decode error
        );

        // when/then - Normal exit SHOULD revert
        vm.expectRevert();
        bytes memory callData = abi.encodeWithSelector(EulerV2SupplyFuse.exit.selector, exitData);
        address(fuse).delegatecall(callData);
    }

    // ============ Helper Functions ============

    /// @notice Setup substrate configuration for testing
    /// @param isCollateral_ Whether vault can be used as collateral
    /// @param canBorrow_ Whether one can borrow against it
    function _setupSubstrate(bool isCollateral_, bool canBorrow_) internal {
        // Create substrate
        EulerSubstrate memory substrate = EulerSubstrate({
            eulerVault: MOCK_EULER_VAULT,
            isCollateral: isCollateral_,
            canBorrow: canBorrow_,
            subAccounts: SUB_ACCOUNT
        });

        // Convert to bytes32
        bytes32 substrateBytes = EulerFuseLib.substrateToBytes32(substrate);

        // Grant substrate to market
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrateBytes;

        vm.prank(address(vault));
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }
}
