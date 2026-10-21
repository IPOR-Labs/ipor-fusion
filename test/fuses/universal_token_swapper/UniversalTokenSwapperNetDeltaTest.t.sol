// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig} from "contracts/vaults/PlasmaVault.sol";
import {FuseAction, PlasmaVault, PlasmaVaultInitData} from "contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultBase} from "contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {ZeroBalanceFuse} from "contracts/fuses/ZeroBalanceFuse.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {
    UniversalTokenSwapperFuse,
    UniversalTokenSwapperEnterData,
    UniversalTokenSwapperData
} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {UniversalTokenSwapperSubstrateLib} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperSubstrateLib.sol";

import {RoleLib, UsersToRoles} from "test/RoleLib.sol";
import {FeeConfigHelper} from "test/test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "test/utils/PlasmaVaultConfigurator.sol";
import {MutableValuePriceFeed} from "test/managers/MutableValuePriceFeed.sol";

/// @dev Simple mintable ERC20 with configurable decimals (stand-in for USDC / USDT).
contract NetDeltaMockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev Permissionless rewards distributor (Morpho URD-style): anyone may trigger a claim on behalf of
///      an account, the claimed tokens always go to that account. Here the vault has pending rewards
///      denominated in the swap's tokenIn.
contract NetDeltaRewardsDistributor {
    ERC20 public immutable REWARD_TOKEN;
    mapping(address => uint256) public pending;

    constructor(address rewardToken_) {
        REWARD_TOKEN = ERC20(rewardToken_);
    }

    function setPending(address account_, uint256 amount_) external {
        pending[account_] = amount_;
    }

    function claim(address account_) external returns (uint256 amount) {
        amount = pending[account_];
        pending[account_] = 0;
        REWARD_TOKEN.transfer(account_, amount);
    }
}

/// @dev Pool paying out tokenOut to msg.sender (the executor) one-to-one for tokenIn it received beforehand.
contract NetDeltaMockPool {
    ERC20 public immutable TOKEN_OUT;

    constructor(address tokenOut_) {
        TOKEN_OUT = ERC20(tokenOut_);
    }

    function payout(uint256 amount_) external {
        TOKEN_OUT.transfer(msg.sender, amount_);
    }
}

