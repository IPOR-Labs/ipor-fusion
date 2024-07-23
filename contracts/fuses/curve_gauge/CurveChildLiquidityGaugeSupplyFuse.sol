// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";

// struct CurveChildLiquidityGaugeSupplyFuseEnterData {
// 	/// @notice LP Token to deposit
// 	address lpToken;
// 	/// @notice Amount of the LP Token to deposit
// 	uint256 amount;
// }

// struct CurveChildLiquidityGaugeSupplyFuseExitData {
// 	/// @notice LP Token to withdraw
// 	address lpToken;
// 	/// @notice Amount of the LP Token to withdraw
// 	uint256 amount;
// }

// contract CurveChildLiquidityGaugeSupplyFuse {
// 	using SafeERC20 for IERC20;

// 	event CurveChildLiquidityGaugeSupplyFuseEnter(
// 		address version,
// 		address lpToken,
// 		uint256 amount
// 	);

// 	event CurveChildLiquidityGaugeSupplyFuseExit(
// 		address version,
// 		address lpToken,
// 		uint256 amount
// 	);

// 	error CurveChildLiquidityGaugeSupplyFuseUnsupportedLPToken(string msg, address lpToken);
//  	error CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();

// 	uint256 public immutable MARKET_ID;
// 	address public immutable VERSION;
// 	IChildLiquidityGauge public immutable CHILD_LIQUIDITY_GAUGE;

// 	constructor(uint256 marketIdInput, address childLiquidityGauge) {
// 		VERSION = address(this);
// 		MARKET_ID = marketIdInput;
// 		CHILD_LIQUIDITY_GAUGE = IChildLiquidityGauge(childLiquidityGauge);
// 	}

// 	function enter(bytes calldata data) external override {
// 		_enter(abi.decode(data, (CurveChildLiquidityGaugeSupplyFuseEnterData)));
// 	}

// 	/// @dev technical method to generate ABI
// 	function enter(CurveChildLiquidityGaugeSupplyFuseEnterData memory data) external {
// 		_enter(data);
// 	}

// 	function _enter(CurveChildLiquidityGaugeSupplyFuseEnterData memory data) internal {
//         if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.lpToken)) {
//             revert CurveChildLiquidityGaugeSupplyFuseUnsupportedLPToken("enter", data.lpToken);
//         }
// 		IERC20(data.lpToken).forceApprove(address(CHILD_LIQUIDITY_GAUGE), data.amount);
// 		CHILD_LIQUIDITY_GAUGE.deposit(data.amount, address(this), false);
// 		emit CurveChildLiquidityGaugeSupplyFuseEnter(VERSION, data.lpToken, data.amount);
// 	}

// 	function exit(bytes calldata data) external override {
// 		_exit(abi.decode(data, (CurveChildLiquidityGaugeSupplyFuseExitData)));
// 	}

// 	/// @dev technical method to generate ABI
// 	function exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data) external {
// 		_exit(data);
// 	}

// 	function _exit(CurveChildLiquidityGaugeSupplyFuseExitData memory data) internal {
// 		if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.lpToken)) {
// 			revert CurveChildLiquidityGaugeSupplyFuseUnsupportedLPToken("exit", data.lpToken);
// 		}
// 		if (data.amount == 0) {
// 			revert CurveChildLiquidityGaugeSupplyFuseZeroWithdrawAmount();
// 		}
// 		CHILD_LIQUIDITY_GAUGE.withdraw(data.amount, address(this), false);
// 		emit CurveChildLiquidityGaugeSupplyFuseExit(VERSION, data.lpToken, data.amount);
// 	}

// }
