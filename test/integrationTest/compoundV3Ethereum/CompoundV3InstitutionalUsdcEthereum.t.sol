// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVault,
    FuseAction
} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {
    CompoundV3SupplyFuse,
    CompoundV3SupplyFuseEnterData,
    CompoundV3SupplyFuseExitData
} from "../../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {CompoundV3WithPriceOracleMiddlewareBalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3WithPriceOracleMiddlewareBalanceFuse.sol";
import {IComet} from "../../../contracts/fuses/compound_v3/ext/IComet.sol";
import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";

/// @title Fork test of the Compound V3 Institutional USDC market (ciUSDCv3) on Ethereum
/// @notice Runs the shared SupplyTest suite against the Comet 0x2071...2F8C with market ID
///         IporFusionMarkets.COMPOUND_V3_INSTITUTIONAL_USDC, using CompoundV3SupplyFuse and
///         CompoundV3WithPriceOracleMiddlewareBalanceFuse, and adds checks of transferred amounts, NAV per step,
///         the ungranted-asset revert and the fuse immutables.
contract CompoundV3InstitutionalUsdcEthereum is SupplyTest {
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant CHAINLINK_USDC = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant COMET = 0x207158a267CBD2598BB3d611D8CBdEE2709F2F8C;
    /// @dev pause guardian of the Institutional Comet (can call pauseLendersWithdraw)
    address private constant PAUSE_GUARDIAN = 0xbbf3f1421D886E9b2c5D716B5192aC998af2012c;
    uint256 private constant FORK_BLOCK = 26_340_464;
    uint256 public constant MARKET_ID = IporFusionMarkets.COMPOUND_V3_INSTITUTIONAL_USDC;

    /// @dev Comet rounds balances through principal/index conversion, so a few wei of drift per operation is expected;
    ///      10 wei is far below any real transfer error while covering that rounding.
    uint256 private constant TOLERANCE = 10;

    CompoundV3WithPriceOracleMiddlewareBalanceFuse private _balanceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        init();
    }

    function getMarketId() public pure override returns (uint256) {
        return MARKET_ID;
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        deal(USDC, account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](1);
        sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[0] = MarketSubstratesConfig(MARKET_ID, substrates);
    }

    function setupFuses() public override {
        CompoundV3SupplyFuse fuse = new CompoundV3SupplyFuse(MARKET_ID, COMET);
        fuses = new address[](1);
        fuses[0] = address(fuse);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        _balanceFuse = new CompoundV3WithPriceOracleMiddlewareBalanceFuse(MARKET_ID, COMET);
        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(_balanceFuse));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        CompoundV3SupplyFuseEnterData memory enterData = CompoundV3SupplyFuseEnterData({asset: asset, amount: amount_});
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("enter((address,uint256))", enterData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        CompoundV3SupplyFuseExitData memory exitData = CompoundV3SupplyFuseExitData({asset: asset, amount: amount_});
        data = new bytes[](1);
        data[0] = abi.encodeWithSignature("exit((address,uint256))", exitData);
        fusesSetup = fuses;
    }

    function testShouldSupplyWithdrawPartAndWithdrawRestWithNavAfterEachStep() external {
        // given
        uint256 depositAmount = 50_000 * 1e6;
        uint256 partAmount = (depositAmount * 40) / 100;
        address userOne = accounts[1];
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        // when - enter all
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateEnterCallsData(depositAmount, new bytes32[](0)));

        // then - funds moved from the vault into Comet
        assertEq(ERC20(USDC).balanceOf(plasmaVault), 0, "idle USDC after enter");
        assertGe(IComet(COMET).balanceOf(plasmaVault), depositAmount - TOLERANCE, "comet balance after enter");
        assertApproxEqAbs(IComet(COMET).balanceOf(plasmaVault), depositAmount, TOLERANCE, "comet balance after enter");
        _assertNav(depositAmount, "after enter");

        // when - exit a part
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateExitCallsData(partAmount, new bytes32[](0)));

        // then
        assertEq(ERC20(USDC).balanceOf(plasmaVault), partAmount, "idle USDC after partial exit");
        assertApproxEqAbs(
            IComet(COMET).balanceOf(plasmaVault),
            depositAmount - partAmount,
            TOLERANCE,
            "comet balance after partial exit"
        );
        _assertNav(depositAmount, "after partial exit");

        // when - exit the rest
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateExitCallsData(type(uint256).max, new bytes32[](0)));

        // then
        assertEq(IComet(COMET).balanceOf(plasmaVault), 0, "comet balance after full exit");
        assertGe(ERC20(USDC).balanceOf(plasmaVault), depositAmount - TOLERANCE, "idle USDC after full exit");
        assertApproxEqAbs(ERC20(USDC).balanceOf(plasmaVault), depositAmount, TOLERANCE, "idle USDC after full exit");
        assertEq(PlasmaVault(plasmaVault).totalAssetsInMarket(MARKET_ID), 0, "market NAV after full exit");
        _assertNav(depositAmount, "after full exit");
    }

    function testShouldRevertWhenEnterWithAssetNotGrantedToMarket() external {
        // given
        uint256 amount = 1e18;
        deal(WETH, plasmaVault, amount);
        CompoundV3SupplyFuseEnterData memory enterData = CompoundV3SupplyFuseEnterData({asset: WETH, amount: amount});
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter((address,uint256))", enterData));

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(CompoundV3SupplyFuse.CompoundV3SupplyFuseUnsupportedAsset.selector, "enter", WETH)
        );
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(calls);
    }

    function testShouldBindFusesToInstitutionalUsdcCometAndMarket57() external view {
        // market id constant
        assertEq(IporFusionMarkets.COMPOUND_V3_INSTITUTIONAL_USDC, 57, "market id constant");

        // supply fuse
        CompoundV3SupplyFuse supplyFuse = CompoundV3SupplyFuse(fuses[0]);
        assertEq(supplyFuse.MARKET_ID(), 57, "supply fuse market id");
        assertEq(address(supplyFuse.COMET()), COMET, "supply fuse comet");
        assertEq(supplyFuse.COMPOUND_BASE_TOKEN(), USDC, "supply fuse base token");
        assertEq(supplyFuse.VERSION(), address(supplyFuse), "supply fuse version");

        // balance fuse
        assertEq(_balanceFuse.MARKET_ID(), 57, "balance fuse market id");
        assertEq(address(_balanceFuse.COMET()), COMET, "balance fuse comet");
        assertEq(_balanceFuse.COMPOUND_BASE_TOKEN(), USDC, "balance fuse base token");
        assertEq(_balanceFuse.COMPOUND_BASE_TOKEN_DECIMALS(), 6, "balance fuse base token decimals");
        assertEq(_balanceFuse.VERSION(), address(_balanceFuse), "balance fuse version");
    }

    function testShouldNotExitWhenLendersWithdrawPaused() external {
        // given - supplied into Comet
        uint256 depositAmount = 50_000 * 1e6;
        address userOne = accounts[1];
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(generateEnterCallsData(depositAmount, new bytes32[](0)));
        uint256 navBefore = PlasmaVault(plasmaVault).totalAssets();

        // when - the guardian pauses lenders' withdrawals only
        vm.prank(PAUSE_GUARDIAN);
        (bool paused, ) = COMET.call(abi.encodeWithSignature("pauseLendersWithdraw(bool)", true));
        assertTrue(paused, "guardian pauseLendersWithdraw");

        // then - only the extended flag is set, the legacy flag stays false
        assertTrue(_staticBool("isLendersWithdrawPaused()"), "lenders withdraw paused");
        assertFalse(_staticBool("isWithdrawPaused()"), "legacy withdraw flag stays false");

        // and - the alpha exit reverts with the Comet error bubbled up by the vault
        FuseAction[] memory exitCalls = generateExitCallsData(depositAmount / 2, new bytes32[](0));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("LendersWithdrawPaused()"))));
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(exitCalls);

        // and - position and NAV are unchanged
        assertApproxEqAbs(IComet(COMET).balanceOf(plasmaVault), depositAmount, TOLERANCE, "comet balance unchanged");
        assertEq(PlasmaVault(plasmaVault).totalAssets(), navBefore, "NAV unchanged");
    }

    function _staticBool(string memory signature_) private view returns (bool) {
        (bool ok, bytes memory ret) = COMET.staticcall(abi.encodeWithSignature(signature_));
        assertTrue(ok, "static call");
        return abi.decode(ret, (bool));
    }

    /// @dev NAV must equal the independent sum of idle USDC and the Comet balance, and match the deposited amount
    function _assertNav(uint256 expectedTotal_, string memory step_) private view {
        uint256 cometBalance = IComet(COMET).balanceOf(plasmaVault);
        uint256 idle = ERC20(USDC).balanceOf(plasmaVault);
        assertApproxEqAbs(
            PlasmaVault(plasmaVault).totalAssetsInMarket(MARKET_ID),
            cometBalance,
            TOLERANCE,
            string.concat("market NAV ", step_)
        );
        assertApproxEqAbs(
            PlasmaVault(plasmaVault).totalAssets(),
            idle + cometBalance,
            TOLERANCE,
            string.concat("total assets vs idle + comet ", step_)
        );
        assertApproxEqAbs(
            PlasmaVault(plasmaVault).totalAssets(),
            expectedTotal_,
            TOLERANCE,
            string.concat("total assets ", step_)
        );
    }
}
