// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";

/// @title Mock ERC20 Token
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title EulerV2SupplyFuse Unit Tests
/// @notice Tests for constructor validation, zero amount handling, and event emissions
/// @dev Integration tests with actual substrate validation are in separate test files
contract EulerV2SupplyFuseTest is Test {
    EulerV2SupplyFuse public fuse;
    MockToken public mockToken;

    uint256 public constant MARKET_ID = 1;
    address public constant MOCK_EVC = address(0x1234);
    bytes1 public constant SUB_ACCOUNT_ID = 0x01;

    event EulerV2SupplyEnterFuse(address version, address eulerVault, uint256 mintedShares, address subAccount);
    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAssets, address subAccount);

    function setUp() public {
        mockToken = new MockToken();
        fuse = new EulerV2SupplyFuse(MARKET_ID, MOCK_EVC);
    }

    // ============================================
    // Constructor Tests
    // ============================================

    /// @notice Test constructor reverts when EVC address is zero
    function testConstructorRevertsWhenEVCIsZero() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new EulerV2SupplyFuse(MARKET_ID, address(0));
    }

    /// @notice Test constructor sets VERSION immutable correctly
    function testConstructorSetsVersion() public {
        EulerV2SupplyFuse newFuse = new EulerV2SupplyFuse(MARKET_ID, MOCK_EVC);
        assertEq(newFuse.VERSION(), address(newFuse), "VERSION should be contract address");
    }

    /// @notice Test constructor sets MARKET_ID immutable correctly
    function testConstructorSetsMarketId() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID, "MARKET_ID should match constructor param");
    }

    /// @notice Test constructor sets EVC immutable correctly
    function testConstructorSetsEVC() public view {
        assertEq(address(fuse.EVC()), MOCK_EVC, "EVC should match constructor param");
    }

    /// @notice Test constructor with zero market ID (should not revert - valid value)
    function testConstructorWithZeroMarketId() public {
        EulerV2SupplyFuse newFuse = new EulerV2SupplyFuse(0, MOCK_EVC);
        assertEq(newFuse.MARKET_ID(), 0, "Should accept zero market ID");
    }

    // ============================================
    // Enter - Zero Amount Early Return Tests
    // ============================================

    /// @notice Test enter returns 0 immediately when maxAmount is 0
    function testEnterReturnsZeroWhenMaxAmountIsZero() public {
        address mockVault = address(0x5678);

        EulerV2SupplyFuseEnterData memory data = EulerV2SupplyFuseEnterData({
            eulerVault: mockVault,
            maxAmount: 0,
            subAccount: SUB_ACCOUNT_ID
        });

        // Should return 0 without any external calls
        uint256 result = fuse.enter(data);
        assertEq(result, 0, "Should return 0 for zero maxAmount");
    }

    /// @notice Test enter with zero maxAmount doesn't emit event
    function testEnterWithZeroAmountDoesNotEmitEvent() public {
        address mockVault = address(0x5678);

        EulerV2SupplyFuseEnterData memory data = EulerV2SupplyFuseEnterData({
            eulerVault: mockVault,
            maxAmount: 0,
            subAccount: SUB_ACCOUNT_ID
        });

        // Record logs to verify no event is emitted
        vm.recordLogs();
        fuse.enter(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "Should not emit any events for zero amount");
    }

    // ============================================
    // Exit - Zero Amount Early Return Tests
    // ============================================

    /// @notice Test exit returns 0 immediately when maxAmount is 0
    function testExitReturnsZeroWhenMaxAmountIsZero() public {
        address mockVault = address(0x5678);

        EulerV2SupplyFuseExitData memory data = EulerV2SupplyFuseExitData({
            eulerVault: mockVault,
            maxAmount: 0,
            subAccount: SUB_ACCOUNT_ID
        });

        // Should return 0 without any external calls
        uint256 result = fuse.exit(data);
        assertEq(result, 0, "Should return 0 for zero maxAmount");
    }

    /// @notice Test exit with zero maxAmount doesn't emit event
    function testExitWithZeroAmountDoesNotEmitEvent() public {
        address mockVault = address(0x5678);

        EulerV2SupplyFuseExitData memory data = EulerV2SupplyFuseExitData({
            eulerVault: mockVault,
            maxAmount: 0,
            subAccount: SUB_ACCOUNT_ID
        });

        // Record logs to verify no event is emitted
        vm.recordLogs();
        fuse.exit(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0, "Should not emit any events for zero amount");
    }

    // ============================================
    // SubAccount Address Generation Tests
    // ============================================

    /// @notice Test subAccount address generation is consistent
    function testSubAccountAddressGeneration() public view {
        address plasmaVault = address(0xABCD);
        bytes1 subAccountId = 0x05;

        address expected = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);
        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        assertEq(result, expected, "SubAccount address should be deterministic");
    }

    /// @notice Test subAccount with zero ID returns original address
    function testSubAccountWithZeroIdReturnsOriginal() public view {
        address plasmaVault = address(0xABCD);
        bytes1 zeroId = 0x00;

        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, zeroId);
        assertEq(result, plasmaVault, "Zero subAccount ID should return original address");
    }

    /// @notice Test different subAccount IDs produce different addresses
    function testDifferentSubAccountIdsProduceDifferentAddresses() public view {
        address plasmaVault = address(0xABCD);

        address sub1 = EulerFuseLib.generateSubAccountAddress(plasmaVault, 0x01);
        address sub2 = EulerFuseLib.generateSubAccountAddress(plasmaVault, 0x02);

        assertTrue(sub1 != sub2, "Different subAccount IDs should produce different addresses");
    }

    // ============================================
    // Fuzz Tests
    // ============================================

    /// @notice Fuzz test: enter always returns 0 for zero maxAmount
    function testFuzz_EnterReturnsZeroForZeroAmount(address vault, bytes1 subAccount) public {
        EulerV2SupplyFuseEnterData memory data = EulerV2SupplyFuseEnterData({
            eulerVault: vault,
            maxAmount: 0,
            subAccount: subAccount
        });

        uint256 result = fuse.enter(data);
        assertEq(result, 0, "Should always return 0 for zero maxAmount");
    }

    /// @notice Fuzz test: exit always returns 0 for zero maxAmount
    function testFuzz_ExitReturnsZeroForZeroAmount(address vault, bytes1 subAccount) public {
        EulerV2SupplyFuseExitData memory data = EulerV2SupplyFuseExitData({
            eulerVault: vault,
            maxAmount: 0,
            subAccount: subAccount
        });

        uint256 result = fuse.exit(data);
        assertEq(result, 0, "Should always return 0 for zero maxAmount");
    }

    /// @notice Fuzz test: subAccount generation is XOR-based
    function testFuzz_SubAccountGeneration(address plasmaVault, bytes1 subAccountId) public pure {
        address expected = address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        assertEq(result, expected, "SubAccount should be XOR of plasmaVault and subAccountId");
    }
}
