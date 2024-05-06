// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {TestAccountSetup} from "./TestAccountSetup.sol";
import {TestPriceOracleSetup} from "./TestPriceOracleSetup.sol";
import {TestVaultSetup} from "./TestVaultSetup.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";

abstract contract SupplyTest is TestAccountSetup, TestPriceOracleSetup, TestVaultSetup {
    uint256 private constant ERROR_DELTA = 100;

    function init() public {
        initStorage();
        initAccount();
        initPriceOracle();
        setupFuses();
        initPlasmaVault();
        initApprove();
    }

    function dealAssets(address account, uint256 amount) public virtual override;

    function setupAsset() public virtual override;

    function setupPriceOracle() public virtual override returns (address[] memory assets, address[] memory sources);

    function setupMarketConfigs()
        public
        virtual
        override
        returns (PlasmaVault.MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual override;

    function setupBalanceFuses()
        public
        virtual
        override
        returns (PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses);

    function getEnterFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual override returns (bytes memory data);

    function getExitFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual override returns (bytes memory data);

    function testShouldDepositRandomAmount() external {
        // given
        uint256 sum;

        // when
        for (uint256 i; i < 5; i++) {
            uint256 amount = random.randomNumber(1, 10_000 * 10 ** (ERC20(asset).decimals()));
            sum += amount;
            vm.prank(accounts[i]);
            PlasmaVault(plasmaVault).deposit(amount, accounts[i]);
        }

        // then
        uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();
        uint256 totalShares = PlasmaVault(plasmaVault).totalSupply();

        assertEq(totalAssets, sum, "totalSupply");
        assertEq(totalShares, sum, "totalShares");
    }

    function testShouldDepositRandomAmountWhenMoveBlockNumberAndTimestamp() external {
        // given
        uint256 sum;

        // when
        for (uint256 i; i < 10; i++) {
            vm.roll(block.number + 100);
            vm.warp(block.timestamp + 1200);
            for (uint256 i; i < 5; i++) {
                uint256 amount = random.randomNumber(1, 10_000 * 10 ** (ERC20(asset).decimals()));
                sum += amount;
                vm.prank(accounts[i]);
                PlasmaVault(plasmaVault).deposit(amount, accounts[i]);
            }
        }

        // then
        uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();
        uint256 totalShares = PlasmaVault(plasmaVault).totalSupply();

        assertEq(totalAssets, sum, "totalSupply");
        assertEq(totalShares, sum, "totalShares");
    }

    function testShouldMintRandomAmount() external {
        // given
        uint256 sum;

        // when
        for (uint256 i; i < 5; i++) {
            uint256 amount = random.randomNumber(1, 10_000 * 10 ** (ERC20(asset).decimals()));
            sum += amount;
            vm.prank(accounts[i]);
            PlasmaVault(plasmaVault).mint(amount, accounts[i]);
        }

        // then
        uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();
        uint256 totalShares = PlasmaVault(plasmaVault).totalSupply();

        assertEq(totalAssets, sum, "totalSupply");
        assertEq(totalShares, sum, "totalShares");
    }

    function testShouldMintRandomAmountWhenMoveBlockNumberAndTimestamp() external {
        // given
        uint256 sum;

        // when
        for (uint256 i; i < 10; i++) {
            vm.roll(block.number + 100);
            vm.warp(block.timestamp + 1200);
            for (uint256 i; i < 5; i++) {
                uint256 amount = random.randomNumber(1, 10_000 * 10 ** (ERC20(asset).decimals()));
                sum += amount;
                vm.prank(accounts[i]);
                PlasmaVault(plasmaVault).mint(amount, accounts[i]);
            }
        }

        // then
        uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();
        uint256 totalShares = PlasmaVault(plasmaVault).totalSupply();

        assertEq(totalAssets, sum, "totalSupply");
        assertEq(totalShares, sum, "totalShares");
    }

    function testShouldUseEnterMethodWithAllDepositAssets() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        bytes memory enterData = getEnterFuseData(depositAmount, new bytes32[](0));

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);
        calls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

        // when

        PlasmaVault(plasmaVault).execute(calls);

        // then

        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, ERROR_DELTA, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter, assetsInMarketBefore + depositAmount, ERROR_DELTA, "assetsInMarket");
    }

    function testShouldUseEnterTwiceMethod() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            2 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        uint256 enterAmount = random.randomNumber(1 * 10 ** (ERC20(asset).decimals()), depositAmount / 2);

        bytes memory enterData = getEnterFuseData(enterAmount, new bytes32[](0));

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);
        calls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));
        calls[1] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

        // when

        PlasmaVault(plasmaVault).execute(calls);

        // then

        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, ERROR_DELTA, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter, assetsInMarketBefore + 2 * enterAmount, ERROR_DELTA, "assetsInMarket");
    }

    function testShouldUseExitMethodWithAllInMarket() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            1 * 10 ** (ERC20(asset).decimals()),
            10_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        bytes memory enterData = getEnterFuseData(depositAmount, new bytes32[](0));
        PlasmaVault.FuseAction[] memory enterCalls = new PlasmaVault.FuseAction[](1);
        enterCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));

        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));
        bytes memory exitData = getExitFuseData(assetsInMarketBefore, new bytes32[](0));

        PlasmaVault.FuseAction[] memory exitCalls = new PlasmaVault.FuseAction[](1);
        exitCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("exit(bytes)", exitData));

        // when
        PlasmaVault(plasmaVault).execute(exitCalls);

        // then

        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, ERROR_DELTA, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter + depositAmount, assetsInMarketBefore, ERROR_DELTA, "assetsInMarket");
    }

    function testShouldUseExitMethodTwice() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            10_000 * 10 ** (ERC20(asset).decimals()),
            20_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        bytes memory enterData = getEnterFuseData(depositAmount, new bytes32[](0));
        PlasmaVault.FuseAction[] memory enterCalls = new PlasmaVault.FuseAction[](1);
        enterCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));

        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketBefore = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));
        bytes memory exitData = getExitFuseData(assetsInMarketBefore / 2, new bytes32[](0));

        PlasmaVault.FuseAction[] memory exitCalls = new PlasmaVault.FuseAction[](2);
        exitCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("exit(bytes)", exitData));
        exitCalls[1] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("exit(bytes)", exitData));

        // when
        PlasmaVault(plasmaVault).execute(exitCalls);

        // then

        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, ERROR_DELTA, "totalAssets");
        assertApproxEqAbs(assetsInMarketAfter + depositAmount, assetsInMarketBefore, ERROR_DELTA, "assetsInMarket");
    }

    function testShouldRandomEnterExitFromMarket() external {
        // given
        address userOne = accounts[1];
        uint256 depositAmount = random.randomNumber(
            10_000 * 10 ** (ERC20(asset).decimals()),
            20_000 * 10 ** (ERC20(asset).decimals())
        );
        vm.prank(userOne);
        PlasmaVault(plasmaVault).deposit(depositAmount, userOne);

        bytes memory enterData = getEnterFuseData(depositAmount, new bytes32[](0));
        PlasmaVault.FuseAction[] memory enterCalls = new PlasmaVault.FuseAction[](1);
        enterCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));

        PlasmaVault(plasmaVault).execute(enterCalls);

        uint256 totalSharesBefore = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsBefore = PlasmaVault(plasmaVault).totalAssets();

        // when
        for (uint256 i; i < 50; i++) {
            vm.roll(block.number + 100);
            vm.warp(block.timestamp + 1200);
            if (random.randomNumber(0, 1) == 1) {
                uint256 totalAssetsInMarket = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));
                uint256 totalAssets = PlasmaVault(plasmaVault).totalAssets();
                uint256 maxAmount = totalAssets - totalAssetsInMarket;

                if (maxAmount == 0) {
                    continue;
                }

                uint256 enterAmount = random.randomNumber(1, maxAmount);
                bytes memory enterData = getEnterFuseData(enterAmount, new bytes32[](0));

                PlasmaVault.FuseAction[] memory enterCalls = new PlasmaVault.FuseAction[](1);
                enterCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", enterData));

                PlasmaVault(plasmaVault).execute(enterCalls);
            } else {
                uint256 inMarket = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));

                if (inMarket == 0) {
                    continue;
                }

                uint256 exitAmount = random.randomNumber(1, inMarket);
                bytes memory exitData = getExitFuseData(exitAmount, new bytes32[](0));

                PlasmaVault.FuseAction[] memory exitCalls = new PlasmaVault.FuseAction[](1);
                exitCalls[0] = PlasmaVault.FuseAction(fuses[0], abi.encodeWithSignature("exit(bytes)", exitData));

                PlasmaVault(plasmaVault).execute(exitCalls);
            }
        }

        // then
        uint256 totalSharesAfter = PlasmaVault(plasmaVault).totalSupply();
        uint256 totalAssetsAfter = PlasmaVault(plasmaVault).totalAssets();
        uint256 assetsInMarketAfter = PlasmaVault(plasmaVault).totalAssetsInMarket(uint256(1));
        uint256 assetsOnPlasmaVaultAfter = ERC20(asset).balanceOf(plasmaVault);

        assertEq(totalSharesAfter, totalSharesBefore, "totalShares");
        assertApproxEqAbs(depositAmount, totalAssetsBefore, ERROR_DELTA, "totalAssetsBefore");
        assertApproxEqAbs(
            totalAssetsAfter,
            assetsOnPlasmaVaultAfter + assetsInMarketAfter,
            ERROR_DELTA,
            "totalAssetsAfter"
        );
    }
}
