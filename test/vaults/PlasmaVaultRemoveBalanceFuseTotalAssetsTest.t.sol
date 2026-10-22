// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, MarketBalanceFuseConfig, MarketSubstratesConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {SettableBalanceFuseMock} from "./mocks/SettableBalanceFuseMock.sol";

/// @title IL-7976 regression - removeBalanceFuse leaves market valuation cached in totalAssets()
/// @notice Uses a locally-deployed SettableBalanceFuseMock (not a pinned mainnet fuse) so balanceOf()
/// executes the code under test via delegatecall, exactly like a real balance fuse would.
contract PlasmaVaultRemoveBalanceFuseTotalAssetsTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    uint256 public constant MARKET_ID = 777_976;

    address public atomist = address(this);
    address public alpha;
    address public userOne;

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;

    PlasmaVault public plasmaVault;
    SettableBalanceFuseMock public balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);

        alpha = address(0x1);
        userOne = address(0x777);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        balanceFuse = new SettableBalanceFuseMock(MARKET_ID);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(balanceFuse));

        IporFusionAccessManager accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, withdrawManager);

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        deal(DAI, userOne, 1_000e18);
        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 1_000e18);
        vm.prank(userOne);
        plasmaVault.deposit(1_000e18, userOne);
    }

    function _createAccessManager() private returns (IporFusionAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
        }
        usersToRoles.alphas = new address[](1);
        usersToRoles.alphas[0] = alpha;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }

    function _setLiveBalanceOnVault(uint256 wadBalanceInUsd_) private {
        vm.store(address(plasmaVault), balanceFuse.BALANCE_SLOT(), bytes32(wadBalanceInUsd_));
    }

    function _updateMarket() private returns (uint256) {
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        vm.prank(atomist);
        return plasmaVault.updateMarketsBalances(markets);
    }

    /// @dev Fails without the fix: totalAssets() stays inflated by the stale cached market valuation
    /// after removeBalanceFuse, because nothing zeroes MarketTotalAssets/TotalAssets on removal.
    function testTotalAssetsDropsByStaleCacheWhenBalanceFuseRemoved() external {
        // given: idle DAI in the vault establishes a baseline totalAssets()
        uint256 totalAssetsBeforeCaching = plasmaVault.totalAssets();
        assertApproxEqAbs(totalAssetsBeforeCaching, 1_000e18, 1e15, "baseline should equal the deposit");

        // the mock fuse reports a large live balance (500 WAD USD ~= 500 DAI at ~$1) and it gets cached
        _setLiveBalanceOnVault(500e18);
        _updateMarket();

        uint256 marketCacheBefore = plasmaVault.totalAssetsInMarket(MARKET_ID);
        assertGt(marketCacheBefore, 0, "market cache should be populated after updateMarketsBalances");

        uint256 totalAssetsWithCache = plasmaVault.totalAssets();
        assertApproxEqAbs(
            totalAssetsWithCache,
            totalAssetsBeforeCaching + marketCacheBefore,
            1e15,
            "totalAssets should include the cached market valuation"
        );

        // the live position disappears (e.g. loss/slashing/withdrawal in the external protocol) but
        // updateMarketsBalances is never called again, so the cache goes stale-high
        _setLiveBalanceOnVault(0);

        // when: governance removes the balance fuse - the dust guard passes because the *live* balance is 0
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).removeBalanceFuse(MARKET_ID, address(balanceFuse));

        // then
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_ID), 0, "market cache must be cleared on removal");

        uint256 totalAssetsAfterRemoval = plasmaVault.totalAssets();
        assertApproxEqAbs(
            totalAssetsAfterRemoval,
            totalAssetsBeforeCaching,
            1e15,
            "totalAssets must drop back to the pre-caching baseline, not stay inflated"
        );
    }

    /// @dev Regression for the recovery path: remove then re-add the same fuse and update again -
    /// the accumulator must reflect only the new live balance, with no leftover double counting from
    /// the pre-removal cache.
    function testCanReAddBalanceFuseAndUpdateAfterRemoval() external {
        // given: cache a stale position, drop the live balance to 0, then remove
        _setLiveBalanceOnVault(500e18);
        _updateMarket();
        _setLiveBalanceOnVault(0);

        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).removeBalanceFuse(MARKET_ID, address(balanceFuse));

        uint256 totalAssetsAfterRemoval = plasmaVault.totalAssets();

        // when: re-add the fuse and report a fresh live balance
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(MARKET_ID, address(balanceFuse));

        _setLiveBalanceOnVault(200e18);
        _updateMarket();

        // then: totalAssets increases by roughly the new position only, no residual from the old cache
        uint256 marketCacheAfterReAdd = plasmaVault.totalAssetsInMarket(MARKET_ID);
        assertGt(marketCacheAfterReAdd, 0, "market cache should reflect the new live balance");

        uint256 totalAssetsAfterReAdd = plasmaVault.totalAssets();
        assertApproxEqAbs(
            totalAssetsAfterReAdd,
            totalAssetsAfterRemoval + marketCacheAfterReAdd,
            1e15,
            "totalAssets after re-add must equal post-removal baseline plus the fresh cache only"
        );
    }
}