/// @title UniversalTokenSwapperNetDeltaTest
/// @notice IL-8767 (bd6682ce): swap deltas are measured on the executor, so inflows to the vault during execution
///         (permissionless claims paid to the vault) can neither mask a tokenIn theft nor fake tokenOut.
contract UniversalTokenSwapperNetDeltaTest is Test {
    event UniversalTokenSwapperFuseEnter(
        address version,
        address tokenIn,
        address tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    NetDeltaMockToken private usdc;
    NetDeltaMockToken private usdt;
    NetDeltaRewardsDistributor private distributorIn; // pays USDC (tokenIn) rewards to the vault
    NetDeltaRewardsDistributor private distributorOut; // pays USDT (tokenOut) rewards to the vault
    NetDeltaMockPool private pool;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _withdrawManager;
    address private _swapExecutor;

    UniversalTokenSwapperFuse private _universalTokenSwapperFuse;

    address private alpha = makeAddr("compromisedAlpha");
    address private userOne = makeAddr("depositor");

    uint256 private constant DEPOSIT = 10_000e6;
    uint256 private constant PENDING_REWARDS = 5_000e6;
    uint256 private constant AMOUNT_IN = 5_000e6;

    function setUp() public {
        usdc = new NetDeltaMockToken("USD Coin", "USDC", 6);
        usdt = new NetDeltaMockToken("Tether", "USDT", 6);
        distributorIn = new NetDeltaRewardsDistributor(address(usdc));
        distributorOut = new NetDeltaRewardsDistributor(address(usdt));
        pool = new NetDeltaMockPool(address(usdt));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );
        MutableValuePriceFeed feed = new MutableValuePriceFeed(1e18);
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdt);
        address[] memory sources = new address[](2);
        sources[0] = address(feed);
        sources[1] = address(feed);
        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assets, sources);

        _withdrawManager = address(new WithdrawManager(address(_accessManager)));

        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvUSDC",
                address(usdc),
                _priceOracle,
                FeeConfigHelper.createZeroFeeConfig(),
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

        usdc.mint(userOne, DEPOSIT);
        vm.startPrank(userOne);
        usdc.approve(_plasmaVault, DEPOSIT);
        PlasmaVault(_plasmaVault).deposit(DEPOSIT, userOne);
        vm.stopPrank();

        // the vault has rewards pending at permissionless distributors, in tokenIn and in tokenOut
        usdc.mint(address(distributorIn), PENDING_REWARDS);
        distributorIn.setPending(_plasmaVault, PENDING_REWARDS);
        usdt.mint(address(distributorOut), PENDING_REWARDS);
        distributorOut.setPending(_plasmaVault, PENDING_REWARDS);

        // liquidity of the honest pool
        usdt.mint(address(pool), 100_000e6);
    }

    function _buildEnter(
        address[] memory targets_,
        bytes[] memory data_,
        uint256 minAmountOut_
    ) internal view returns (FuseAction[] memory enterCalls) {
        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: address(usdc),
            tokenOut: address(usdt),
            amountIn: AMOUNT_IN,
            minAmountOut: minAmountOut_,
            data: UniversalTokenSwapperData({targets: targets_, data: data_, tokensToReturn: new address[](0)})
        });

        enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_universalTokenSwapperFuse),
            abi.encodeWithSignature("enter((address,address,uint256,uint256,(address[],bytes[],address[])))", enterData)
        );
    }

    /// @dev [USDC.transfer(alpha, AMOUNT_IN), distributor.claim(vault)]
    function _theftWithClaim(address distributor_) internal view returns (FuseAction[] memory) {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(usdc);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", alpha, AMOUNT_IN);
        targets[1] = distributor_;
        data[1] = abi.encodeWithSignature("claim(address)", _plasmaVault);
        return _buildEnter(targets, data, AMOUNT_IN);
    }

    /// @dev [USDC.transfer(pool, amount), pool.payout(amount)] - honest 1:1 swap through the executor
    function _honestSwap(uint256 amount_) internal view returns (FuseAction[] memory) {
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);
        targets[0] = address(usdc);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", address(pool), amount_);
        targets[1] = address(pool);
        data[1] = abi.encodeCall(NetDeltaMockPool.payout, (amount_));
        return _buildEnter(targets, data, amount_);
    }

    /// @notice Control: a plain theft without any inflow is blocked (unchanged behaviour).
    function test_control_directTheftIsBlocked() external {
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(usdc);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", alpha, AMOUNT_IN);
        FuseAction[] memory calls = _buildEnter(targets, data, 0);

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSignature("UniversalTokenSwapperFuseSlippageFail()"));
        PlasmaVault(_plasmaVault).execute(calls);
    }

    /// @notice (a) tokenIn inflow to the vault via a permissionless claim no longer masks the theft.
    function test_a_tokenInInflowViaClaimDoesNotMaskTheft() external {
        FuseAction[] memory calls = _theftWithClaim(address(distributorIn));

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSignature("UniversalTokenSwapperFuseSlippageFail()"));
        PlasmaVault(_plasmaVault).execute(calls);

        assertEq(usdc.balanceOf(alpha), 0, "alpha got nothing");
        assertEq(usdc.balanceOf(_plasmaVault), DEPOSIT, "vault tokenIn untouched");
        assertEq(distributorIn.pending(_plasmaVault), PENDING_REWARDS, "claim rolled back");
    }

    /// @notice (a') a partial tokenIn inflow (amountIn - 1) used to leave a 1 wei vault delta; together with a 1 wei
    ///         tokenOut payout the old vault-delta check passed. Executor-side measurement still reverts.
    function test_a_partialTokenInInflowStillReverts() external {
        distributorIn.setPending(_plasmaVault, AMOUNT_IN - 1);

        address[] memory targets = new address[](3);
        bytes[] memory data = new bytes[](3);
        targets[0] = address(usdc);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", alpha, AMOUNT_IN);
        targets[1] = address(distributorIn);
        data[1] = abi.encodeWithSignature("claim(address)", _plasmaVault);
        targets[2] = address(pool);
        data[2] = abi.encodeCall(NetDeltaMockPool.payout, (1));
        FuseAction[] memory calls = _buildEnter(targets, data, 0);

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSignature("UniversalTokenSwapperFuseSlippageFail()"));
        PlasmaVault(_plasmaVault).execute(calls);

        assertEq(usdc.balanceOf(alpha), 0, "alpha got nothing");
        assertEq(usdc.balanceOf(_plasmaVault), DEPOSIT, "vault tokenIn untouched");
    }

    /// @notice (b) mirror: ALPHA takes tokenIn while a claim pays the vault tokenOut - not counted as swap output.
    function test_b_tokenOutInflowViaClaimIsNotCountedAsReceived() external {
        FuseAction[] memory calls = _theftWithClaim(address(distributorOut));

        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSignature("UniversalTokenSwapperFuseSlippageFail()"));
        PlasmaVault(_plasmaVault).execute(calls);

        assertEq(usdc.balanceOf(alpha), 0, "alpha got nothing");
        assertEq(usdt.balanceOf(_plasmaVault), 0, "claim rolled back");
    }

    /// @notice (c) control: an honest swap passes and the emitted deltas are spent / received on the executor.
    function test_c_honestSwapPassesAndEmitsExecutorDeltas() external {
        FuseAction[] memory calls = _honestSwap(AMOUNT_IN);

        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit UniversalTokenSwapperFuseEnter(
            address(_universalTokenSwapperFuse),
            address(usdc),
            address(usdt),
            AMOUNT_IN,
            AMOUNT_IN
        );
        vm.prank(alpha);
        PlasmaVault(_plasmaVault).execute(calls);

        assertEq(usdc.balanceOf(_plasmaVault), DEPOSIT - AMOUNT_IN, "tokenIn spent");
        assertEq(usdt.balanceOf(_plasmaVault), AMOUNT_IN, "tokenOut received");
    }

    /// @notice (c') an honest swap is measured correctly even when unrelated claims pay the vault in the same call.
    function test_c_honestSwapWithUnrelatedInflowsEmitsExecutorDeltas() external {
        address[] memory targets = new address[](4);
        bytes[] memory data = new bytes[](4);
        targets[0] = address(usdc);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", address(pool), AMOUNT_IN);
        targets[1] = address(pool);
        data[1] = abi.encodeCall(NetDeltaMockPool.payout, (AMOUNT_IN));
        targets[2] = address(distributorIn);
        data[2] = abi.encodeWithSignature("claim(address)", _plasmaVault);
        targets[3] = address(distributorOut);
        data[3] = abi.encodeWithSignature("claim(address)", _plasmaVault);
        FuseAction[] memory calls = _buildEnter(targets, data, AMOUNT_IN);

        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit UniversalTokenSwapperFuseEnter(
            address(_universalTokenSwapperFuse),
            address(usdc),
            address(usdt),
            AMOUNT_IN,
            AMOUNT_IN
        );
        vm.prank(alpha);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    /// @notice (d) a pre-existing executor balance (tokenIn / tokenOut) does not loosen the checks.
    function test_d_preExistingExecutorBalanceDoesNotLoosenChecks() external {
        // tokenIn left in the executor: theft of amountIn is still a spent amountIn with no tokenOut
        usdc.mint(_swapExecutor, 3_000e6);
        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        targets[0] = address(usdc);
        data[0] = abi.encodeWithSignature("transfer(address,uint256)", alpha, AMOUNT_IN);
        FuseAction[] memory theft = _buildEnter(targets, data, 0);
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSignature("UniversalTokenSwapperFuseSlippageFail()"));
        PlasmaVault(_plasmaVault).execute(theft);

        // tokenOut left in the executor must not be credited as swap output
        usdt.mint(_swapExecutor, 4_000e6);
        FuseAction[] memory theftWithOut = _buildEnter(targets, data, AMOUNT_IN);
        vm.prank(alpha);
        vm.expectRevert(abi.encodeWithSignature("UniversalTokenSwapperFuseSlippageFail()"));
        PlasmaVault(_plasmaVault).execute(theftWithOut);
    }

    /// @notice (d') with both balances pre-seeded an honest swap reports only its own amounts and passes.
    function test_d_honestSwapWithSeededExecutorReportsOwnAmounts() external {
        usdc.mint(_swapExecutor, 3_000e6);
        usdt.mint(_swapExecutor, 4_000e6);
        FuseAction[] memory calls = _honestSwap(AMOUNT_IN);

        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit UniversalTokenSwapperFuseEnter(
            address(_universalTokenSwapperFuse),
            address(usdc),
            address(usdt),
            AMOUNT_IN,
            AMOUNT_IN
        );
        vm.prank(alpha);
        PlasmaVault(_plasmaVault).execute(calls);
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
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

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](6);
        // token substrates
        substrates[0] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(address(usdc));
        substrates[1] = UniversalTokenSwapperSubstrateLib.encodeTokenSubstrate(address(usdt));
        // target substrates: tokenIn itself (standard, needed for transfer/approve) + a permissionless distributor
        substrates[2] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(address(usdc));
        substrates[3] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(address(distributorIn));
        substrates[4] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(address(distributorOut));
        substrates[5] = UniversalTokenSwapperSubstrateLib.encodeTargetSubstrate(address(pool));
        // no slippage substrate -> default 1%
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, substrates);
    }

    function _setupFuses() private returns (address[] memory fuses_) {
        _universalTokenSwapperFuse = new UniversalTokenSwapperFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        _swapExecutor = _universalTokenSwapperFuse.EXECUTOR();
        fuses_ = new address[](1);
        fuses_[0] = address(_universalTokenSwapperFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
    }
}
