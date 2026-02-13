// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {SDaiPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/SDaiPriceFeedEthereum.sol";

import {SparkBalanceFuse} from "../../../contracts/fuses/chains/ethereum/spark/SparkBalanceFuse.sol";
import {SparkSupplyFuse, SparkSupplyFuseEnterData, SparkSupplyFuseExitData} from "../../../contracts/fuses/chains/ethereum/spark/SparkSupplyFuse.sol";
import {ISavingsDai} from "../../../contracts/fuses/chains/ethereum/spark/ext/ISavingsDai.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title SparkSupplyFuseTest
/// @notice Tests for SparkSupplyFuse
/// @author IPOR Labs
contract SparkSupplyFuseTest is Test {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    address private _transientStorageSetInputsFuse;

    /// @notice Setup the test environment
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );

        SDaiPriceFeedEthereum priceFeed = new SDaiPriceFeedEthereum();
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = SDAI;
        sources[0] = address(priceFeed);

        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());
    }

    /// @notice Test supplying DAI to Spark
    function testShouldBeAbleToSupplyDaiToSpark() external {
        // given
        // sDAI/DAI
        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1);
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIBefore = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf();

        // when
        vaultMock.enterSparkSupply(SparkSupplyFuseEnterData({amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf();

        assertEq(balanceBefore, 1_000e18, "vault balance should be 1_000e18");
        assertEq(balanceAfter, 900e18, "vault balance should be 900e18");
        assertEq(balanceSDAIBefore, 0, "sDAI balance should be 0");
        assertEq(balanceSDAIAfter, 93731561573799055444, "sDAI balance should be 93731561573799055444");
        assertEq(balanceFromBalanceFuseBefore, 0, "balance should be 0");
        assertEq(balanceFromBalanceFuseAfter, 100042570414709200292, "balance should be 100042570414709200292");
    }

    /// @notice Test withdrawing sDAI from Spark
    function testShouldBeAbleToWithdrawSDaiFormSpark() external {
        // given
        // sDAI/DAI
        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1);
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        vaultMock.enterSparkSupply(SparkSupplyFuseEnterData({amount: amount}));

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIBefore = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf();

        // when
        vaultMock.exitSparkSupply(
            SparkSupplyFuseExitData({amount: ISavingsDai(SDAI).convertToAssets(balanceSDAIBefore)})
        );

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf();

        assertEq(balanceBefore, 900e18, "vault balance should be 900e18");
        assertEq(balanceAfter, 999999999999999999999, "vault balance should be 999999999999999999999");
        assertEq(balanceSDAIBefore, 93731561573799055444, "sDAI balance should be 93731561573799055444");
        assertEq(balanceSDAIAfter, 0, "sDAI balance should be 0");
        assertEq(balanceFromBalanceFuseBefore, 100042570414709200292, "balance should be 100042570414709200292");
        assertEq(balanceFromBalanceFuseAfter, 0, "balance should be 0");
    }

    /// @notice Test entering via transient storage
    function testShouldEnterTransient() external {
        // given
        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1);
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        uint256 amount = 100e18;
        deal(DAI, address(vaultMock), 1_000e18);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(amount);

        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        bytes memory setInputsData = abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData);

        // when
        vaultMock.execute(address(_transientStorageSetInputsFuse), setInputsData);
        vaultMock.enterSparkSupplyTransient();

        // then
        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        assertEq(balanceSDAIAfter, 93731561573799055444, "sDAI balance should match expected");
    }

    /// @notice Test exiting via transient storage
    function testShouldExitTransient() external {
        // given
        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1);
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        uint256 amount = 100e18;
        deal(DAI, address(vaultMock), 1_000e18);

        vaultMock.enterSparkSupply(SparkSupplyFuseEnterData({amount: amount}));
        uint256 balanceSDAIBefore = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        uint256 exitAmount = ISavingsDai(SDAI).convertToAssets(balanceSDAIBefore);

        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(exitAmount);

        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory inputData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        bytes memory setInputsData = abi.encodeWithSelector(TransientStorageSetInputsFuse.enter.selector, inputData);

        // when
        vaultMock.execute(address(_transientStorageSetInputsFuse), setInputsData);
        vaultMock.exitSparkSupplyTransient();

        // then
        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        assertEq(balanceSDAIAfter, 0, "sDAI balance should be 0");
    }

    /// @notice Test zero amount checks for enter
    function testShouldReturnWhenEnteringWithZeroAmount() external {
        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1);
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(DAI, address(vaultMock), 100e18);
        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));

        vaultMock.enterSparkSupply(SparkSupplyFuseEnterData({amount: 0}));

        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        assertEq(balanceBefore, balanceAfter, "balance should not change");
    }

    /// @notice Test zero amount checks for exit
    function testShouldReturnWhenExitingWithZeroAmount() external {
        SparkBalanceFuse balanceFuse = new SparkBalanceFuse(1);
        SparkSupplyFuse fuse = new SparkSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(DAI, address(vaultMock), 100e18);
        vaultMock.enterSparkSupply(SparkSupplyFuseEnterData({amount: 50e18}));

        uint256 balanceSDAIBefore = ISavingsDai(SDAI).balanceOf(address(vaultMock));

        vaultMock.exitSparkSupply(SparkSupplyFuseExitData({amount: 0}));

        uint256 balanceSDAIAfter = ISavingsDai(SDAI).balanceOf(address(vaultMock));
        assertEq(balanceSDAIBefore, balanceSDAIAfter, "sDAI balance should not change");
    }
}
