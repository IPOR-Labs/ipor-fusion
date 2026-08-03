// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {FuseAction, PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";

import {UniswapV4TestBase, IPermit2View} from "./UniswapV4TestBase.sol";
import {
    UniswapV4NewPositionFuse,
    UniswapV4NewPositionFuseEnterData,
    UniswapV4NewPositionFuseExitData
} from "../../../contracts/fuses/uniswap/UniswapV4NewPositionFuse.sol";
import {
    UniswapV4ModifyPositionFuse,
    UniswapV4ModifyPositionFuseEnterData,
    UniswapV4ModifyPositionFuseExitData
} from "../../../contracts/fuses/uniswap/UniswapV4ModifyPositionFuse.sol";
import {
    UniswapV4CollectFuse,
    UniswapV4CollectFuseEnterData
} from "../../../contracts/fuses/uniswap/UniswapV4CollectFuse.sol";
import {UniswapV4SubstrateLib} from "../../../contracts/fuses/uniswap/UniswapV4SubstrateLib.sol";
import {IPositionManagerV4} from "../../../contracts/fuses/uniswap/ext/v4/IPositionManagerV4.sol";

contract UniswapV4PositionFuseTest is UniswapV4TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------
    // constructor validation
    // ------------------------------------------------------------------

    function testShouldRevertConstructorsOnZeroAddress() external {
        vm.expectRevert(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseInvalidAddress.selector);
        new UniswapV4NewPositionFuse(1, address(0), POOL_MANAGER, PERMIT2);

        vm.expectRevert(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseInvalidAddress.selector);
        new UniswapV4NewPositionFuse(1, POSITION_MANAGER, address(0), PERMIT2);

        vm.expectRevert(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseInvalidAddress.selector);
        new UniswapV4NewPositionFuse(1, POSITION_MANAGER, POOL_MANAGER, address(0));

        vm.expectRevert(UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseInvalidAddress.selector);
        new UniswapV4ModifyPositionFuse(1, address(0), POOL_MANAGER, PERMIT2);

        vm.expectRevert(UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseInvalidAddress.selector);
        new UniswapV4ModifyPositionFuse(1, POSITION_MANAGER, address(0), PERMIT2);

        vm.expectRevert(UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseInvalidAddress.selector);
        new UniswapV4ModifyPositionFuse(1, POSITION_MANAGER, POOL_MANAGER, address(0));

        vm.expectRevert(UniswapV4CollectFuse.UniswapV4CollectFuseInvalidAddress.selector);
        new UniswapV4CollectFuse(1, address(0));
    }

    // ------------------------------------------------------------------
    // storage slot sanity
    // ------------------------------------------------------------------

    function testUniswapV4TokenIdsSlotMatchesErc7201Formula() external {
        // the literal used in FuseStorageLib.UNISWAP_V4_TOKEN_IDS must equal the ERC-7201 formula
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("io.ipor.UniswapV4TokenIds")) - 1)) &
            ~bytes32(uint256(0xff));
        assertEq(
            expected,
            bytes32(0xa0cb9820b479943d568ab227efebaab415b98a8a6852b9c25e27d9ce5c481900),
            "ERC-7201 slot literal"
        );
    }

    // ------------------------------------------------------------------
    // Scenario 1 — open position (enter)
    // ------------------------------------------------------------------

    function testShouldOpenNewPositionWethUsdc() external {
        // given
        uint256 expectedTokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();
        uint256 wethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        // when
        vm.recordLogs();
        _executeEnterNewPosition(
            UniswapV4NewPositionFuseEnterData({
                poolKey: _wethUsdcKey,
                tickLower: _alignTick(currentTick - 1000, 10),
                tickUpper: _alignTick(currentTick + 1000, 10),
                amount0Desired: 1e18,
                amount1Desired: 3_000e6,
                amount0Max: 2e18,
                amount1Max: 6_000e6,
                hookData: bytes(""),
                deadline: block.timestamp + 100
            })
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _extractNewPositionEnterEvent(entries);

        assertEq(tokenId, expectedTokenId, "tokenId should equal pre-read nextTokenId");
        assertGt(liquidity, 0, "liquidity minted");
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId), _plasmaVault, "vault owns the NFT");
        assertEq(_positionLiquidity(tokenId), liquidity, "position liquidity matches event");

        assertEq(wethBefore - ERC20(WETH).balanceOf(_plasmaVault), amount0, "amount0 equals vault WETH delta");
        assertEq(usdcBefore - ERC20(USDC).balanceOf(_plasmaVault), amount1, "amount1 equals vault USDC delta");
        assertLe(amount0, 2e18, "amount0 within amount0Max");
        assertLe(amount1, 6_000e6, "amount1 within amount1Max");

        uint256 marketBalance = _v4MarketBalance();
        uint256 expected = _valueInUnderlying(WETH, amount0) + _valueInUnderlying(USDC, amount1);
        assertApproxEqRel(marketBalance, expected, 0.01e18, "market balance approx deposited value");
    }

    function testShouldOpenNewPositionUsdcCbbtc() external {
        // given
        uint256 expectedTokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();

        // when
        vm.recordLogs();
        uint256 tokenId = _openPosition(_usdcCbbtcKey, 1000, 5_000e6, 5e6);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (uint256 eventTokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = _extractNewPositionEnterEvent(
            entries
        );

        assertEq(tokenId, expectedTokenId, "tokenId equals pre-read nextTokenId");
        assertEq(eventTokenId, tokenId, "event tokenId");
        assertGt(liquidity, 0, "liquidity minted");
        assertGt(amount0, 0, "USDC spent");
        assertGt(amount1, 0, "cbBTC spent");
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId), _plasmaVault, "vault owns the NFT");

        uint256 expected = _valueInUnderlying(USDC, amount0) + _valueInUnderlying(CBBTC, amount1);
        assertApproxEqRel(_v4MarketBalance(), expected, 0.01e18, "market balance approx deposited value");
    }

    function testShouldOpenTwoPositionsSamePool() external {
        // when
        uint256 tokenId1 = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint256 tokenId2 = _openPosition(_wethUsdcKey, 2000, 2e18, 6_000e6);

        // then
        assertEq(tokenId2, tokenId1 + 1, "sequential tokenIds");
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId1), _plasmaVault, "vault owns first NFT");
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId2), _plasmaVault, "vault owns second NFT");
        assertGt(_v4MarketBalance(), 0, "market balance covers both positions");
    }

    function testShouldOpenPositionsInTwoPools() external {
        // when
        _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        _openPosition(_usdcCbbtcKey, 1000, 5_000e6, 5e6);

        // then
        assertGt(_v4MarketBalance(), _valueInUnderlying(USDC, 5_000e6), "market balance covers both pools");
    }

    // ------------------------------------------------------------------
    // Scenario 6 — substrate gating
    // ------------------------------------------------------------------

    function testShouldRevertOpenWhenPoolIdNotGranted() external {
        // given: same tokens but a non-granted fee tier => different PoolId
        PoolKey memory notGrantedKey = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: notGrantedKey,
                    tickLower: -100,
                    tickUpper: 100,
                    amount0Desired: 1e18,
                    amount1Desired: 3_000e6,
                    amount0Max: 2e18,
                    amount1Max: 6_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4SubstrateLib.UniswapV4UnsupportedPool.selector,
                UniswapV4SubstrateLib.poolKeyToId(notGrantedKey)
            )
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertOpenWhenTokenNotGranted() external {
        // given: cbETH/WETH pool IS granted as a pool substrate, but cbETH (currency0) is NOT granted as
        // an asset
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: _cbethWethKey,
                    tickLower: -600,
                    tickUpper: 600,
                    amount0Desired: 1e18,
                    amount1Desired: 1e18,
                    amount0Max: 2e18,
                    amount1Max: 2e18,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(abi.encodeWithSelector(UniswapV4SubstrateLib.UniswapV4UnsupportedToken.selector, CBETH));
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertOpenWhenToken1NotGranted() external {
        // given: pool substrate granted but currency1 not granted as asset
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: _usdcUngrantedToken1Key,
                    tickLower: -100,
                    tickUpper: 100,
                    amount0Desired: 1_000e6,
                    amount1Desired: 1_000e6,
                    amount0Max: 1_100e6,
                    amount1Max: 1_100e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4SubstrateLib.UniswapV4UnsupportedToken.selector, UNGRANTED_TOKEN)
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertOpenWhenNativeCurrencyPool() external {
        // given: native ETH/USDC pool (currency0 == address(0)) — out of scope in v1
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: nativeKey,
                    tickLower: -100,
                    tickUpper: 100,
                    amount0Desired: 1e18,
                    amount1Desired: 1_000e6,
                    amount0Max: 2e18,
                    amount1Max: 1_100e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(UniswapV4SubstrateLib.UniswapV4NativeCurrencyNotSupported.selector);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    // ------------------------------------------------------------------
    // slippage / validation branches
    // ------------------------------------------------------------------

    function testShouldRevertOpenWhenAmountMaxTooTight() external {
        // given: pay-limits far below what the mint requires
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: _wethUsdcKey,
                    tickLower: _alignTick(currentTick - 1000, 10),
                    tickUpper: _alignTick(currentTick + 1000, 10),
                    amount0Desired: 1e18,
                    amount1Desired: 3_000e6,
                    amount0Max: 1e9,
                    amount1Max: 1e3,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then — PositionManager reverts with MaximumAmountExceeded
        vm.expectRevert();
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertOpenWhenDeadlinePassed() external {
        // given: identical to a passing open except the deadline is in the past — proves the fuse
        // forwards data_.deadline to modifyLiquidities (POSM reverts DeadlinePassed)
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: _wethUsdcKey,
                    tickLower: _alignTick(currentTick - 1000, 10),
                    tickUpper: _alignTick(currentTick + 1000, 10),
                    amount0Desired: 1e18,
                    amount1Desired: 3_000e6,
                    amount0Max: 2e18,
                    amount1Max: 6_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp - 1
                })
            )
        );

        // when / then
        vm.expectRevert();
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertOpenWhenZeroLiquidity() external {
        // given: zero desired amounts produce zero liquidity
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: _wethUsdcKey,
                    tickLower: _alignTick(currentTick - 1000, 10),
                    tickUpper: _alignTick(currentTick + 1000, 10),
                    amount0Desired: 0,
                    amount1Desired: 0,
                    amount0Max: 1e9,
                    amount1Max: 1e3,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseZeroLiquidity.selector);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    // ------------------------------------------------------------------
    // Scenario 2 — close position (exit)
    // ------------------------------------------------------------------

    function testShouldClosePosition() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint256 wethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        // when
        vm.recordLogs();
        _closePosition(tokenId);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (uint256 closedTokenId, uint256 amount0, uint256 amount1) = _extractExitEvent(entries);

        assertEq(closedTokenId, tokenId, "closed tokenId");
        assertGt(amount0 + amount1, 0, "principal returned");
        assertEq(ERC20(WETH).balanceOf(_plasmaVault) - wethBefore, amount0, "vault received WETH");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault) - usdcBefore, amount1, "vault received USDC");

        // NFT burned (V4 POSM is a solmate ERC721)
        vm.expectRevert(bytes("NOT_MINTED"));
        IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId);

        assertEq(_v4MarketBalance(), 0, "market balance zero after full exit");
    }

    function testShouldClosePositionAfterSubstratesRevoked() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.UNISWAP_V4,
            new bytes32[](0)
        );

        // when
        _closePosition(tokenId);

        // then
        vm.expectRevert(bytes("NOT_MINTED"));
        IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId);
    }

    function testShouldCloseMiddlePositionOfThree() external {
        // given — exercises the swap-and-pop branch where the removed element is not the last one
        uint256 tokenId1 = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint256 tokenId2 = _openPosition(_wethUsdcKey, 2000, 1e18, 3_000e6);
        uint256 tokenId3 = _openPosition(_wethUsdcKey, 3000, 1e18, 3_000e6);

        uint256 balanceWithThree = _v4MarketBalance();

        // when — close the middle position
        _closePosition(tokenId2);

        // then
        uint256 balanceWithTwo = _v4MarketBalance();
        assertLt(balanceWithTwo, balanceWithThree, "balance decreased");
        assertGt(balanceWithTwo, 0, "remaining positions still valued");

        // remaining positions can still be closed (storage indexes intact after swap-and-pop)
        uint256[] memory rest = new uint256[](2);
        rest[0] = tokenId1;
        rest[1] = tokenId3;
        _closePositions(rest);

        assertEq(_v4MarketBalance(), 0, "market balance zero after closing all");
    }

    function testShouldRevertExitWhenTokenIdNotTracked() external {
        // given: a V4 position that does NOT belong to the vault storage
        uint256 foreignTokenId = 341_378;

        FuseAction[] memory calls = new FuseAction[](1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = foreignTokenId;
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.exit.selector,
                UniswapV4NewPositionFuseExitData({
                    tokenIds: tokenIds,
                    amount0Min: new uint256[](1),
                    amount1Min: new uint256[](1),
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.UniswapV4NewPositionFuseTokenIdNotTracked.selector,
                foreignTokenId
            )
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertExitWhenArrayLengthMismatch() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        FuseAction[] memory calls = new FuseAction[](1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.exit.selector,
                UniswapV4NewPositionFuseExitData({
                    tokenIds: tokenIds,
                    amount0Min: new uint256[](2),
                    amount1Min: new uint256[](1),
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseInvalidArrayLength.selector);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertExitWhenAmount1MinArrayLengthMismatch() external {
        // given — the second (amount1Min) length arm
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        FuseAction[] memory calls = new FuseAction[](1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.exit.selector,
                UniswapV4NewPositionFuseExitData({
                    tokenIds: tokenIds,
                    amount0Min: new uint256[](1),
                    amount1Min: new uint256[](2),
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseInvalidArrayLength.selector);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertDoubleExitOfSameTokenId() external {
        // given — position closed once; a second close must hit the tracked-tokenId guard (proves
        // swap-and-pop leaves no resurrectable stale index)
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        _openPosition(_wethUsdcKey, 2000, 1e18, 3_000e6); // second position occupies index after pop
        _closePosition(tokenId);

        FuseAction[] memory calls = new FuseAction[](1);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.exit.selector,
                UniswapV4NewPositionFuseExitData({
                    tokenIds: tokenIds,
                    amount0Min: new uint256[](1),
                    amount1Min: new uint256[](1),
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4NewPositionFuse.UniswapV4NewPositionFuseTokenIdNotTracked.selector, tokenId)
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertExitWhenAmountMinTooHigh() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        uint256[] memory amount0Min = new uint256[](1);
        amount0Min[0] = 1_000e18; // far above what the position can return
        uint256[] memory amount1Min = new uint256[](1);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.exit.selector,
                UniswapV4NewPositionFuseExitData({
                    tokenIds: tokenIds,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then — PositionManager reverts with MinimumAmountInsufficient
        vm.expectRevert();
        PlasmaVault(_plasmaVault).execute(calls);
    }

    // ------------------------------------------------------------------
    // Permit2 hygiene
    // ------------------------------------------------------------------

    function testShouldResetPermit2AllowanceAfterEnter() external {
        // when
        _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        // then — ERC20 allowance vault -> Permit2 reset to zero after the action
        assertEq(ERC20(WETH).allowance(_plasmaVault, PERMIT2), 0, "WETH allowance to Permit2 reset");
        assertEq(ERC20(USDC).allowance(_plasmaVault, PERMIT2), 0, "USDC allowance to Permit2 reset");

        // and — the Permit2-internal allowance vault -> POSM is reset as well
        (uint160 wethAmount, , ) = IPermit2View(PERMIT2).allowance(_plasmaVault, WETH, POSITION_MANAGER);
        (uint160 usdcAmount, , ) = IPermit2View(PERMIT2).allowance(_plasmaVault, USDC, POSITION_MANAGER);
        assertEq(wethAmount, 0, "Permit2-internal WETH allowance reset");
        assertEq(usdcAmount, 0, "Permit2-internal USDC allowance reset");
    }

    // ------------------------------------------------------------------
    // composite execute
    // ------------------------------------------------------------------

    function testShouldExecuteEnterIncreaseAndCollectInOneCall() external {
        // given — the realistic alpha pattern: mint + increase + collect batched in a single execute
        uint256 expectedTokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        uint256[] memory collectIds = new uint256[](1);
        collectIds[0] = expectedTokenId;

        FuseAction[] memory calls = new FuseAction[](3);
        calls[0] = FuseAction(
            address(_newPositionFuse),
            abi.encodeWithSelector(
                UniswapV4NewPositionFuse.enter.selector,
                UniswapV4NewPositionFuseEnterData({
                    poolKey: _wethUsdcKey,
                    tickLower: _alignTick(currentTick - 1000, 10),
                    tickUpper: _alignTick(currentTick + 1000, 10),
                    amount0Desired: 1e18,
                    amount1Desired: 3_000e6,
                    amount0Max: 2e18,
                    amount1Max: 6_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );
        calls[1] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.enter.selector,
                UniswapV4ModifyPositionFuseEnterData({
                    tokenId: expectedTokenId,
                    amount0Desired: 5e17,
                    amount1Desired: 1_500e6,
                    amount0Max: 1e18,
                    amount1Max: 3_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );
        calls[2] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(collectIds))
        );

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(expectedTokenId), _plasmaVault, "minted to vault");
        assertGt(_positionLiquidity(expectedTokenId), 0, "liquidity present after mint+increase");
        assertGt(_v4MarketBalance(), 0, "market balance recalculated after composite execute");
    }

    // ------------------------------------------------------------------
    // Scenario 3 — increase / decrease liquidity
    // ------------------------------------------------------------------

    function testShouldIncreaseLiquidity() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint128 liquidityBefore = _positionLiquidity(tokenId);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 marketBalanceBefore = _v4MarketBalance();

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.enter.selector,
                UniswapV4ModifyPositionFuseEnterData({
                    tokenId: tokenId,
                    amount0Desired: 5e17,
                    amount1Desired: 1_500e6,
                    amount0Max: 1e18,
                    amount1Max: 3_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertGt(_positionLiquidity(tokenId), liquidityBefore, "position liquidity increased");
        assertLt(ERC20(USDC).balanceOf(_plasmaVault), usdcBefore, "vault spent USDC");
        assertGt(_v4MarketBalance(), marketBalanceBefore, "market balance increased");
        assertEq(ERC20(USDC).allowance(_plasmaVault, PERMIT2), 0, "USDC allowance to Permit2 reset");
    }

    function testShouldRevertIncreaseWhenZeroLiquidity() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.enter.selector,
                UniswapV4ModifyPositionFuseEnterData({
                    tokenId: tokenId,
                    amount0Desired: 0,
                    amount1Desired: 0,
                    amount0Max: 1e9,
                    amount1Max: 1e3,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseZeroLiquidity.selector);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldDecreaseLiquidity() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 2e18, 6_000e6);
        uint128 liquidityBefore = _positionLiquidity(tokenId);
        uint256 wethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.exit.selector,
                UniswapV4ModifyPositionFuseExitData({
                    tokenId: tokenId,
                    liquidity: liquidityBefore / 2,
                    amount0Min: 0,
                    amount1Min: 0,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then — V4 decrease transfers funds to the vault within the same call (unlike V3)
        assertEq(_positionLiquidity(tokenId), liquidityBefore - liquidityBefore / 2, "liquidity halved");
        assertGt(
            ERC20(WETH).balanceOf(_plasmaVault) + ERC20(USDC).balanceOf(_plasmaVault),
            wethBefore + usdcBefore,
            "vault received tokens"
        );
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId), _plasmaVault, "NFT still owned by vault");
    }

    function testShouldDecreaseLiquidityAfterSubstratesRevoked() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 2e18, 6_000e6);
        uint128 liquidityBefore = _positionLiquidity(tokenId);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.UNISWAP_V4,
            new bytes32[](0)
        );

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.exit.selector,
                UniswapV4ModifyPositionFuseExitData({
                    tokenId: tokenId,
                    liquidity: liquidityBefore / 2,
                    amount0Min: 0,
                    amount1Min: 0,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertEq(_positionLiquidity(tokenId), liquidityBefore - liquidityBefore / 2, "liquidity decreased");
    }

    function testShouldDecreaseCappedAtPositionLiquidity() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.exit.selector,
                UniswapV4ModifyPositionFuseExitData({
                    tokenId: tokenId,
                    liquidity: type(uint128).max, // requested more than the position holds
                    amount0Min: 0,
                    amount1Min: 0,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then — capped at position liquidity, position empty but NFT alive
        assertEq(_positionLiquidity(tokenId), 0, "all liquidity removed");
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId), _plasmaVault, "NFT not burned");
        // zero-liquidity position still tracked in storage but valued at zero by the balance fuse
        assertEq(_v4MarketBalance(), 0, "zero-liquidity position valued at zero");
    }

    function testShouldRevertDecreaseWhenAmountMinTooHigh() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint128 liquidity = _positionLiquidity(tokenId);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.exit.selector,
                UniswapV4ModifyPositionFuseExitData({
                    tokenId: tokenId,
                    liquidity: liquidity / 2,
                    amount0Min: 1_000e18,
                    amount1Min: 1_000_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert();
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertModifyEnterWhenTokenIdNotTracked() external {
        // given — a foreign position id (not minted by the vault's fuse)
        uint256 foreignTokenId = 341_378;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.enter.selector,
                UniswapV4ModifyPositionFuseEnterData({
                    tokenId: foreignTokenId,
                    amount0Desired: 1e18,
                    amount1Desired: 1e18,
                    amount0Max: 2e18,
                    amount1Max: 2e18,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then — only tokenIds registered by the vault's NewPositionFuse can be modified
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseTokenIdNotTracked.selector,
                foreignTokenId
            )
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertModifyEnterOnForeignPositionInGrantedPool() external {
        // given — an attacker-owned position in a WHITELISTED pool (INCREASE_LIQUIDITY is not
        // permissioned in the V4 PositionManager, so without the tracked-tokenId guard the vault's
        // funds could be added to this position and silently exfiltrated)
        uint256 foreignTokenId = _mintForeignPosition();

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.enter.selector,
                UniswapV4ModifyPositionFuseEnterData({
                    tokenId: foreignTokenId,
                    amount0Desired: 5e17,
                    amount1Desired: 1_500e6,
                    amount0Max: 1e18,
                    amount1Max: 3_000e6,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseTokenIdNotTracked.selector,
                foreignTokenId
            )
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldRevertModifyExitWhenZeroLiquidity() external {
        // given — a position whose liquidity was already fully removed
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.exit.selector,
                UniswapV4ModifyPositionFuseExitData({
                    tokenId: tokenId,
                    liquidity: type(uint128).max,
                    amount0Min: 0,
                    amount1Min: 0,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );
        PlasmaVault(_plasmaVault).execute(calls);
        assertEq(_positionLiquidity(tokenId), 0, "position emptied");

        // when / then — decreasing an empty position reverts with ZeroLiquidity (cap resolves to 0)
        vm.expectRevert(UniswapV4ModifyPositionFuse.UniswapV4ModifyPositionFuseZeroLiquidity.selector);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    // ------------------------------------------------------------------
    // Scenario 4 — collect fees
    // ------------------------------------------------------------------

    function testShouldCollectFees() external {
        // given — wide position, then swaps in both directions to accrue fees
        uint256 tokenId = _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        uint128 liquidityBefore = _positionLiquidity(tokenId);

        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);

        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 cbbtcBefore = ERC20(CBBTC).balanceOf(_plasmaVault);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (uint256 collectedTokenId, uint256 amount0, uint256 amount1) = _extractCollectEvent(entries);

        assertEq(collectedTokenId, tokenId, "collected tokenId");
        assertGt(amount0 + amount1, 0, "fees collected");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault) - usdcBefore, amount0, "vault received USDC fees");
        assertEq(ERC20(CBBTC).balanceOf(_plasmaVault) - cbbtcBefore, amount1, "vault received cbBTC fees");
        assertEq(_positionLiquidity(tokenId), liquidityBefore, "position liquidity unchanged");
    }

    function testShouldCollectFeesAfterSubstratesRevoked() external {
        // given
        uint256 tokenId = _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(
            IporFusionMarkets.UNISWAP_V4,
            new bytes32[](0)
        );

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then
        (, uint256 amount0, uint256 amount1) = _extractCollectEvent(entries);
        assertGt(amount0 + amount1, 0, "fees collected");
    }

    function testShouldCollectZeroWhenNoFees() external {
        // given — freshly minted position, no swaps
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint256 wethBefore = ERC20(WETH).balanceOf(_plasmaVault);
        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertEq(ERC20(WETH).balanceOf(_plasmaVault), wethBefore, "no WETH collected");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), usdcBefore, "no USDC collected");
    }

    function testShouldCollectFromEmptyListAsNoOp() external {
        // when / then — no revert, no transfers
        _refreshMarketBalance();
        assertEq(_v4MarketBalance(), 0, "no positions, zero balance");
    }

    function testShouldRevertCollectWhenTokenIdNotTracked() external {
        // given — foreign position id (not minted by the vault's fuse)
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 341_378;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4CollectFuse.UniswapV4CollectFuseTokenIdNotTracked.selector, 341_378)
        );
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function testShouldCollectSkipZeroLiquidityPosition() external {
        // given — a batch of [emptied position, fee-bearing position]; the empty one must be skipped
        // instead of reverting the whole batch with CannotUpdateEmptyPosition
        uint256 emptyTokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        FuseAction[] memory emptyCalls = new FuseAction[](1);
        emptyCalls[0] = FuseAction(
            address(_modifyPositionFuse),
            abi.encodeWithSelector(
                UniswapV4ModifyPositionFuse.exit.selector,
                UniswapV4ModifyPositionFuseExitData({
                    tokenId: emptyTokenId,
                    liquidity: type(uint128).max,
                    amount0Min: 0,
                    amount1Min: 0,
                    hookData: bytes(""),
                    deadline: block.timestamp + 100
                })
            )
        );
        PlasmaVault(_plasmaVault).execute(emptyCalls);

        uint256 feeTokenId = _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);

        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = emptyTokenId;
        tokenIds[1] = feeTokenId;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        // when — must not revert
        PlasmaVault(_plasmaVault).execute(calls);

        // then — fees of the live position were collected
        assertGt(ERC20(USDC).balanceOf(_plasmaVault), usdcBefore, "fees from live position collected");
    }

    function testShouldCollectFromManyPositionsAggregated() external {
        // given — two fee-bearing positions in the same pool
        uint256 tokenId1 = _openPosition(_usdcCbbtcKey, 2_000, 10_000e6, 10e6);
        uint256 tokenId2 = _openPosition(_usdcCbbtcKey, 2_000, 10_000e6, 10e6);
        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);

        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 cbbtcBefore = ERC20(CBBTC).balanceOf(_plasmaVault);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            address(_collectFuse),
            abi.encodeWithSelector(UniswapV4CollectFuse.enter.selector, UniswapV4CollectFuseEnterData(tokenIds))
        );

        // when
        vm.recordLogs();
        PlasmaVault(_plasmaVault).execute(calls);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // then — one event per position and vault deltas equal the sum over both events
        (uint256 sum0, uint256 sum1, uint256 eventCount) = _sumCollectEvents(entries);
        assertEq(eventCount, 2, "one collect event per position");
        assertGt(sum0 + sum1, 0, "fees collected");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault) - usdcBefore, sum0, "USDC delta equals summed events");
        assertEq(ERC20(CBBTC).balanceOf(_plasmaVault) - cbbtcBefore, sum1, "cbBTC delta equals summed events");
    }

    // ------------------------------------------------------------------
    // transient storage variants
    // ------------------------------------------------------------------

    function testShouldOpenAndClosePositionTransient() external {
        // given
        uint256 expectedTokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();
        (, int24 currentTick, , ) = IPoolManager(POOL_MANAGER).getSlot0(_wethUsdcKey.toId());

        address[] memory fuses = new address[](1);
        fuses[0] = address(_newPositionFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](12);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(WETH); // currency0
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(USDC); // currency1
        inputsByFuse[0][2] = TypeConversionLib.toBytes32(uint256(500)); // fee
        inputsByFuse[0][3] = TypeConversionLib.toBytes32(uint256(int256(10))); // tickSpacing
        inputsByFuse[0][4] = TypeConversionLib.toBytes32(address(0)); // hooks
        inputsByFuse[0][5] = TypeConversionLib.toBytes32(int256(_alignTick(currentTick - 1000, 10))); // tickLower
        inputsByFuse[0][6] = TypeConversionLib.toBytes32(int256(_alignTick(currentTick + 1000, 10))); // tickUpper
        inputsByFuse[0][7] = TypeConversionLib.toBytes32(uint256(1e18)); // amount0Desired
        inputsByFuse[0][8] = TypeConversionLib.toBytes32(uint256(3_000e6)); // amount1Desired
        inputsByFuse[0][9] = TypeConversionLib.toBytes32(uint256(2e18)); // amount0Max
        inputsByFuse[0][10] = TypeConversionLib.toBytes32(uint256(6_000e6)); // amount1Max
        inputsByFuse[0][11] = TypeConversionLib.toBytes32(block.timestamp + 100); // deadline

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputsByFuse})
            )
        );
        calls[1] = FuseAction(address(_newPositionFuse), abi.encodeWithSignature("enterTransient()"));

        // when — enter via transient inputs
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(expectedTokenId), _plasmaVault, "minted to vault");
        assertGt(_v4MarketBalance(), 0, "market balance positive");

        // and — exit via transient inputs: [0]=len, [1]=tokenId, [2]=amount0Min, [3]=amount1Min, [4]=deadline
        bytes32[][] memory exitInputs = new bytes32[][](1);
        exitInputs[0] = new bytes32[](5);
        exitInputs[0][0] = TypeConversionLib.toBytes32(uint256(1));
        exitInputs[0][1] = TypeConversionLib.toBytes32(expectedTokenId);
        exitInputs[0][2] = TypeConversionLib.toBytes32(uint256(0));
        exitInputs[0][3] = TypeConversionLib.toBytes32(uint256(0));
        exitInputs[0][4] = TypeConversionLib.toBytes32(block.timestamp + 100);

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: exitInputs})
            )
        );
        exitCalls[1] = FuseAction(address(_newPositionFuse), abi.encodeWithSignature("exitTransient()"));

        PlasmaVault(_plasmaVault).execute(exitCalls);

        assertEq(_v4MarketBalance(), 0, "market balance zero after transient exit");
    }

    function testShouldExitTransientWithEmptyListAsNoOp() external {
        // given — exitTransient with len == 0 must be a no-op (dedicated early-return branch)
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_newPositionFuse);
        bytes32[][] memory inputs = new bytes32[][](1);
        inputs[0] = new bytes32[](1);
        inputs[0][0] = TypeConversionLib.toBytes32(uint256(0)); // length = 0

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputs})
            )
        );
        calls[1] = FuseAction(address(_newPositionFuse), abi.encodeWithSignature("exitTransient()"));

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then — position untouched
        assertEq(IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId), _plasmaVault, "position not closed");
        assertGt(_v4MarketBalance(), 0, "market balance unchanged");
    }

    function testShouldModifyPositionTransient() external {
        // given
        uint256 tokenId = _openPosition(_wethUsdcKey, 1000, 1e18, 3_000e6);
        uint128 liquidityAfterOpen = _positionLiquidity(tokenId);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_modifyPositionFuse);

        // increase via enterTransient: [tokenId, a0Desired, a1Desired, a0Max, a1Max, deadline]
        bytes32[][] memory increaseInputs = new bytes32[][](1);
        increaseInputs[0] = new bytes32[](6);
        increaseInputs[0][0] = TypeConversionLib.toBytes32(tokenId);
        increaseInputs[0][1] = TypeConversionLib.toBytes32(uint256(5e17));
        increaseInputs[0][2] = TypeConversionLib.toBytes32(uint256(1_500e6));
        increaseInputs[0][3] = TypeConversionLib.toBytes32(uint256(1e18));
        increaseInputs[0][4] = TypeConversionLib.toBytes32(uint256(3_000e6));
        increaseInputs[0][5] = TypeConversionLib.toBytes32(block.timestamp + 100);

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: increaseInputs})
            )
        );
        calls[1] = FuseAction(address(_modifyPositionFuse), abi.encodeWithSignature("enterTransient()"));

        // when — increase
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        uint128 liquidityAfterIncrease = _positionLiquidity(tokenId);
        assertGt(liquidityAfterIncrease, liquidityAfterOpen, "liquidity increased via transient");

        // and — decrease via exitTransient: [tokenId, liquidity, a0Min, a1Min, deadline]
        bytes32[][] memory decreaseInputs = new bytes32[][](1);
        decreaseInputs[0] = new bytes32[](5);
        decreaseInputs[0][0] = TypeConversionLib.toBytes32(tokenId);
        decreaseInputs[0][1] = TypeConversionLib.toBytes32(uint256(liquidityAfterIncrease / 2));
        decreaseInputs[0][2] = TypeConversionLib.toBytes32(uint256(0));
        decreaseInputs[0][3] = TypeConversionLib.toBytes32(uint256(0));
        decreaseInputs[0][4] = TypeConversionLib.toBytes32(block.timestamp + 100);

        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: decreaseInputs})
            )
        );
        calls[1] = FuseAction(address(_modifyPositionFuse), abi.encodeWithSignature("exitTransient()"));

        PlasmaVault(_plasmaVault).execute(calls);

        assertLt(_positionLiquidity(tokenId), liquidityAfterIncrease, "liquidity decreased via transient");
    }

    function testShouldCollectTransient() external {
        // given — accrue fees on a USDC/cbBTC position
        uint256 tokenId = _openPosition(_usdcCbbtcKey, 2_000, 20_000e6, 20e6);
        _swapV4(_usdcCbbtcKey, true, 100_000e6);
        _swapV4(_usdcCbbtcKey, false, 1e8);

        uint256 usdcBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 cbbtcBefore = ERC20(CBBTC).balanceOf(_plasmaVault);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_collectFuse);
        bytes32[][] memory inputs = new bytes32[][](1);
        inputs[0] = new bytes32[](2);
        inputs[0][0] = TypeConversionLib.toBytes32(uint256(1)); // length
        inputs[0][1] = TypeConversionLib.toBytes32(tokenId);

        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fuses, inputsByFuse: inputs})
            )
        );
        calls[1] = FuseAction(address(_collectFuse), abi.encodeWithSignature("enterTransient()"));

        // when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        assertGt(
            (ERC20(USDC).balanceOf(_plasmaVault) - usdcBefore) + (ERC20(CBBTC).balanceOf(_plasmaVault) - cbbtcBefore),
            0,
            "fees collected via transient"
        );
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _sumCollectEvents(
        Vm.Log[] memory entries_
    ) private pure returns (uint256 sum0, uint256 sum1, uint256 count) {
        for (uint256 i; i < entries_.length; i++) {
            if (entries_[i].topics[0] == keccak256("UniswapV4CollectFuseEnter(address,uint256,uint256,uint256)")) {
                (, , uint256 amount0, uint256 amount1) = abi.decode(
                    entries_[i].data,
                    (address, uint256, uint256, uint256)
                );
                sum0 += amount0;
                sum1 += amount1;
                count++;
            }
        }
    }
}
