// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";

import {UniswapV2SwapFuse, UniswapV2SwapFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV2SwapFuse.sol";
import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {ReadResult, UniversalReader} from "../../../contracts/universal_reader/UniversalReader.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";

/// @dev Test-only reader used to inspect a fuse's transient storage outputs after `PlasmaVault.execute`
/// via `UniversalReader.read`, which delegatecalls this contract in the vault's context.
contract TransientOutputsReader {
    function readOutputs(address fuse_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getOutputs(fuse_);
    }
}

contract UniswapV2SwapFuseTest is Test {
    using SafeERC20 for ERC20;

    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);
    event UniswapV2SwapFuseEnter(address version, uint256 tokenInAmount, address[] path, uint256 minOutAmount);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address public constant UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _withdrawManager;
    UniswapV2SwapFuse private _uniswapV2SwapFuse;
    address private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20590113);

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        // price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );
        _withdrawManager = address(new WithdrawManager(address(_accessManager)));

        // plasma vault
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                USDC,
                _priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                _withdrawManager,
                address(0)
            )
        );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
        _setupRoles();
    }

    function testShouldSwapWhenOneHop() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        uint256 plasmaVaultUsdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceBefore = ERC20(USDT).balanceOf(_plasmaVault);

        //when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);

        assertEq(plasmaVaultUsdcBalanceBefore, depositAmount, "plasmaVaultUsdcBalanceBefore");
        assertEq(plasmaVaultUsdcBalanceAfter, 0, "plasmaVaultUsdcBalanceAfter");
        assertEq(plasmaVaultUsdtBalanceBefore, 0, "plasmaVaultUsdtBalanceBefore");
        assertGt(plasmaVaultUsdtBalanceAfter, 0, "plasmaVaultUsdtBalanceAfter");
    }

    function testShouldSwapWhenMultipleHop() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](3);
        path[0] = USDC;
        path[1] = DAI;
        path[2] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        uint256 plasmaVaultUsdcBalanceBefore = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceBefore = ERC20(USDT).balanceOf(_plasmaVault);

        //when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(USDC).balanceOf(_plasmaVault);
        uint256 plasmaVaultUsdtBalanceAfter = ERC20(USDT).balanceOf(_plasmaVault);

        assertEq(plasmaVaultUsdcBalanceBefore, depositAmount, "plasmaVaultUsdcBalanceBefore");
        assertEq(plasmaVaultUsdcBalanceAfter, 0, "plasmaVaultUsdcBalanceAfter");
        assertEq(plasmaVaultUsdtBalanceBefore, 0, "plasmaVaultUsdtBalanceBefore");
        assertGt(plasmaVaultUsdtBalanceAfter, 0, "plasmaVaultUsdtBalanceAfter");
    }

    /// @notice Regression for IL-7990: the event and return value must report the amount actually
    ///         swapped (clamped to the vault balance), not the raw request.
    function testShouldReportClampedAmountWhenRequestExceedsVaultBalance() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;
        // Requested amount is 2.5x the vault's balance, so the gap between "requested" and
        // "effective" cannot be mistaken for rounding noise.
        uint256 requestedAmount = 2_500e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: requestedAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        vm.recordLogs();

        //when
        PlasmaVault(_plasmaVault).execute(enterCalls);

        // then
        bytes32 enterTopic = keccak256("UniswapV2SwapFuseEnter(address,uint256,address[],uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            // The fuse runs via delegatecall from PlasmaVault, so the log's on-chain emitter is
            // the vault's address, not the fuse's.
            if (logs[i].emitter == _plasmaVault && logs[i].topics[0] == enterTopic) {
                found = true;
                (
                    address version,
                    uint256 emittedTokenInAmount,
                    address[] memory emittedPath,
                    uint256 emittedMinOutAmount
                ) = abi.decode(logs[i].data, (address, uint256, address[], uint256));
                assertEq(version, address(_uniswapV2SwapFuse), "event.version");
                // Effective amount == depositAmount (1_000e6), NOT requestedAmount (2_500e6).
                assertEq(emittedTokenInAmount, depositAmount, "event.tokenInAmount == effective amount");
                assertTrue(emittedTokenInAmount != requestedAmount, "event.tokenInAmount != requested amount");
                assertEq(emittedPath.length, path.length, "event.path.length");
                assertEq(emittedPath[0], path[0], "event.path[0]");
                assertEq(emittedPath[1], path[1], "event.path[1]");
                assertEq(emittedMinOutAmount, 0, "event.minOutAmount");
            }
        }
        assertTrue(found, "UniswapV2SwapFuseEnter must be emitted");

        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "plasmaVaultUsdcBalanceAfter");
        assertGt(ERC20(USDT).balanceOf(_plasmaVault), 0, "plasmaVaultUsdtBalanceAfter");
    }

    /// @notice Regression for IL-7990: `enterTransient` must publish the effective (clamped)
    ///         amount to `outputs[0]`, not the raw request, since downstream fuses chain on it.
    function testShouldPublishClampedAmountToTransientOutputsWhenRequestExceedsVaultBalance() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;
        // Requested amount is 2.5x the vault's balance.
        uint256 requestedAmount = 2_500e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        FuseAction[] memory calls = _buildTransientEnterCalls(requestedAmount, path, 0);

        //when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        bytes32[] memory outputs = _readOutputs(address(_uniswapV2SwapFuse));
        assertEq(outputs.length, 5, "outputs.length"); // tokenInAmount, pathLength, path[0], path[1], minOutAmount
        assertEq(outputs[0], TypeConversionLib.toBytes32(depositAmount), "outputs[0] == effective amount");
        assertTrue(outputs[0] != TypeConversionLib.toBytes32(requestedAmount), "outputs[0] != requested amount");
        assertEq(outputs[1], TypeConversionLib.toBytes32(uint256(2)), "outputs[1] == pathLength");
        assertEq(outputs[2], TypeConversionLib.toBytes32(path[0]), "outputs[2] == path[0]");
        assertEq(outputs[3], TypeConversionLib.toBytes32(path[1]), "outputs[3] == path[1]");
        assertEq(outputs[4], TypeConversionLib.toBytes32(uint256(0)), "outputs[4] == minOutAmount");
    }

    /// @notice Regression for IL-7990: when the vault holds none of the input token, `enter` must
    ///         perform no transfer, emit no event, and report `0` (not the raw request).
    function testShouldReportZeroAndNotSwapWhenVaultHasNoInputToken() external {
        // given — no deposit, vault holds 0 USDC
        uint256 requestedAmount = 1_000e6;

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        FuseAction[] memory calls = _buildTransientEnterCalls(requestedAmount, path, 0);

        vm.recordLogs();

        //when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 enterTopic = keccak256("UniswapV2SwapFuseEnter(address,uint256,address[],uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].emitter != _plasmaVault || logs[i].topics[0] != enterTopic,
                "UniswapV2SwapFuseEnter must not be emitted on a no-op"
            );
        }

        bytes32[] memory outputs = _readOutputs(address(_uniswapV2SwapFuse));
        assertEq(outputs[0], TypeConversionLib.toBytes32(uint256(0)), "outputs[0] == 0, not requestedAmount");
        assertTrue(outputs[0] != TypeConversionLib.toBytes32(requestedAmount), "outputs[0] != requested amount");
        assertEq(outputs[1], TypeConversionLib.toBytes32(uint256(2)), "outputs[1] == pathLength (echoed)");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "no USDC balance moved");
        assertEq(ERC20(USDT).balanceOf(_plasmaVault), 0, "no USDT received");
    }

    /// @notice Regression for IL-7990: a `path` shorter than two tokens must report `0`, not the
    ///         raw request, even though nothing (not even the balance check) ran.
    function testShouldReportZeroWhenPathShorterThanTwo() external {
        // given
        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;
        uint256 requestedAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](1);
        path[0] = USDC;

        FuseAction[] memory calls = _buildTransientEnterCalls(requestedAmount, path, 0);

        //when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        bytes32[] memory outputs = _readOutputs(address(_uniswapV2SwapFuse));
        assertEq(outputs[0], TypeConversionLib.toBytes32(uint256(0)), "outputs[0] == 0, not requestedAmount");
        assertTrue(outputs[0] != TypeConversionLib.toBytes32(requestedAmount), "outputs[0] != requested amount");
        assertEq(outputs[1], TypeConversionLib.toBytes32(uint256(1)), "outputs[1] == pathLength (echoed)");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), depositAmount, "no USDC balance moved");
    }

    /// @notice Positive control: a zero request already reported 0 before the fix, so this test
    ///         must pass both before and after.
    function testShouldReportZeroWhenTokenInAmountIsZero() external {
        // given
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = USDT;

        FuseAction[] memory calls = _buildTransientEnterCalls(0, path, 0);

        //when
        PlasmaVault(_plasmaVault).execute(calls);

        // then
        bytes32[] memory outputs = _readOutputs(address(_uniswapV2SwapFuse));
        assertEq(outputs[0], TypeConversionLib.toBytes32(uint256(0)), "outputs[0] == 0");
        assertEq(ERC20(USDC).balanceOf(_plasmaVault), 0, "no USDC balance moved");
    }

    function _buildTransientEnterCalls(
        uint256 tokenInAmount_,
        address[] memory path_,
        uint256 minOutAmount_
    ) private view returns (FuseAction[] memory calls_) {
        uint256 pathLength = path_.length;

        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = address(_uniswapV2SwapFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](2 + pathLength + 1);
        inputsByFuse[0][0] = TypeConversionLib.toBytes32(tokenInAmount_);
        inputsByFuse[0][1] = TypeConversionLib.toBytes32(pathLength);
        for (uint256 i; i < pathLength; ++i) {
            inputsByFuse[0][2 + i] = TypeConversionLib.toBytes32(path_[i]);
        }
        inputsByFuse[0][2 + pathLength] = TypeConversionLib.toBytes32(minOutAmount_);

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fusesToSet,
            inputsByFuse: inputsByFuse
        });

        calls_ = new FuseAction[](2);
        calls_[0] = FuseAction(
            _transientStorageSetInputsFuse,
            abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        );
        calls_[1] = FuseAction(address(_uniswapV2SwapFuse), abi.encodeWithSignature("enterTransient()"));
    }

    function _readOutputs(address fuse_) private returns (bytes32[] memory outputs_) {
        TransientOutputsReader reader = new TransientOutputsReader();
        ReadResult memory readResult = UniversalReader(_plasmaVault).read(
            address(reader),
            abi.encodeWithSignature("readOutputs(address)", fuse_)
        );
        outputs_ = abi.decode(readResult.data, (bytes32[]));
    }

    function testShouldNotBeAbleSwapWhenDAIWasRemovedFromSubstrates() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](3);
        path[0] = USDC;
        path[1] = DAI;
        path[2] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        bytes32[] memory uniswapTokens = new bytes32[](2);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);

        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.UNISWAP_SWAP_V2, uniswapTokens);

        bytes memory error = abi.encodeWithSignature("UniswapV2SwapFuseUnsupportedToken(address)", DAI);

        //when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldRevertWhenUnsupportedToken() external {
        // given

        address userOne = address(0x1222);
        uint256 depositAmount = 1_000e6;

        vm.prank(0xDa9CE944a37d218c3302F6B82a094844C6ECEb17);
        ERC20(USDC).transfer(userOne, 10_000e6);

        vm.prank(userOne);
        ERC20(USDC).approve(_plasmaVault, depositAmount);
        vm.prank(userOne);
        PlasmaVault(_plasmaVault).deposit(depositAmount, userOne);

        address[] memory path = new address[](3);
        path[0] = USDC;
        path[1] = address(0x76543);
        path[2] = USDT;

        UniswapV2SwapFuseEnterData memory enterData = UniswapV2SwapFuseEnterData({
            tokenInAmount: depositAmount,
            path: path,
            minOutAmount: 0
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_uniswapV2SwapFuse),
            abi.encodeWithSignature("enter((uint256,address[],uint256))", enterData)
        );

        bytes memory error = abi.encodeWithSignature("UniswapV2SwapFuseUnsupportedToken(address)", address(0x76543));

        //when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        _accessManager = accessManager_;
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            _plasmaVault,
            IporFusionAccessManager(_accessManager),
            _withdrawManager
        );
    }

    function _getFuses() private returns (address[] memory fuses_) {
        UniswapV2SwapFuse uniswapV2SwapFuse = new UniswapV2SwapFuse(
            IporFusionMarkets.UNISWAP_SWAP_V2,
            UNIVERSAL_ROUTER
        );

        fuses_ = new address[](1);
        fuses_[0] = address(uniswapV2SwapFuse);
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory uniswapTokens = new bytes32[](3);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        uniswapTokens[2] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNISWAP_SWAP_V2, uniswapTokens);
    }
    //
    function _setupFuses() private returns (address[] memory fuses_) {
        _uniswapV2SwapFuse = new UniswapV2SwapFuse(IporFusionMarkets.UNISWAP_SWAP_V2, UNIVERSAL_ROUTER);
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        fuses_ = new address[](2);
        fuses_[0] = address(_uniswapV2SwapFuse);
        fuses_[1] = _transientStorageSetInputsFuse;
    }
    //
    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        // @Dev this setup is ignored for tests
        ZeroBalanceFuse uniswapBalance = new ZeroBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V2);
        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNISWAP_SWAP_V2, address(uniswapBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));
    }
}
