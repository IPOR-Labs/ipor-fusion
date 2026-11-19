// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockERC4626} from "../test_helpers/MockErc4626.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @dev Fixed USD price feed (1 USD, 8 decimals) for the underlying asset
contract FailureIsolationTestPriceFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Instant withdrawal fuse that first moves tokens out of the vault (delegatecall context) and then reverts.
///      params[1] = token, params[2] = mode (0 revert with error data, 1 empty revert)
contract FaultyInstantWithdrawFuse {
    error FaultyEntry(uint256 amount);

    address public constant SINK = address(0xdead);
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function instantWithdraw(bytes32[] calldata params_) external {
        IERC20(address(uint160(uint256(params_[1])))).transfer(SINK, 1e18);
        if (uint256(params_[2]) == 0) {
            revert FaultyEntry(uint256(params_[0]));
        }
        assembly {
            revert(0, 0)
        }
    }
}

/// @notice IL-9659 (L28, Pete D-051 / Q17): an instant withdrawal entry that reverts with error data is skipped with
/// `InstantWithdrawalFuseFailed` and the next entries serve the withdrawal; an empty revert and an all-failing list
/// still revert. Real PlasmaVault clone, `withdraw` and `redeem` beyond the idle balance.
contract PlasmaVaultInstantWithdrawFailureIsolationTest is Test {
    event InstantWithdrawalFuseFailed(address fuse, uint256 index, bytes4 errorSelector);

    uint256 private constant MARKET_A = 5001;
    uint256 private constant MARKET_B = 5002;
    uint256 private constant MARKET_FAULTY = 5003;
    uint256 private constant MODE_REVERT_WITH_DATA = 0;
    uint256 private constant MODE_EMPTY_REVERT = 1;
    uint256 private constant INITIAL_REDEMPTION_DELAY = 1 days;
    uint256 private constant DEPOSIT_AMOUNT = 1000e18;
    uint256 private constant IN_VENUE = 300e18;
    uint256 private constant BASE_TIMESTAMP = 1_700_000_000;
    FusionFactory private fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses private factoryAddresses;
    MockERC20 private underlyingToken;

    address private plasmaVaultBase;
    address private priceOracleMiddleware;
    address private burnRequestFeeFuse;
    address private burnRequestFeeBalanceFuse;

    address private owner;
    address private atomist;
    address private alpha;
    address private depositor;
    address private daoFeeRecipient;
    address private daoFeeManager;
    address private maintenanceManager;

    IporFusionAccessManager private accessManager;
    PlasmaVault private plasmaVault;
    PriceOracleMiddlewareManager private priceManager;

    MockERC4626 private venueA;
    MockERC4626 private venueB;
    Erc4626SupplyFuse private fuseA;
    Erc4626SupplyFuse private fuseB;
    FaultyInstantWithdrawFuse private faultyFuse;

    function setUp() public {
        vm.warp(BASE_TIMESTAMP);

        owner = makeAddr("owner");
        atomist = makeAddr("atomist");
        depositor = makeAddr("depositor");
        alpha = makeAddr("alpha");
        daoFeeRecipient = makeAddr("daoFeeRecipient");
        daoFeeManager = makeAddr("daoFeeManager");
        maintenanceManager = makeAddr("maintenanceManager");

        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        FusionFactory fusionFactoryImplementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        vm.startPrank(daoFeeManager);
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(1);

        address accessManagerBase = address(new IporFusionAccessManager(owner, 1 seconds));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address contextManagerBase = address(new ContextManager(owner, approvedAddresses));
        address priceManagerBase = address(new PriceOracleMiddlewareManager(owner, priceOracleMiddleware));

        address plasmaVaultCoreBase = address(new PlasmaVault());

        address rewardsManagerBase = address(new RewardsClaimManager(owner, plasmaVaultCoreBase));

        vm.startPrank(maintenanceManager);
        fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Vault",
            "TVAULT",
            address(underlyingToken),
            INITIAL_REDEMPTION_DELAY,
            owner,
            0
        );

        accessManager = IporFusionAccessManager(instance.accessManager);
        plasmaVault = PlasmaVault(payable(instance.plasmaVault));
        priceManager = PriceOracleMiddlewareManager(instance.priceManager);

        _configureVault();
    }

    function testShouldSkipFaultyEntryAndServeWithdrawFromNextEntry() public {
        // given: entry 0 reverts with error data after moving tokens out of the vault, entry 1 is healthy
        uint256 idle = underlyingToken.balanceOf(address(plasmaVault));
        uint256 assets = idle + 100e18;
        uint256 venueBBefore = underlyingToken.balanceOf(address(venueB));

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit InstantWithdrawalFuseFailed(address(faultyFuse), 0, FaultyInstantWithdrawFuse.FaultyEntry.selector);
        vm.expectCall(address(venueB), abi.encodePacked(venueB.withdraw.selector), 1);

        // when
        vm.prank(depositor);
        plasmaVault.withdraw(assets, depositor, depositor);

        // then
        assertEq(underlyingToken.balanceOf(depositor), assets, "user paid in full");
        assertEq(underlyingToken.balanceOf(faultyFuse.SINK()), 0, "effects of the failed entry are rolled back");
        assertLt(underlyingToken.balanceOf(address(venueB)), venueBBefore, "venue B served the shortfall");
    }

    function testShouldSkipFaultyEntryAndServeRedeemFromNextEntry() public {
        // given
        uint256 idle = underlyingToken.balanceOf(address(plasmaVault));
        uint256 shares = plasmaVault.convertToShares(idle + 100e18);

        // then
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit InstantWithdrawalFuseFailed(address(faultyFuse), 0, FaultyInstantWithdrawFuse.FaultyEntry.selector);

        // when
        vm.prank(depositor);
        uint256 assets = plasmaVault.redeem(shares, depositor, depositor);

        // then
        assertGt(assets, idle, "redeem paid beyond the idle balance");
        assertEq(underlyingToken.balanceOf(faultyFuse.SINK()), 0, "effects of the failed entry are rolled back");
    }

    function testShouldRevertWholeWithdrawWhenEntryRevertsWithEmptyData() public {
        // given
        _configureList(MODE_EMPTY_REVERT, true);
        uint256 assets = underlyingToken.balanceOf(address(plasmaVault)) + 100e18;

        // then: an empty revert may be out of gas, so it is never skipped
        vm.expectRevert(abi.encodeWithSelector(Address.FailedInnerCall.selector));

        // when
        vm.prank(depositor);
        plasmaVault.withdraw(assets, depositor, depositor);
    }

    function testShouldRevertWhenEveryEntryFails() public {
        // given: the only entry fails, so nothing can serve the amount beyond idle
        _configureList(MODE_REVERT_WITH_DATA, false);
        uint256 idle = underlyingToken.balanceOf(address(plasmaVault));
        uint256 assets = idle + 100e18;
        uint256 depositorBefore = underlyingToken.balanceOf(depositor);

        // then: the faulty entry is skipped (IL-9659), nothing serves the shortfall, so the vault cannot pay `assets`
        vm.expectEmit(true, true, true, true, address(plasmaVault));
        emit InstantWithdrawalFuseFailed(address(faultyFuse), 0, FaultyInstantWithdrawFuse.FaultyEntry.selector);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(plasmaVault), idle, assets)
        );

        // when
        vm.prank(depositor);
        plasmaVault.withdraw(assets, depositor, depositor);

        // then
        assertEq(underlyingToken.balanceOf(depositor), depositorBefore, "nothing was paid");
    }

    function _configureVault() private {
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, owner, 0);
        accessManager.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, owner, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, owner, 0);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, owner, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, depositor, 0);

        address[] memory assets = new address[](1);
        assets[0] = address(underlyingToken);
        address[] memory sources = new address[](1);
        sources[0] = address(new FailureIsolationTestPriceFeed());
        priceManager.setAssetsPriceSources(assets, sources);
        vm.stopPrank();

        venueA = new MockERC4626(underlyingToken, "Venue A", "VA");
        venueB = new MockERC4626(underlyingToken, "Venue B", "VB");
        fuseA = new Erc4626SupplyFuse(MARKET_A);
        fuseB = new Erc4626SupplyFuse(MARKET_B);
        faultyFuse = new FaultyInstantWithdrawFuse(MARKET_FAULTY);
        Erc4626BalanceFuse balanceFuseA = new Erc4626BalanceFuse(MARKET_A);
        Erc4626BalanceFuse balanceFuseB = new Erc4626BalanceFuse(MARKET_B);

        vm.startPrank(owner);
        PlasmaVaultGovernance governance = PlasmaVaultGovernance(address(plasmaVault));
        address[] memory fuses = new address[](3);
        fuses[0] = address(fuseA);
        fuses[1] = address(fuseB);
        fuses[2] = address(faultyFuse);
        governance.addFuses(fuses);
        governance.addBalanceFuse(MARKET_A, address(balanceFuseA));
        governance.addBalanceFuse(MARKET_B, address(balanceFuseB));
        governance.grantMarketSubstrates(MARKET_A, _substrate(address(venueA)));
        governance.grantMarketSubstrates(MARKET_B, _substrate(address(venueB)));

        vm.stopPrank();
        _configureList(MODE_REVERT_WITH_DATA, true);

        underlyingToken.mint(depositor, DEPOSIT_AMOUNT);
        vm.startPrank(depositor);
        underlyingToken.approve(address(plasmaVault), DEPOSIT_AMOUNT);
        plasmaVault.deposit(DEPOSIT_AMOUNT, depositor);
        vm.stopPrank();

        FuseAction[] memory enter = new FuseAction[](2);
        enter[0] = FuseAction({
            fuse: address(fuseA),
            data: abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(venueA), IN_VENUE, 0)))
        });
        enter[1] = FuseAction({
            fuse: address(fuseB),
            data: abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(venueB), IN_VENUE, 0)))
        });
        vm.prank(alpha);
        plasmaVault.execute(enter);

        vm.warp(block.timestamp + INITIAL_REDEMPTION_DELAY + 1);
    }

    function _substrate(address venue_) private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(venue_);
    }

    /// @dev Instant withdrawal list: [faulty entry (index 0), healthy venue B entry (index 1) if `withHealthy_`]
    function _configureList(uint256 mode_, bool withHealthy_) private {
        InstantWithdrawalFusesParamsStruct[] memory list = new InstantWithdrawalFusesParamsStruct[](
            withHealthy_ ? 2 : 1
        );
        bytes32[] memory faultyParams = new bytes32[](3);
        faultyParams[1] = PlasmaVaultConfigLib.addressToBytes32(address(underlyingToken));
        faultyParams[2] = bytes32(mode_);
        list[0] = InstantWithdrawalFusesParamsStruct({fuse: address(faultyFuse), params: faultyParams});
        if (withHealthy_) {
            list[1] = InstantWithdrawalFusesParamsStruct({
                fuse: address(fuseB),
                params: _instantParams(address(venueB))
            });
        }
        vm.prank(owner);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(list);
    }

    function _instantParams(address venue_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(venue_);
    }
}
