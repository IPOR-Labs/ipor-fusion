// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {
    SwapExecutorEth,
    SwapExecutorEthData
} from "../../../contracts/fuses/universal_token_swapper/SwapExecutorEth.sol";
import {
    UniversalTokenSwapperEthFuseNoSlippage,
    UniversalTokenSwapperEthEnterDataNoSlippage,
    UniversalTokenSwapperEthDataNoSlippage
} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperEthFuseNoSlippage.sol";
import {
    UniversalTokenSwapperWithVerificationFuse,
    UniversalTokenSwapperWithVerificationEnterData,
    UniversalTokenSwapperWithVerificationData,
    UniversalTokenSwapperSubstrate
} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperWithVerificationFuse.sol";

/// @dev Mintable ERC20 with 6 decimals (stand-in for USDC / USDT).
contract SwapPinToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Minimal WETH: deposit() mints the sent ETH one-to-one.
contract SwapPinWeth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev Price oracle returning 1.00 USD (8 decimals) for every asset.
contract SwapPinOracle {
    function getAssetPrice(address) external pure returns (uint256, uint256) {
        return (1e8, 8);
    }
}

/// @dev Honest pool: pays out tokenOut to msg.sender (the executor) for tokenIn that it received beforehand.
contract SwapPinPool {
    ERC20 public immutable TOKEN_OUT;

    constructor(address tokenOut_) {
        TOKEN_OUT = ERC20(tokenOut_);
    }

    function payout(uint256 amount_) external {
        TOKEN_OUT.transfer(msg.sender, amount_);
    }
}

/// @dev A granted target that hands control to foreign code: it spends an allowance that a stranger left on the
///      executor and forwards the tokens to the stranger.
contract SwapPinControlHandingTarget {
    function grab(address token_, address from_, address to_, uint256 amount_) external {
        ERC20(token_).transferFrom(from_, to_, amount_);
    }
}

