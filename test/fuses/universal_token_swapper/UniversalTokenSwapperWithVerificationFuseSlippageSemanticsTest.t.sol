// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SwapExecutorEth} from "../../../contracts/fuses/universal_token_swapper/SwapExecutorEth.sol";
import {
    UniversalTokenSwapperWithVerificationFuse,
    UniversalTokenSwapperWithVerificationEnterData,
    UniversalTokenSwapperWithVerificationData,
    UniversalTokenSwapperSubstrate
} from "../../../contracts/fuses/universal_token_swapper/UniversalTokenSwapperWithVerificationFuse.sol";
import {
    SwapPinToken,
    SwapPinWeth,
    SwapPinOracle,
    SwapPinPool,
    SwapPinHost
} from "./SwapExecutorEthOpenCallerBoundTest.t.sol";

/// @title UniversalTokenSwapperWithVerificationFuseSlippageSemanticsTest
/// @notice IL-9668 (L37), pinning test: the constructor argument (renamed from slippageReverse_ to slippageWad_) is a
///         plain slippage tolerance in WAD; SLIPPAGE_REVERSE() = 1e18 - argument. The rename changes no behaviour, so
///         these tests pass on the base commit.
contract UniversalTokenSwapperWithVerificationFuseSlippageSemanticsTest is Test {
    uint256 private constant _MARKET_ID = 9;
    uint256 private constant _AMOUNT_IN = 1_000e6;

    SwapPinToken private _tokenIn;
    SwapPinToken private _tokenOut;
    SwapPinPool private _pool;
    SwapExecutorEth private _executor;
    SwapPinHost private _host;

    function setUp() public {
        _tokenIn = new SwapPinToken("In", "IN");
        _tokenOut = new SwapPinToken("Out", "OUT");
        _pool = new SwapPinPool(address(_tokenOut));
        _executor = new SwapExecutorEth(address(new SwapPinWeth()));
        _host = new SwapPinHost();

        _tokenOut.mint(address(_pool), 1_000_000e6);
        _tokenIn.mint(address(_host), 100 * _AMOUNT_IN);
        _host.setOracle(address(new SwapPinOracle()));
    }

    function testFuzzShouldStoreReverseAsOneMinusArgument(uint256 slippageWad_) external {
        slippageWad_ = bound(slippageWad_, 0, 1e18);

        UniversalTokenSwapperWithVerificationFuse fuse = new UniversalTokenSwapperWithVerificationFuse(
            _MARKET_ID,
            address(_executor),
            slippageWad_
        );

        assertEq(fuse.SLIPPAGE_REVERSE(), 1e18 - slippageWad_, "SLIPPAGE_REVERSE = 1e18 - arg");
    }

    function testShouldRevertConstructorWhenArgumentAboveOneWad() external {
        vm.expectRevert(UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseSlippageFail.selector);
        new UniversalTokenSwapperWithVerificationFuse(_MARKET_ID, address(_executor), 1e18 + 1);
    }

    function testShouldPassSwapWhenLossEqualsArgument() external {
        UniversalTokenSwapperWithVerificationFuse fuse = _deploy(1e16); // 1%

        _swap(fuse, 990e6); // out = in - 1%

        assertEq(_tokenOut.balanceOf(address(_host)), 990e6, "vault tokenOut");
    }

    function testShouldRevertSwapWhenLossExceedsArgument() external {
        UniversalTokenSwapperWithVerificationFuse fuse = _deploy(1e16); // 1%

        vm.expectRevert(UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseSlippageFail.selector);
        _swap(fuse, 990e6 - 1); // one raw unit more than 1%
    }

    function testShouldDisableUsdCheckWhenArgumentIsOneWad() external {
        UniversalTokenSwapperWithVerificationFuse fuse = _deploy(1e18);

        _swap(fuse, 1); // 99.9999% loss still passes

        assertEq(_tokenOut.balanceOf(address(_host)), 1, "vault tokenOut");
    }

    function testShouldRevertWhenNothingReceivedEvenIfCheckDisabled() external {
        UniversalTokenSwapperWithVerificationFuse fuse = _deploy(1e18);

        vm.expectRevert(UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseSlippageFail.selector);
        _swap(fuse, 0);
    }

    function _deploy(uint256 slippageWad_) private returns (UniversalTokenSwapperWithVerificationFuse fuse) {
        fuse = new UniversalTokenSwapperWithVerificationFuse(_MARKET_ID, address(_executor), slippageWad_);
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = fuse.toBytes32(UniversalTokenSwapperSubstrate(bytes4(0), address(_tokenIn)));
        substrates[1] = fuse.toBytes32(UniversalTokenSwapperSubstrate(bytes4(0), address(_tokenOut)));
        substrates[2] = fuse.toBytes32(UniversalTokenSwapperSubstrate(ERC20.transfer.selector, address(_tokenIn)));
        substrates[3] = fuse.toBytes32(UniversalTokenSwapperSubstrate(SwapPinPool.payout.selector, address(_pool)));
        _host.grantSubstrates(_MARKET_ID, substrates);
    }

    /// @dev [tokenIn.transfer(pool, amountIn), pool.payout(amountOut)]
    function _swap(UniversalTokenSwapperWithVerificationFuse fuse_, uint256 amountOut_) private {
        address[] memory targets = new address[](2);
        bytes[] memory callDatas = new bytes[](2);
        targets[0] = address(_tokenIn);
        callDatas[0] = abi.encodeCall(ERC20.transfer, (address(_pool), _AMOUNT_IN));
        targets[1] = address(_pool);
        callDatas[1] = abi.encodeCall(SwapPinPool.payout, (amountOut_));

        _host.run(
            address(fuse_),
            abi.encodeCall(
                UniversalTokenSwapperWithVerificationFuse.enter,
                (
                    UniversalTokenSwapperWithVerificationEnterData({
                        tokenIn: address(_tokenIn),
                        tokenOut: address(_tokenOut),
                        amountIn: _AMOUNT_IN,
                        data: UniversalTokenSwapperWithVerificationData({
                            targets: targets,
                            callDatas: callDatas,
                            ethAmounts: new uint256[](2),
                            tokensDustToCheck: new address[](0)
                        })
                    })
                )
            )
        );
    }
}
