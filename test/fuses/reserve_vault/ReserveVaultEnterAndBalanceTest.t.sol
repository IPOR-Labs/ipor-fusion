// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {
    ReserveVaultSupplyFuse,
    ReserveVaultSupplyFuseEnterData,
    ReserveVaultSupplyFuseExitData
} from "../../../contracts/fuses/reserve_vault/ReserveVaultSupplyFuse.sol";

import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MutableValuePriceFeed} from "../../managers/MutableValuePriceFeed.sol";
import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev A granted substrate that is not a working vault: any call to it reverts, so a balance read that touches it fails
contract RevertingMemberVault {
    function asset() external pure returns (address) {
        revert("asset() must not be called");
    }
}

/// @dev A member vault whose asset is not the reserve vault's underlying
contract OtherAssetMemberVault is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Other member", "oMEM") {}
}

contract ReserveVaultEnterAndBalanceTest is ReserveVaultTestBase {
    event ReserveVaultSupplyFuseEnter(
        address version,
        address vault,
        address asset,
        uint256 amount,
        uint256 shares,
        uint256 principal
    );

    event ReserveVaultSupplyFuseExit(
        address version,
        address vault,
        address asset,
        uint256 amount,
        uint256 sharesBurned,
        uint256 boost,
        uint256 surplusAssets,
        uint256 principal
    );

    bytes32 private constant ENTER_TOPIC =
        keccak256("ReserveVaultSupplyFuseEnter(address,address,address,uint256,uint256,uint256)");
    bytes32 private constant EXIT_TOPIC =
        keccak256("ReserveVaultSupplyFuseExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    /// @dev Off-grid USDC price in the feed's 18 decimals
    int256 private constant OFF_GRID_PRICE = 999_873_211_457_913_207;

    function setUp() public override {
        super.setUp();
        _userDeposit(USERS_DEPOSIT);
        _userDepositB(USERS_DEPOSIT);
        _fundC(300_000_000);
    }

    function _refreshC() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = RESERVE_MARKET;
        vm.prank(ATOMIST);
        vaultC.updateMarketsBalances(ids);
    }

    function _countEvents(Vm.Log[] memory logs_, bytes32 topic_) internal view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(vaultC) && logs_[i].topics[0] == topic_) {
                ++count;
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Principal ledger
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldAddUpPrincipalOfTwoEntersIntoTheSameVault() public {
        uint256 shares1 = vaultA.previewDeposit(100_000_000);
        vm.expectEmit(false, false, false, true, address(vaultC));
        emit ReserveVaultSupplyFuseEnter(
            address(supplyFuse),
            address(vaultA),
            address(usdc),
            100_000_000,
            shares1,
            100_000_000
        );
        _reserveEnter(vaultA, 100_000_000);
        assertEq(_principal(vaultA), 100_000_000, "principal after first enter");

        uint256 shares2 = vaultA.previewDeposit(40_000_001);
        vm.expectEmit(false, false, false, true, address(vaultC));
        emit ReserveVaultSupplyFuseEnter(
            address(supplyFuse),
            address(vaultA),
            address(usdc),
            40_000_001,
            shares2,
            140_000_001
        );
        _reserveEnter(vaultA, 40_000_001);

        assertEq(_principal(vaultA), 140_000_001, "principal is the sum of both enters");
        assertEq(usdc.balanceOf(address(vaultC)), 300_000_000 - 140_000_001, "C idle decreased by the principal");
        assertEq(vaultA.balanceOf(address(vaultC)), shares1 + shares2, "C holds the shares of both deposits");
    }

    function testShouldKeepSeparateLedgersForMemberVaults() public {
        _reserveEnter(vaultA, 100_000_000);
        _reserveEnter(vaultB, 33_333_333);

        assertEq(_principal(vaultA), 100_000_000, "principal A");
        assertEq(_principal(vaultB), 33_333_333, "principal B");

        _reserveExit(vaultA, 60_000_000);

        assertEq(_principal(vaultA), 40_000_000, "principal A after partial exit");
        assertEq(_principal(vaultB), 33_333_333, "principal B untouched by exit from A");

        _reserveExit(vaultA, 40_000_000);
        assertEq(_principal(vaultA), 0, "principal A cleared");
        assertEq(_principal(vaultB), 33_333_333, "principal B still untouched");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reserve vault balance and 1:1 price
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldKeepReserveVaultAtOneToOneThroughEnterLossGainAndExit() public {
        uint256 totalAssetsBefore = vaultC.totalAssets();
        uint256 sharePriceBefore = _sharePrice(vaultC);
        uint256 supplyBefore = vaultC.totalSupply();
        assertEq(totalAssetsBefore, 300_000_000, "C starts with the funded assets");

        _reserveEnter(vaultA, 100_000_000);
        _reserveEnter(vaultB, 33_333_333);
        _refreshC();
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 133_333_333, "market 61 is the sum of principals");
        assertEq(vaultC.totalAssets(), totalAssetsBefore, "C totalAssets after enter");
        assertEq(_sharePrice(vaultC), sharePriceBefore, "C share price after enter");

        _loss(vaultA, LOSS);
        _refreshC();
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 133_333_333, "market 61 ignores A loss");
        assertEq(vaultC.totalAssets(), totalAssetsBefore, "C totalAssets after loss");
        assertEq(_sharePrice(vaultC), sharePriceBefore, "C share price after loss");

        _gain(vaultB, GAIN);
        _refreshC();
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 133_333_333, "market 61 ignores B gain");
        assertEq(vaultC.totalAssets(), totalAssetsBefore, "C totalAssets after gain");
        assertEq(_sharePrice(vaultC), sharePriceBefore, "C share price after gain");

        _reserveExit(vaultA, 100_000_000);
        _refreshC();
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 33_333_333, "market 61 after exit from A");
        assertEq(vaultC.totalAssets(), totalAssetsBefore, "C totalAssets after exit");
        assertEq(_sharePrice(vaultC), sharePriceBefore, "C share price after exit");
        assertEq(vaultC.totalSupply(), supplyBefore, "C supply never changed");
    }

    function testShouldRoundMarketBalanceUpWithOffGridReserveOraclePrice() public {
        feedC.setPrice(OFF_GRID_PRICE);
        _refreshC();
        uint256 totalAssetsBefore = vaultC.totalAssets();
        assertEq(totalAssetsBefore, 300_000_000, "C totalAssets before enter");

        _reserveEnter(vaultA, 100_000_001);
        _refreshC();
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 100_000_001, "market 61 is not floored to 100_000_000");
        assertEq(vaultC.totalAssets(), totalAssetsBefore, "C totalAssets unchanged after the first enter");

        _reserveEnter(vaultB, 33_333_333);
        _refreshC();
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 133_333_334, "principals are summed before conversion");
        assertEq(vaultC.totalAssets(), totalAssetsBefore, "C totalAssets unchanged after the second enter");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reverts and no-ops
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldRevertEnterAndExitForUngrantedVault() public {
        address ungranted = address(vaultC);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseUnsupportedVault.selector,
                "enter",
                ungranted
            )
        );
        vm.prank(ALPHA);
        vaultC.execute(_single(address(supplyFuse), _enterData(ungranted, 1_000_000)));

        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseUnsupportedVault.selector,
                "exit",
                ungranted
            )
        );
        vm.prank(ALPHA);
        vaultC.execute(_single(address(supplyFuse), _exitData(ungranted, 1_000_000)));
    }

    function testShouldRevertExitAboveRecordedPrincipal() public {
        _reserveEnter(vaultA, 100_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseAmountExceedsPrincipal.selector,
                address(vaultA),
                100_000_001,
                100_000_000
            )
        );
        vm.prank(ALPHA);
        vaultC.execute(_single(address(supplyFuse), _exitData(address(vaultA), 100_000_001)));
        assertEq(_principal(vaultA), 100_000_000, "principal unchanged");
    }

    function testShouldRevertExitFromMemberVaultWithoutPrincipal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultSupplyFuse.ReserveVaultSupplyFuseAmountExceedsPrincipal.selector,
                address(vaultB),
                1,
                0
            )
        );
        vm.prank(ALPHA);
        vaultC.execute(_single(address(supplyFuse), _exitData(address(vaultB), 1)));
    }

    function testShouldDoNothingForZeroAmountEnterAndExit() public {
        _reserveEnter(vaultA, 100_000_000);
        uint256 idleBefore = usdc.balanceOf(address(vaultC));
        uint256 sharesBefore = vaultA.balanceOf(address(vaultC));

        vm.recordLogs();
        _reserveEnter(vaultA, 0);
        _reserveExit(vaultA, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_countEvents(logs, ENTER_TOPIC), 0, "no enter event");
        assertEq(_countEvents(logs, EXIT_TOPIC), 0, "no exit event");
        assertEq(_principal(vaultA), 100_000_000, "principal unchanged");
        assertEq(usdc.balanceOf(address(vaultC)), idleBefore, "idle unchanged");
        assertEq(vaultA.balanceOf(address(vaultC)), sharesBefore, "shares unchanged");
    }

    function testShouldDoNothingForZeroAmountOnUngrantedVault() public {
        vm.recordLogs();
        _execute(vaultC, address(supplyFuse), _enterData(address(vaultC), 0));
        _execute(vaultC, address(supplyFuse), _exitData(address(vaultC), 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, ENTER_TOPIC) + _countEvents(logs, EXIT_TOPIC), 0, "no event");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // A -> C leg
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldValueMemberDepositIntoReserveVaultAndLeavePrincipalLedgerAlone() public {
        _reserveEnter(vaultA, 100_000_000);
        uint256 principalBefore = _principal(vaultA);
        uint256 cTotalBefore = vaultC.totalAssets();
        uint256 cSharePriceBefore = _sharePrice(vaultC);

        _memberDepositToC(vaultA, 50_000_000);

        assertEq(_principal(vaultA), principalBefore, "principal ledger unaffected by A -> C deposit");
        assertEq(_principal(vaultB), 0, "B ledger unaffected");

        uint256 cSharesOfA = vaultC.balanceOf(address(vaultA));
        assertGt(cSharesOfA, 0, "A holds C shares");
        assertEq(
            vaultA.totalAssetsInMarket(ERC4626_MARKET),
            vaultC.convertToAssets(cSharesOfA),
            "A values its C shares at C's exchange rate"
        );
        assertEq(vaultA.totalAssetsInMarket(ERC4626_MARKET), 50_000_000, "50 USDC at a 1:1 rate");

        _refreshC();
        assertEq(vaultC.totalAssets(), cTotalBefore + 50_000_000, "C received the deposit");
        assertEq(_sharePrice(vaultC), cSharePriceBefore, "C share price unchanged");
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 100_000_000, "market 61 is still the principal");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Zero-principal skip and a different asset
    // ---------------------------------------------------------------------------------------------------------------

    function testShouldSkipGrantedMemberVaultWithZeroPrincipalBeforeAnyExternalCall() public {
        RevertingMemberVault broken = new RevertingMemberVault();
        address[] memory members = new address[](3);
        members[0] = address(vaultA);
        members[1] = address(vaultB);
        members[2] = address(broken);
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vaultC)).grantMarketSubstrates(RESERVE_MARKET, _toSubstrates(members));

        // the broken substrate has zero principal: the balance read must not touch it
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 0, "empty market");
        _refreshC();

        _reserveEnter(vaultA, 100_000_000);
        _refreshC();
        assertEq(
            vaultC.totalAssetsInMarket(RESERVE_MARKET),
            100_000_000,
            "balance read succeeds around the broken one"
        );
        assertEq(vaultC.totalAssets(), 300_000_000, "C totalAssets unchanged");

        // sanity: the broken vault really reverts when asked
        vm.expectRevert();
        broken.asset();
    }

    function testShouldConvertPrincipalOfMemberVaultWithDifferentAsset() public {
        MockERC20 other = new MockERC20("Other", "OTH", 8);
        OtherAssetMemberVault member = new OtherAssetMemberVault(other);
        MutableValuePriceFeed otherFeed = new MutableValuePriceFeed(2e18);

        // price of the other asset: 2 USD; the oracle of C is shared by the base's price feed set-up
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            PlasmaVaultGovernance(address(vaultC)).getPriceOracleMiddleware()
        );
        address[] memory assets = new address[](1);
        assets[0] = address(other);
        address[] memory sources = new address[](1);
        sources[0] = address(otherFeed);
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        address[] memory members = new address[](3);
        members[0] = address(vaultA);
        members[1] = address(vaultB);
        members[2] = address(member);
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vaultC)).grantMarketSubstrates(RESERVE_MARKET, _toSubstrates(members));

        other.mint(address(vaultC), 50e8);
        _reserveEnter(vaultA, 100_000_000);
        _execute(vaultC, address(supplyFuse), _enterData(address(member), 50e8));
        _refreshC();

        assertEq(_principal(PlasmaVault(payable(address(member)))), 50e8, "principal in the other asset");
        // 100 USDC at 1 USD + 50 OTH at 2 USD = 200 USD = 200 USDC
        assertEq(vaultC.totalAssetsInMarket(RESERVE_MARKET), 200_000_000, "other asset converted through the oracle");
        assertEq(vaultC.totalAssets(), 200_000_000 + (300_000_000 - 100_000_000), "other asset funded from outside");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _enterData(address vault_, uint256 amount_) internal pure returns (bytes memory) {
        return abi.encodeCall(ReserveVaultSupplyFuse.enter, (ReserveVaultSupplyFuseEnterData(vault_, amount_)));
    }

    function _exitData(address vault_, uint256 amount_) internal pure returns (bytes memory) {
        return abi.encodeCall(ReserveVaultSupplyFuse.exit, (ReserveVaultSupplyFuseExitData(vault_, amount_)));
    }

    function _single(address fuse_, bytes memory data_) internal pure returns (FuseAction[] memory actions) {
        actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
    }
}
