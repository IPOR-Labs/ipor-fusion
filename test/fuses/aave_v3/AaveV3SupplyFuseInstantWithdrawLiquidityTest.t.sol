// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {AaveV3SupplyFuse, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @dev Acts as the Aave V3 addresses provider, pool and data provider at once. `withdraw` pays exactly the requested
///      amount or reverts when the amount exceeds the reserve liquidity, as the real pool does.
contract MockAaveV3Environment {
    MockERC20 public immutable UNDERLYING;
    MockERC20 public immutable A_TOKEN;

    uint256 public configuration;
    uint128 public virtualUnderlyingBalance;

    error InsufficientLiquidity();
    error ConfigurationReverts();

    bool public configurationReverts;

    constructor(MockERC20 underlying_, MockERC20 aToken_) {
        UNDERLYING = underlying_;
        A_TOKEN = aToken_;
    }

    function setVirtualAccounting(bool active_, uint128 virtualBalance_) external {
        configuration = active_ ? (uint256(1) << 252) : 0;
        virtualUnderlyingBalance = virtualBalance_;
    }

    function setConfigurationReverts(bool value_) external {
        configurationReverts = value_;
    }

    function getPool() external view returns (address) {
        return address(this);
    }

    function getPoolDataProvider() external view returns (address) {
        return address(this);
    }

    function getReserveTokensAddresses(address) external view returns (address, address, address) {
        return (address(A_TOKEN), address(0), address(0));
    }

    function getConfiguration(address) external view returns (uint256) {
        if (configurationReverts) {
            revert ConfigurationReverts();
        }
        return configuration;
    }

    function getVirtualUnderlyingBalance(address) external view returns (uint128) {
        return virtualUnderlyingBalance;
    }

    function withdraw(address, uint256 amount_, address to_) external returns (uint256) {
        if (amount_ > UNDERLYING.balanceOf(address(A_TOKEN))) {
            revert InsufficientLiquidity();
        }
        if ((configuration >> 252) & 1 == 1) {
            if (amount_ > virtualUnderlyingBalance) {
                revert InsufficientLiquidity();
            }
            virtualUnderlyingBalance -= uint128(amount_);
        }
        UNDERLYING.mint(to_, amount_);
        return amount_;
    }
}