/// @dev Stands in for the vault: the fuses are delegatecalled so that substrates and the oracle live here.
contract SwapPinHost {
    function grantAssets(uint256 marketId_, address[] calldata assets_) external {
        PlasmaVaultConfigLib.grantSubstratesAsAssetsToMarket(marketId_, assets_);
    }

    function grantSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function setOracle(address oracle_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
    }

    function run(address fuse_, bytes calldata data_) external returns (bytes memory) {
        (bool ok, bytes memory ret) = fuse_.delegatecall(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @title SwapExecutorEthOpenCallerBoundTest
/// @notice IL-9650 (L19), pinning test: SwapExecutorEth.execute() is open to any caller by design (shared executor,
///         IL-7946). The executor is empty between swaps, so a stranger gets nothing from it. A stranger can leave an
///         allowance on it; a granted target that hands control to foreign code can then spend it during a vault swap.
///         With UniversalTokenSwapperWithVerificationFuse the loss is bounded by the slippage band, with
///         UniversalTokenSwapperEthFuseNoSlippage it is not bounded. These tests describe the accepted behaviour and
///         pass on the base commit.
contract SwapExecutorEthOpenCallerBoundTest is Test {
    uint256 private constant _MARKET_ID = 7;
    uint256 private constant _AMOUNT_IN = 1_000e6;
    uint256 private constant _SLIPPAGE = 1e16; // 1%

    SwapPinToken private _tokenIn;
    SwapPinToken private _tokenOut;
    SwapPinToken private _dust;
    SwapPinWeth private _weth;
    SwapPinPool private _pool;
    SwapPinControlHandingTarget private _hook;
    SwapExecutorEth private _executor;
    SwapPinHost private _host;
    UniversalTokenSwapperWithVerificationFuse private _verifiedFuse;
    UniversalTokenSwapperEthFuseNoSlippage private _noSlippageFuse;

    address private _stranger = makeAddr("stranger");

    function setUp() public {
        _tokenIn = new SwapPinToken("In", "IN");
        _tokenOut = new SwapPinToken("Out", "OUT");
        _dust = new SwapPinToken("Dust", "DUST");
        _weth = new SwapPinWeth();
        _pool = new SwapPinPool(address(_tokenOut));
        _hook = new SwapPinControlHandingTarget();
        _executor = new SwapExecutorEth(address(_weth));
        _host = new SwapPinHost();
        _verifiedFuse = new UniversalTokenSwapperWithVerificationFuse(_MARKET_ID, address(_executor), _SLIPPAGE);
        _noSlippageFuse = new UniversalTokenSwapperEthFuseNoSlippage(_MARKET_ID, address(_executor));

        _tokenOut.mint(address(_pool), 1_000_000e6);
        _tokenIn.mint(address(_host), 10 * _AMOUNT_IN);
        _host.setOracle(address(new SwapPinOracle()));
    }

    // ----------------------------------------------------------------------------------------------------------
    // 1. A swap leaves nothing on the executor, so an open execute() gives a stranger nothing
    // ----------------------------------------------------------------------------------------------------------

    function testShouldLeaveExecutorEmptyAfterVaultSwapAndGiveStrangerNothing() external {
        _grantVerified(false);

        _verifiedEnter(_honestRoute(_AMOUNT_IN, _AMOUNT_IN));

        assertEq(_tokenIn.balanceOf(address(_executor)), 0, "tokenIn left on executor");
        assertEq(_tokenOut.balanceOf(address(_executor)), 0, "tokenOut left on executor");
        assertEq(_dust.balanceOf(address(_executor)), 0, "dust left on executor");
        assertEq(_weth.balanceOf(address(_executor)), 0, "weth left on executor");
        assertEq(address(_executor).balance, 0, "ETH left on executor");
        assertEq(_tokenOut.balanceOf(address(_host)), _AMOUNT_IN, "vault did not receive tokenOut");

        // when: a stranger calls the open execute() on the now empty executor
        vm.prank(_stranger);
        (uint256 inReturned, uint256 outReturned) = _executor.execute(_emptyExecutorData());

        // then
        assertEq(inReturned, 0, "stranger got tokenIn");
        assertEq(outReturned, 0, "stranger got tokenOut");
        assertEq(_tokenIn.balanceOf(_stranger), 0, "stranger balance tokenIn");
        assertEq(_tokenOut.balanceOf(_stranger), 0, "stranger balance tokenOut");
        assertEq(_dust.balanceOf(_stranger), 0, "stranger balance dust");
        assertEq(_stranger.balance, 0, "stranger balance ETH");
    }

    function testShouldLeaveExecutorEmptyAfterNoSlippageSwap() external {
        _grantNoSlippage();

        _noSlippageEnter(_honestRoute(_AMOUNT_IN, _AMOUNT_IN));

        assertEq(_tokenIn.balanceOf(address(_executor)), 0, "tokenIn left on executor");
        assertEq(_tokenOut.balanceOf(address(_executor)), 0, "tokenOut left on executor");
        assertEq(_dust.balanceOf(address(_executor)), 0, "dust left on executor");
        assertEq(address(_executor).balance, 0, "ETH left on executor");
        assertEq(_tokenOut.balanceOf(address(_host)), _AMOUNT_IN, "vault did not receive tokenOut");
    }

    // ----------------------------------------------------------------------------------------------------------
    // 2. Stranger allowance + a control-handing granted target: loss bounded by the band (verification fuse)
    // ----------------------------------------------------------------------------------------------------------

    function testShouldRevertWhenStrangerAllowanceDrainsAboveBand() external {
        _grantVerified(true);
        _strangerLeavesAllowanceOnExecutor();

        // loss of exactly band + 1 raw unit (1% of 1_000e6 is 10e6)
        uint256 loss = (_AMOUNT_IN * _SLIPPAGE) / 1e18 + 1;

        vm.expectRevert(UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseSlippageFail.selector);
        _verifiedEnter(_drainRoute(loss));

        assertEq(_tokenIn.balanceOf(_stranger), 0, "stranger kept funds despite revert");
        assertEq(_tokenIn.balanceOf(address(_host)), 10 * _AMOUNT_IN, "vault tokenIn changed despite revert");
    }

    function testShouldBoundStrangerAllowanceLossByBandInsideBand() external {
        _grantVerified(true);
        _strangerLeavesAllowanceOnExecutor();

        // loss of exactly the band: accepted, this is the accepted bound of IL-9416
        uint256 loss = (_AMOUNT_IN * _SLIPPAGE) / 1e18;

        _verifiedEnter(_drainRoute(loss));

        assertEq(_tokenIn.balanceOf(_stranger), loss, "stranger should capture exactly the loss");
        assertEq(_tokenOut.balanceOf(address(_host)), _AMOUNT_IN - loss, "vault tokenOut");
        assertEq(_tokenIn.balanceOf(address(_host)), 9 * _AMOUNT_IN, "vault spent the full amountIn");
    }

    // ----------------------------------------------------------------------------------------------------------
    // 3. NoSlippage variant: no bound at all
    // ----------------------------------------------------------------------------------------------------------

    function testShouldNotBoundLossInNoSlippageVariant() external {
        _grantNoSlippage();
        _strangerLeavesAllowanceOnExecutor();

        // 90% of the amount is taken by the stranger and the swap still succeeds
        uint256 loss = (_AMOUNT_IN * 90) / 100;

        _noSlippageEnter(_drainRoute(loss));

        assertEq(_tokenIn.balanceOf(_stranger), loss, "stranger should capture the loss");
        assertEq(_tokenOut.balanceOf(address(_host)), _AMOUNT_IN - loss, "vault tokenOut");
    }

    // ----------------------------------------------------------------------------------------------------------
    // helpers
    // ----------------------------------------------------------------------------------------------------------

    struct Route {
        address[] targets;
        bytes[] callDatas;
    }

    /// @dev [tokenIn.transfer(pool, inAmount), pool.payout(outAmount)]
    function _honestRoute(uint256 inAmount_, uint256 outAmount_) private view returns (Route memory r) {
        r.targets = new address[](2);
        r.callDatas = new bytes[](2);
        r.targets[0] = address(_tokenIn);
        r.callDatas[0] = abi.encodeCall(ERC20.transfer, (address(_pool), inAmount_));
        r.targets[1] = address(_pool);
        r.callDatas[1] = abi.encodeCall(SwapPinPool.payout, (outAmount_));
    }

    /// @dev [hook.grab(tokenIn, executor, stranger, loss), tokenIn.transfer(pool, amountIn - loss), pool.payout(same)]
    function _drainRoute(uint256 loss_) private view returns (Route memory r) {
        r.targets = new address[](3);
        r.callDatas = new bytes[](3);
        r.targets[0] = address(_hook);
        r.callDatas[0] = abi.encodeCall(
            SwapPinControlHandingTarget.grab,
            (address(_tokenIn), address(_executor), _stranger, loss_)
        );
        r.targets[1] = address(_tokenIn);
        r.callDatas[1] = abi.encodeCall(ERC20.transfer, (address(_pool), _AMOUNT_IN - loss_));
        r.targets[2] = address(_pool);
        r.callDatas[2] = abi.encodeCall(SwapPinPool.payout, (_AMOUNT_IN - loss_));
    }

    function _emptyExecutorData() private view returns (SwapExecutorEthData memory) {
        address[] memory dust = new address[](1);
        dust[0] = address(_dust);
        return
            SwapExecutorEthData({
                tokenIn: address(_tokenIn),
                tokenOut: address(_tokenOut),
                targets: new address[](0),
                callDatas: new bytes[](0),
                ethAmounts: new uint256[](0),
                tokensDustToCheck: dust
            });
    }

    /// @dev the stranger uses the open execute() to approve the control-handing target on the executor
    function _strangerLeavesAllowanceOnExecutor() private {
        address[] memory targets = new address[](1);
        bytes[] memory callDatas = new bytes[](1);
        targets[0] = address(_tokenIn);
        callDatas[0] = abi.encodeCall(ERC20.approve, (address(_hook), type(uint256).max));

        vm.prank(_stranger);
        _executor.execute(
            SwapExecutorEthData({
                tokenIn: address(_tokenIn),
                tokenOut: address(_tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: new uint256[](1),
                tokensDustToCheck: new address[](0)
            })
        );
        assertEq(_tokenIn.allowance(address(_executor), address(_hook)), type(uint256).max, "allowance not left");
    }

    function _grantVerified(bool withHook_) private {
        bytes4 transferSel = ERC20.transfer.selector;
        bytes32[] memory substrates = new bytes32[](withHook_ ? 6 : 5);
        substrates[0] = _verifiedFuse.toBytes32(UniversalTokenSwapperSubstrate(bytes4(0), address(_tokenIn)));
        substrates[1] = _verifiedFuse.toBytes32(UniversalTokenSwapperSubstrate(bytes4(0), address(_tokenOut)));
        substrates[2] = _verifiedFuse.toBytes32(UniversalTokenSwapperSubstrate(bytes4(0), address(_dust)));
        substrates[3] = _verifiedFuse.toBytes32(UniversalTokenSwapperSubstrate(transferSel, address(_tokenIn)));
        substrates[4] = _verifiedFuse.toBytes32(
            UniversalTokenSwapperSubstrate(SwapPinPool.payout.selector, address(_pool))
        );
        if (withHook_) {
            substrates[5] = _verifiedFuse.toBytes32(
                UniversalTokenSwapperSubstrate(SwapPinControlHandingTarget.grab.selector, address(_hook))
            );
        }
        _host.grantSubstrates(_MARKET_ID, substrates);
    }

    function _grantNoSlippage() private {
        address[] memory assets = new address[](5);
        assets[0] = address(_tokenIn);
        assets[1] = address(_tokenOut);
        assets[2] = address(_dust);
        assets[3] = address(_pool);
        assets[4] = address(_hook);
        _host.grantAssets(_MARKET_ID, assets);
    }

    function _verifiedEnter(Route memory r_) private {
        address[] memory dust = new address[](1);
        dust[0] = address(_dust);
        _host.run(
            address(_verifiedFuse),
            abi.encodeCall(
                UniversalTokenSwapperWithVerificationFuse.enter,
                (
                    UniversalTokenSwapperWithVerificationEnterData({
                        tokenIn: address(_tokenIn),
                        tokenOut: address(_tokenOut),
                        amountIn: _AMOUNT_IN,
                        data: UniversalTokenSwapperWithVerificationData({
                            targets: r_.targets,
                            callDatas: r_.callDatas,
                            ethAmounts: new uint256[](r_.targets.length),
                            tokensDustToCheck: dust
                        })
                    })
                )
            )
        );
    }

    function _noSlippageEnter(Route memory r_) private {
        address[] memory dust = new address[](1);
        dust[0] = address(_dust);
        _host.run(
            address(_noSlippageFuse),
            abi.encodeCall(
                UniversalTokenSwapperEthFuseNoSlippage.enter,
                (
                    UniversalTokenSwapperEthEnterDataNoSlippage({
                        tokenIn: address(_tokenIn),
                        tokenOut: address(_tokenOut),
                        amountIn: _AMOUNT_IN,
                        data: UniversalTokenSwapperEthDataNoSlippage({
                            targets: r_.targets,
                            callDatas: r_.callDatas,
                            ethAmounts: new uint256[](r_.targets.length),
                            tokensDustToCheck: dust
                        })
                    })
                )
            )
        );
    }
}
