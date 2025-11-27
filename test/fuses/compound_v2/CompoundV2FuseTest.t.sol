// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {CompoundV2BalanceFuse} from "../../../contracts/fuses/compound_v2/CompoundV2BalanceFuse.sol";
import {CompoundV2SupplyFuse, CompoundV2SupplyFuseExitData, CompoundV2SupplyFuseEnterData} from "../../../contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title CompoundV2FuseTest
/// @notice Tests for CompoundV2SupplyFuse
/// @author IPOR Labs
contract CompoundV2FuseTest is Test {
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant CDAI = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    address private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );

        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());
    }

    function testShouldBeAbleToSupplyDai() external {
        // given
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;

        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIBefore = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf();

        // when
        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf();

        assertEq(balanceBefore, 1_000e18, "vault balance should be 1_000e18");
        assertEq(balanceAfter, 900e18, "vault balance should be 900e18");
        assertEq(balanceCDAIBefore, 0, "cDAI balance should be 0");
        assertEq(balanceCDAIAfter, 433859673319, "cDAI balance should be 433859673319");
        assertEq(balanceFromBalanceFuseBefore, 0, "balance should be 0");
        assertEq(balanceFromBalanceFuseAfter, 100042570999782587684, "balance should be 100042570414709200292");
    }

    function testShouldBeAbleToWithdrawDai() external {
        // given
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;

        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: amount}));

        // when
        vaultMock.exitCompoundV2Supply(CompoundV2SupplyFuseExitData({asset: DAI, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf();

        assertEq(balanceAfter, 999999999999782680199, "vault balance should be 999999999999782680199");
        assertEq(balanceCDAIAfter, 1, "sDAI balance should be 1");
        assertEq(balanceFromBalanceFuseAfter, 230587393, "balance should be 230587393");
    }

    function testShouldRevertWhenAssetIsNotSupported() external {
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        address[] memory assets = new address[](0);
        vaultMock.grantAssetsToMarket(1, assets);

        vm.expectRevert(
            abi.encodeWithSelector(CompoundV2SupplyFuse.CompoundV2SupplyFuseUnsupportedAsset.selector, DAI)
        );
        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: 100e18}));
    }

    function testShouldReturnWhenEnteringWithZeroAmount() external {
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        deal(DAI, address(vaultMock), 100e18);
        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));

        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: 0}));

        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        assertEq(balanceBefore, balanceAfter, "balance should not change");
    }

    function testShouldReturnWhenExitingWithZeroAmount() external {
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;
        vaultMock.grantAssetsToMarket(1, assets);

        deal(DAI, address(vaultMock), 100e18);
        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: 50e18}));

        uint256 balanceCDAIBefore = ERC20(CDAI).balanceOf(address(vaultMock));

        vaultMock.exitCompoundV2Supply(CompoundV2SupplyFuseExitData({asset: DAI, amount: 0}));

        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        assertEq(balanceCDAIBefore, balanceCDAIAfter, "cDAI balance should not change");
    }

    function testShouldRevertWhenUnsupportedAssetInExit() external {
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));

        address[] memory assets = new address[](0);
        vaultMock.grantAssetsToMarket(1, assets);

        vm.expectRevert(
            abi.encodeWithSelector(CompoundV2SupplyFuse.CompoundV2SupplyFuseUnsupportedAsset.selector, DAI)
        );
        vaultMock.exitCompoundV2Supply(CompoundV2SupplyFuseExitData({asset: DAI, amount: 100e18}));
    }

    function testShouldInstantWithdraw() external {
        // given
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;
        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;
        deal(DAI, address(vaultMock), 1_000e18);
        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: amount}));

        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        // when
        vaultMock.instantWithdraw(params);

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        assertEq(balanceAfter, 999999999999782680199, "balance should match expected withdrawal");
    }

    function testShouldEnterTransient() external {
        // given
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;
        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;
        deal(DAI, address(vaultMock), 1_000e18);

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(DAI);
        inputs[1] = TypeConversionLib.toBytes32(amount);

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
        vaultMock.enterCompoundV2SupplyTransient();

        // then
        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        assertEq(balanceCDAIAfter, 433859673319, "cDAI balance should be 433859673319");
    }

    function testShouldExitTransient() external {
        // given
        CompoundV2BalanceFuse balanceFuse = new CompoundV2BalanceFuse(1);
        CompoundV2SupplyFuse fuse = new CompoundV2SupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        address[] memory assets = new address[](1);
        assets[0] = CDAI;
        vaultMock.grantAssetsToMarket(1, assets);

        uint256 amount = 100e18;
        deal(DAI, address(vaultMock), 1_000e18);
        vaultMock.enterCompoundV2Supply(CompoundV2SupplyFuseEnterData({asset: DAI, amount: amount}));

        bytes32[] memory inputs = new bytes32[](2);
        inputs[0] = TypeConversionLib.toBytes32(DAI);
        inputs[1] = TypeConversionLib.toBytes32(amount);

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
        vaultMock.exitCompoundV2SupplyTransient();

        // then
        uint256 balanceCDAIAfter = ERC20(CDAI).balanceOf(address(vaultMock));
        assertEq(balanceCDAIAfter, 1, "cDAI balance should be 1");
    }
}
