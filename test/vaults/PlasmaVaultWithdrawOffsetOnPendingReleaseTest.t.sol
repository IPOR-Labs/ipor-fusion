// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData,
    FuseAction
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../../contracts/fuses/IFuseCommon.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {
    MockExternalMarket,
    MockMarketSupplyFuse,
    MockMarketBalanceFuse
} from "./PlasmaVaultRedeemFromRequestReentrancy.t.sol";

/// @notice Instant withdrawal fuse whose market pays 1 wei less than requested, modelling share-rounding
///         integrations (stETH, aToken/cToken rounding). Stateless, delegatecalled by the PlasmaVault.
contract RoundingShortInstantWithdrawFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    /// @param params_ [0] amount to withdraw (set by the vault)
    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);
        uint256 available = MockExternalMarket(MARKET).balanceOf(address(this));

        if (amount > available) {
            amount = available;
        }

        if (amount > 1) {
            MockExternalMarket(MARKET).withdraw(amount - 1);
        }
    }
}

/// @title PlasmaVaultWithdrawOffsetOnPendingReleaseTest
/// @notice Regression suite for IL-8357 - withdraw targets assets_ + WITHDRAW_FROM_MARKETS_OFFSET when nothing is
///         released, but with sharesToRelease > 0 the fixed offset was replaced by a 0.01% markup on the released
///         portion only. A dust release (below one wei of assets) therefore left no slack for the caller's own
///         assets_, and a market that rounds 1 wei short made canWithdrawFromUnallocated revert. The offset is now
///         added in both branches.
contract PlasmaVaultWithdrawOffsetOnPendingReleaseTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    uint256 public constant MARKET_ID = 999_999;
    uint256 public constant USER_DEPOSIT = 1_000e6;
    uint256 public constant WITHDRAW_AMOUNT = 100e6;
    /// @dev mirrors PlasmaVault.WITHDRAW_FROM_MARKETS_OFFSET
    uint256 public constant WITHDRAW_FROM_MARKETS_OFFSET = 10;
    /// @dev below one wei of assets with the 2-decimal share offset, i.e. a residual left after partial claims
    uint256 public constant DUST_SHARES_TO_RELEASE = 99;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    MockExternalMarket public market;
    MockMarketSupplyFuse public supplyFuse;
    RoundingShortInstantWithdrawFuse public instantWithdrawFuse;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        market = new MockExternalMarket(address(asset));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        supplyFuse = new MockMarketSupplyFuse(MARKET_ID, address(market));
        instantWithdrawFuse = new RoundingShortInstantWithdrawFuse(MARKET_ID, address(market));

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(instantWithdrawFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: MARKET_ID,
            fuse: address(new MockMarketBalanceFuse(MARKET_ID, address(market)))
        });

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
        marketConfigs[0] = MarketSubstratesConfig({marketId: MARKET_ID, substrates: substrates});

        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(plasmaVault), fuses, balanceFuses, marketConfigs);

        _configureInstantWithdrawal();

        _fund(user, USER_DEPOSIT);
        _fund(other, USER_DEPOSIT);
        _deposit(user, USER_DEPOSIT);
        _deposit(other, USER_DEPOSIT);

        /// @dev fully allocate the vault so that every withdrawal goes through the rounding-short market
        _supplyToMarket(2 * USER_DEPOSIT);
    }

    /// @dev IL-8357: a dust residual release must not strip the caller's rounding buffer
    function testShouldWithdraw_whenDustSharesToReleaseAndMarketRoundsShort() public {
        _releaseFunds(DUST_SHARES_TO_RELEASE);
        assertEq(plasmaVault.convertToAssets(DUST_SHARES_TO_RELEASE), 0, "release is below one wei of assets");

        /// @dev target = assets_ + offset + 0 released assets, the market pays 1 wei less
        vm.expectCall(
            address(market),
            abi.encodeCall(MockExternalMarket.withdraw, (WITHDRAW_AMOUNT + WITHDRAW_FROM_MARKETS_OFFSET - 1))
        );

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT, user, user);

        assertEq(asset.balanceOf(user), WITHDRAW_AMOUNT, "user received the requested assets");
        assertEq(withdrawManager.getSharesToRelease(), DUST_SHARES_TO_RELEASE, "release untouched");
    }

    /// @dev IL-8357: with a non-dust release the offset is added on top of the padded released assets
    function testShouldAddOffsetOnTopOfReleasedAssets_whenSharesToReleaseSet() public {
        uint256 sharesToRelease = plasmaVault.balanceOf(other) / 2;
        _releaseFunds(sharesToRelease);

        uint256 target = WITHDRAW_AMOUNT +
            WITHDRAW_FROM_MARKETS_OFFSET +
            (plasmaVault.convertToAssets(sharesToRelease) * 10001) / 10000;

        vm.expectCall(address(market), abi.encodeCall(MockExternalMarket.withdraw, (target - 1)));

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT, user, user);

        assertEq(asset.balanceOf(user), WITHDRAW_AMOUNT, "user received the requested assets");
    }

    /// @dev Control case: without a pending release the fixed offset already absorbed the 1 wei shortfall
    function testShouldWithdraw_whenNoSharesToReleaseAndMarketRoundsShort() public {
        vm.expectCall(
            address(market),
            abi.encodeCall(MockExternalMarket.withdraw, (WITHDRAW_AMOUNT + WITHDRAW_FROM_MARKETS_OFFSET - 1))
        );

        vm.prank(user);
        plasmaVault.withdraw(WITHDRAW_AMOUNT, user, user);

        assertEq(asset.balanceOf(user), WITHDRAW_AMOUNT, "user received the requested assets");
    }

    function _releaseFunds(uint256 sharesToRelease_) internal {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alpha);
        withdrawManager.releaseFunds(block.timestamp - 1, sharesToRelease_);
        assertEq(withdrawManager.getSharesToRelease(), sharesToRelease_, "shares released");
    }

    function _supplyToMarket(uint256 amount_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeWithSignature(
                "enter((uint256))",
                MockMarketSupplyFuse.MockMarketSupplyFuseEnterData({amount: amount_})
            )
        });

        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    function _configureInstantWithdrawal() internal {
        bytes4[] memory configureSig = new bytes4[](1);
        configureSig[0] = PlasmaVaultGovernance.configureInstantWithdrawalFuses.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), configureSig, Roles.ATOMIST_ROLE);

        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({
            fuse: address(instantWithdrawFuse),
            params: new bytes32[](1)
        });

        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantWithdrawFuses);
    }

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
    }

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