/// @title AaveV3SupplyFuseInstantWithdrawLiquidityTest
/// @notice IL-9558: the instant withdraw path caps the request at the reserve liquidity (the underlying held by the
///         aToken and, with virtual accounting active, the virtual balance); the ALPHA exit is not capped.
contract AaveV3SupplyFuseInstantWithdrawLiquidityTest is Test {
    uint256 private constant MARKET_ID = 1;
    uint256 private constant POSITION = 1_000e6;

    MockERC20 private _underlying;
    MockERC20 private _aToken;
    MockAaveV3Environment private _aave;
    AaveV3SupplyFuse private _fuse;
    PlasmaVaultMock private _vault;

    function setUp() public {
        _underlying = new MockERC20("USD Coin", "USDC", 6);
        _aToken = new MockERC20("Aave USDC", "aUSDC", 6);
        _aave = new MockAaveV3Environment(_underlying, _aToken);
        _fuse = new AaveV3SupplyFuse(MARKET_ID, address(_aave));
        _vault = new PlasmaVaultMock(address(_fuse), address(0));

        address[] memory assets = new address[](1);
        assets[0] = address(_underlying);
        _vault.grantAssetsToMarket(MARKET_ID, assets);

        _aToken.mint(address(_vault), POSITION);
    }

    function testShouldCapInstantWithdrawAtUnderlyingHeldByATokenWhenVirtualAccountingIsOff() external {
        // given - bit 252 is 0 (Aave 3.0 and forks): only the underlying held by the aToken limits the withdrawal
        _underlying.mint(address(_aToken), 300e6);
        _aave.setVirtualAccounting(false, 0);

        // then - the virtual balance getter is never called
        vm.expectCall(
            address(_aave),
            abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", address(_underlying)),
            0
        );
        vm.expectCall(address(_aave), abi.encodeWithSignature("getConfiguration(address)", address(_underlying)), 1);
        vm.expectCall(
            address(_aave),
            abi.encodeWithSignature("withdraw(address,uint256,address)", address(_underlying), 300e6, address(_vault)),
            1
        );

        // when
        vm.recordLogs();
        _vault.instantWithdraw(_params(800e6));

        // then
        assertEq(_underlying.balanceOf(address(_vault)), 300e6, "capped at the underlying held by the aToken");
        assertEq(_countEvents(vm.getRecordedLogs(), _failedTopic()), 0, "no ExitFailed event");
    }

    function testShouldCapInstantWithdrawAtVirtualBalanceWhenVirtualAccountingIsOn() external {
        // given - bit 252 is 1 and the virtual balance is the binding limit (aToken holds more underlying)
        _underlying.mint(address(_aToken), 900e6);
        _aave.setVirtualAccounting(true, 300e6);

        vm.expectCall(
            address(_aave),
            abi.encodeWithSignature("getVirtualUnderlyingBalance(address)", address(_underlying)),
            1
        );
        vm.expectCall(
            address(_aave),
            abi.encodeWithSignature("withdraw(address,uint256,address)", address(_underlying), 300e6, address(_vault)),
            1
        );

        // when
        vm.recordLogs();
        _vault.instantWithdraw(_params(800e6));

        // then
        assertEq(_underlying.balanceOf(address(_vault)), 300e6, "capped at the virtual balance");
        assertEq(_countEvents(vm.getRecordedLogs(), _failedTopic()), 0, "no ExitFailed event");
    }

    function testShouldCapInstantWithdrawAtUnderlyingHeldByATokenWhenItIsBelowVirtualBalance() external {
        // given - virtual accounting is on, the underlying held by the aToken is the lower limit
        _underlying.mint(address(_aToken), 200e6);
        _aave.setVirtualAccounting(true, 700e6);

        // when
        _vault.instantWithdraw(_params(800e6));

        // then
        assertEq(_underlying.balanceOf(address(_vault)), 200e6, "capped at the underlying held by the aToken");
    }

    function testShouldWithdrawTheWholeRequestWhenLiquidityCoversIt() external {
        // given
        _underlying.mint(address(_aToken), 900e6);
        _aave.setVirtualAccounting(true, 900e6);

        // when
        _vault.instantWithdraw(_params(800e6));

        // then
        assertEq(_underlying.balanceOf(address(_vault)), 800e6, "request below the liquidity is paid in full");
    }

    function testShouldStillCapAtThePositionWhenLiquidityIsHigher() external {
        // given
        _underlying.mint(address(_aToken), 5_000e6);
        _aave.setVirtualAccounting(true, 5_000e6);

        // when
        _vault.instantWithdraw(_params(5_000e6));

        // then
        assertEq(_underlying.balanceOf(address(_vault)), POSITION, "capped at the aToken balance of the vault");
    }

    function testShouldNotCallThePoolWhenLiquidityIsZero() external {
        // given - a fully utilized reserve
        _aave.setVirtualAccounting(true, 0);
        _underlying.mint(address(_aToken), 500e6);

        // then
        vm.expectCall(address(_aave), abi.encodeWithSignature("withdraw(address,uint256,address)"), 0);

        // when
        vm.recordLogs();
        _vault.instantWithdraw(_params(800e6));

        // then - neither an Exit nor an ExitFailed event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, _failedTopic()), 0, "no ExitFailed event");
        assertEq(_countEvents(logs, _exitTopic()), 0, "no Exit event");
        assertEq(_underlying.balanceOf(address(_vault)), 0, "nothing withdrawn");
    }

    function testShouldNotReadLiquidityForZeroAmount() external {
        // then
        vm.expectCall(address(_aave), abi.encodeWithSignature("getConfiguration(address)"), 0);

        // when
        _vault.instantWithdraw(_params(0));
    }

    function testShouldRevertInstantWithdrawWhenLiquidityReadFails() external {
        // given - the reads are outside the try block (fail closed)
        _aave.setConfigurationReverts(true);

        // when / then
        vm.expectRevert(MockAaveV3Environment.ConfigurationReverts.selector);
        _vault.instantWithdraw(_params(800e6));
    }

    function testShouldKeepAlphaExitUncappedAndRevertAboveLiquidity() external {
        // given
        _underlying.mint(address(_aToken), 300e6);
        _aave.setVirtualAccounting(true, 300e6);

        // then - the ALPHA exit asks the pool for the full amount and the pool reverts
        vm.expectCall(
            address(_aave),
            abi.encodeWithSignature("withdraw(address,uint256,address)", address(_underlying), 800e6, address(_vault)),
            1
        );
        vm.expectCall(address(_aave), abi.encodeWithSignature("getConfiguration(address)"), 0);
        vm.expectRevert(MockAaveV3Environment.InsufficientLiquidity.selector);

        // when
        _vault.exitAaveV3Supply(AaveV3SupplyFuseExitData({asset: address(_underlying), amount: 800e6}));
    }

    function _params(uint256 amount_) private view returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(amount_);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(address(_underlying));
    }

    function _failedTopic() private pure returns (bytes32) {
        return keccak256("AaveV3SupplyFuseExitFailed(address,address,uint256)");
    }

    function _exitTopic() private pure returns (bytes32) {
        return keccak256("AaveV3SupplyFuseExit(address,address,uint256)");
    }

    function _countEvents(Vm.Log[] memory logs_, bytes32 topic_) private view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(_vault) && logs_[i].topics[0] == topic_) ++count;
        }
    }
}
