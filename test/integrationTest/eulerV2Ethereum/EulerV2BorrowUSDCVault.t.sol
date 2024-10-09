// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler_v2/EulerV2SupplyFuse.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseEnterData, EulerV2BorrowFuseExitData} from "../../../contracts/fuses/euler_v2/EulerV2BorrowFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler_v2/EulerV2BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {IEVC} from "../../../node_modules/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

contract EulerV2BorrowUSDCVault is BorrowTest {
    using SafeERC20 for ERC20;

    event EulerV2BorrowEnterFuse(address version, address vault, uint256 amount);
    event EulerV2BorrowExitFuse(address version, address vault, uint256 repaidAmount);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant EULER_WETH2_VAULT_BORROW = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    address public constant EULER_USDC2_VAULT_COLLATERAL = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address public constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    uint256 internal depositAmount = 50000e6;
    uint256 internal borrowAmount = 1e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20778740);
        setupBorrowAsset();
        init();
    }

    function getMarketId() public view override returns (uint256) {
        return IporFusionMarkets.EULER_V2;
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function setupBorrowAsset() public override {
        borrowAsset = WETH;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa); // USDC Holder
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;
        assets[1] = WETH;
        sources[1] = CHAINLINK_ETH_USD;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(EULER_USDC2_VAULT_COLLATERAL);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(EULER_WETH2_VAULT_BORROW);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), substrates);
    }

    function setupFuses() public override {
        EulerV2SupplyFuse fuseSupplyLoc = new EulerV2SupplyFuse(getMarketId(), address(EVC));
        EulerV2BorrowFuse fuseBorrowLoc = new EulerV2BorrowFuse(getMarketId(), address(EVC));
        fuses = new address[](2);
        fuses[0] = address(fuseSupplyLoc);
        fuses[1] = address(fuseBorrowLoc);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        EulerV2BalanceFuse eulerV2Balances = new EulerV2BalanceFuse(getMarketId(), address(EVC));

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(eulerV2Balances));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        EulerV2SupplyFuseEnterData memory enterSupplyData = EulerV2SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            amount: amount_
        });

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_WETH2_VAULT_BORROW,
            amount: amount_
        });

        data = new bytes[](2);
        data[0] = abi.encode(enterSupplyData);
        data[1] = abi.encode(enterBorrowData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        EulerV2SupplyFuseExitData memory exitSupplyData = EulerV2SupplyFuseExitData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            amount: amount_
        });

        EulerV2BorrowFuseExitData memory exitBorrowData = EulerV2BorrowFuseExitData({
            vault: EULER_WETH2_VAULT_BORROW,
            amount: amount_
        });

        data = new bytes[](2);
        data[0] = abi.encode(exitSupplyData);
        data[1] = abi.encode(exitBorrowData);

        fusesSetup = fuses;
    }

    function testShouldEnterBorrow() public {
        // given
        uint256 initialWETHEulerVaultBalance = ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        _setupInitialState();

        vm.expectEmit(true, true, true, true);
        emit EulerV2BorrowEnterFuse(address(fuses[1]), EULER_WETH2_VAULT_BORROW, borrowAmount);
        // when
        _executeBorrowOrRepay(true, borrowAmount);

        // then
        assertEq(ERC20(WETH).balanceOf(address(plasmaVault)), borrowAmount);
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW), initialWETHEulerVaultBalance - borrowAmount);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
    }

    function testShouldExitBorrow() public {
        // given
        uint256 initialWETHEulerVaultBalance = ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        _setupInitialState();

        _executeBorrowOrRepay(true, borrowAmount);

        vm.expectEmit(true, true, true, true);
        emit EulerV2BorrowExitFuse(address(fuses[1]), EULER_WETH2_VAULT_BORROW, borrowAmount);

        // when
        _executeBorrowOrRepay(false, borrowAmount);

        // then
        assertEq(ERC20(WETH).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW), initialWETHEulerVaultBalance);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
    }

    function testShouldEnterBorrowWithZeroAmount() public {
        // given
        uint256 initialWETHEulerVaultBalance = ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        _setupInitialState();

        // when
        _executeBorrowOrRepay(true, 0);

        // then
        // No state change expected, but the transaction should succeed
        assertEq(ERC20(WETH).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
        assertEq(ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW), initialWETHEulerVaultBalance);
    }

    function testShouldExitBorrowWithZeroAmount() public {
        // given
        uint256 initialWETHEulerVaultBalance = ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        _setupInitialState();

        _executeBorrowOrRepay(true, borrowAmount);

        // when
        _executeBorrowOrRepay(false, 0);

        // then
        // No state change expected, but the transaction should succeed
        assertEq(ERC20(WETH).balanceOf(address(plasmaVault)), borrowAmount);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
        assertEq(ERC20(WETH).balanceOf(EULER_WETH2_VAULT_BORROW), initialWETHEulerVaultBalance - borrowAmount);
    }

    function testShouldFailEnterBorrowWithInsufficientCollateral() public {
        // given
        uint256 insufficientDepositAmount = 90e6;
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(insufficientDepositAmount, accounts[1]);

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            fuses[0],
            abi.encodeWithSignature(
                "enter((address,uint256))",
                EulerV2SupplyFuseEnterData({vault: EULER_USDC2_VAULT_COLLATERAL, amount: insufficientDepositAmount})
            )
        );

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_WETH2_VAULT_BORROW);

        // when / then
        vm.expectRevert();
        _executeBorrowOrRepay(true, borrowAmount);
    }

    function testShouldDisableController() public {
        // given
        _setupInitialState();

        _executeBorrowOrRepay(true, borrowAmount);

        // when
        _executeBorrowOrRepay(false, borrowAmount);

        vm.prank(EULER_WETH2_VAULT_BORROW);
        IEVC(EVC).disableController(address(plasmaVault));

        // then
        assertFalse(IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW));

        // Attempt to borrow again (should fail)
        vm.expectRevert();
        _executeBorrowOrRepay(true, borrowAmount);
    }

    function testShouldRepayPartialLoan() public {
        // given
        _setupInitialState();

        _executeBorrowOrRepay(true, borrowAmount);

        // when
        uint256 partialRepayAmount = borrowAmount / 2;
        _executeBorrowOrRepay(false, partialRepayAmount);

        // then
        uint256 remainingDebt = ERC20(WETH).balanceOf(address(plasmaVault));
        assertEq(
            remainingDebt,
            borrowAmount - partialRepayAmount,
            "Remaining debt should be initial debt minus partial repayment"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW),
            "Controller should still be enabled after partial repayment"
        );
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)),
            borrowAmount - partialRepayAmount,
            "PlasmaVault should still hold the remaining borrowed amount"
        );
    }

    function testShouldFailBorrowingMoreThanAvailableLiquidity() public {
        // given
        uint256 excessiveBorrowAmount = 635e18; // 634 WETH available in the vault, so we borrow more than available

        _setupInitialState();

        // when
        vm.expectRevert();
        _executeBorrowOrRepay(true, excessiveBorrowAmount);

        // then
        assertEq(ERC20(WETH).balanceOf(address(plasmaVault)), 0, "PlasmaVault should not have borrowed any WETH");
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW),
            "Controller should still be enabled after failed borrow attempt"
        );
    }

    function testMultipleBorrowAndRepayOperations() public {
        // given
        _setupInitialState();

        uint256 initialBalance = ERC20(WETH).balanceOf(address(plasmaVault));
        uint256[] memory borrowAmounts = new uint256[](2);
        borrowAmounts[0] = 0.5e18;
        borrowAmounts[1] = 0.3e18;
        uint256[] memory repayAmounts = new uint256[](2);
        repayAmounts[0] = 0.2e18;
        repayAmounts[1] = 0.4e18;

        // First borrow
        _executeBorrowOrRepay(true, borrowAmounts[0]);

        // Verify state after first borrow
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)),
            initialBalance + borrowAmounts[0],
            "Incorrect balance after first borrow"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW),
            "Controller should be enabled after first borrow"
        );

        // First repay
        _executeBorrowOrRepay(false, repayAmounts[0]);

        // Verify state after first repay
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)),
            initialBalance + borrowAmounts[0] - repayAmounts[0],
            "Incorrect balance after first repay"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW),
            "Controller should still be enabled after first repay"
        );

        // Second borrow
        _executeBorrowOrRepay(true, borrowAmounts[1]);

        // Verify state after second borrow
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)),
            initialBalance + borrowAmounts[0] - repayAmounts[0] + borrowAmounts[1],
            "Incorrect balance after second borrow"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW),
            "Controller should be enabled after second borrow"
        );

        // Second repay
        _executeBorrowOrRepay(false, repayAmounts[1]);

        // Verify final state
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)),
            initialBalance + borrowAmounts[0] - repayAmounts[0] + borrowAmounts[1] - repayAmounts[1],
            "Incorrect final balance"
        );
        assertTrue(
            IEVC(EVC).isControllerEnabled(address(plasmaVault), EULER_WETH2_VAULT_BORROW),
            "Controller should still be enabled after all operations"
        );

        // Verify remaining debt
        assertEq(
            ERC20(WETH).balanceOf(address(plasmaVault)),
            borrowAmounts[0] + borrowAmounts[1] - repayAmounts[0] - repayAmounts[1],
            "Incorrect remaining debt"
        );
    }

    function _executeBorrowOrRepay(bool isBorrow, uint256 amount) private {
        if (isBorrow) {
            EulerV2BorrowFuseEnterData memory enterData = EulerV2BorrowFuseEnterData({
                vault: EULER_WETH2_VAULT_BORROW,
                amount: amount
            });

            FuseAction[] memory actions = new FuseAction[](1);
            actions[0] = FuseAction(fuses[1], abi.encodeWithSelector(EulerV2BorrowFuse.enter.selector, enterData));

            vm.prank(alpha);
            PlasmaVault(plasmaVault).execute(actions);
        } else {
            EulerV2BorrowFuseExitData memory exitData = EulerV2BorrowFuseExitData({
                vault: EULER_WETH2_VAULT_BORROW,
                amount: amount
            });

            FuseAction[] memory actions = new FuseAction[](1);
            actions[0] = FuseAction(fuses[1], abi.encodeWithSelector(EulerV2BorrowFuse.exit.selector, exitData));

            vm.prank(alpha);
            PlasmaVault(plasmaVault).execute(actions);
        }
    }

    function _setupInitialState() private {
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(
            fuses[0],
            abi.encodeWithSignature(
                "enter((address,uint256))",
                EulerV2SupplyFuseEnterData({vault: EULER_USDC2_VAULT_COLLATERAL, amount: depositAmount})
            )
        );

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_WETH2_VAULT_BORROW);
    }
}
