// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {
    DolomiteSupplyFuse,
    DolomiteSupplyFuseEnterData,
    DolomiteSupplyFuseExitData
} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";

/// @notice Second instant-withdraw entry of the test vault: pays whatever is asked from a funded source, up to its
///         balance. It runs by delegatecall in the vault context, so the tokens land in the vault.
contract DolomiteLiquidityTestSourceFuse {
    uint256 public constant MARKET_ID = 47;

    /// @dev params: [0] amount (set by the router), [1] asset, [2] source
    function instantWithdraw(bytes32[] calldata params_) external {
        address asset = address(uint160(uint256(params_[1])));
        address source = address(uint160(uint256(params_[2])));
        uint256 available = ERC20(asset).balanceOf(source);
        uint256 amount = uint256(params_[0]) < available ? uint256(params_[0]) : available;
        if (amount > 0) {
            ERC20(asset).transferFrom(source, address(this), amount);
        }
    }
}

/// @title DolomiteSupplyFuseInstantWithdrawLiquidityForkTest
/// @notice IL-9564 on an Arbitrum fork with the real DolomiteMargin. DolomiteMargin pays a withdrawal only up to the
///         tokens it holds for the market (supplied minus borrowed); the test lowers its USDC balance with `deal` to
///         model a partly liquid market. Every case runs through the real PlasmaVault `withdraw` and the
///         `withdrawFromMarkets` loop: entry 0 is the Dolomite fuse, entry 1 a second source that pays the remainder.
contract DolomiteSupplyFuseInstantWithdrawLiquidityForkTest is Test {
    /// @dev Own fork block of this suite
    uint256 private constant _FORK_BLOCK = 420_000_001;

    address private constant _DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address private constant _DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;
    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address private constant _BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    uint256 private constant _DOLOMITE_MARKET_ID = 47;
    uint8 private constant _ACCOUNT_FILLED = 0;
    uint8 private constant _ACCOUNT_EMPTY = 1;

    uint256 private constant _POSITION = 300_000e6;
    uint256 private constant _LIQUIDITY = 200_000e6;
    uint256 private constant _REQUEST = 250_000e6;
    uint256 private constant _SOURCE_FUNDS = 1_000_000e6;
    /// @dev The vault asks the markets for the assets plus its 10 wei share-decimals offset
    uint256 private constant _VAULT_OFFSET = 10;

    address private _admin = address(1001);
    address private _alpha = address(1002);
    address private _user = address(1003);
    address private _source = address(1004);

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    DolomiteSupplyFuse private _supplyFuse;
    DolomiteBalanceFuse private _balanceFuse;
    DolomiteLiquidityTestSourceFuse private _sourceFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), _FORK_BLOCK);

        _supplyFuse = new DolomiteSupplyFuse(_DOLOMITE_MARKET_ID, _DOLOMITE_MARGIN, _DEPOSIT_WITHDRAWAL_ROUTER);
        _balanceFuse = new DolomiteBalanceFuse(_DOLOMITE_MARKET_ID, _DOLOMITE_MARGIN);
        _sourceFuse = new DolomiteLiquidityTestSourceFuse();

        _setupPriceOracle();
        _deployPlasmaVault();

        // the user deposits, the vault supplies the whole deposit to Dolomite account number 0
        deal(_USDC, _user, _POSITION);
        vm.startPrank(_user);
        ERC20(_USDC).approve(_plasmaVault, _POSITION);
        PlasmaVault(_plasmaVault).deposit(_POSITION, _user);
        vm.stopPrank();
        _supply(_POSITION, _ACCOUNT_FILLED);

        // the second source holds enough to pay any remainder and approves the vault
        deal(_USDC, _source, _SOURCE_FUNDS);
        vm.prank(_source);
        ERC20(_USDC).approve(_plasmaVault, type(uint256).max);
    }

    /// @notice Liquidity 200k below the 250k request: the Dolomite entry pays its whole liquidity instead of failing
    ///         and the second entry pays the remaining 50k
    function testPartlyLiquidMarketPaysLiquidityAndNextEntryPaysRest() public {
        _configureInstantWithdraw(_ACCOUNT_FILLED, 0);
        _setDolomiteLiquidity(_LIQUIDITY);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_REQUEST, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _REQUEST, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), _LIQUIDITY, "Dolomite pays its whole liquidity");
        assertEq(_count(logs, "DolomiteSupplyFuseExitFailed(address,address,uint256,uint256)"), 0, "no ExitFailed");
        assertEq(
            ERC20(_USDC).balanceOf(_source),
            _SOURCE_FUNDS - (_REQUEST - _LIQUIDITY) - _VAULT_OFFSET,
            "source paid the rest"
        );
        assertEq(ERC20(_USDC).balanceOf(_DOLOMITE_MARGIN), 0, "Dolomite liquidity fully used");
    }

    /// @notice A withdrawal that needs exactly the DolomiteMargin balance (assets plus the vault offset) is paid in full
    ///         by the Dolomite entry
    function testWithdrawExactlyTheDolomiteMarginBalancePasses() public {
        _configureInstantWithdraw(_ACCOUNT_FILLED, 0);
        _setDolomiteLiquidity(_LIQUIDITY);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_LIQUIDITY - _VAULT_OFFSET, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _LIQUIDITY - _VAULT_OFFSET, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), _LIQUIDITY, "Dolomite pays exactly its balance");
        assertEq(_count(logs, "DolomiteSupplyFuseExitFailed(address,address,uint256,uint256)"), 0, "no ExitFailed");
        assertEq(ERC20(_USDC).balanceOf(_source), _SOURCE_FUNDS, "second source untouched");
    }

    /// @notice Word 4 above the amount left after the liquidity cap: the entry is skipped quietly (no Dolomite call,
    ///         no event, no revert) and the second entry pays the whole request
    function testWordFourAboveCappedAmountSkipsEntry() public {
        _configureInstantWithdraw(_ACCOUNT_FILLED, _REQUEST);
        _setDolomiteLiquidity(_LIQUIDITY);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_REQUEST, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _REQUEST, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), 0, "Dolomite entry skipped");
        assertEq(_count(logs, "DolomiteSupplyFuseExitFailed(address,address,uint256,uint256)"), 0, "no ExitFailed");
        assertEq(_count(logs, "InstantWithdrawalFuseFailed(address,uint256,bytes4)"), 0, "no failed entry event");
        assertEq(ERC20(_USDC).balanceOf(_DOLOMITE_MARGIN), _LIQUIDITY, "Dolomite not called");
        assertEq(ERC20(_USDC).balanceOf(_source), _SOURCE_FUNDS - _REQUEST - _VAULT_OFFSET, "source paid everything");
    }

    /// @notice Empty position with word 4 above 0: the entry returns 0 without a revert and the next entry pays
    function testEmptyPositionWithWordFourDoesNotRevert() public {
        _configureInstantWithdraw(_ACCOUNT_EMPTY, 1);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_REQUEST, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _REQUEST, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), 0, "empty position pays nothing");
        assertEq(_count(logs, "InstantWithdrawalFuseFailed(address,uint256,bytes4)"), 0, "no failed entry event");
    }

    /// @notice Liquidity 0: the entry returns before calling Dolomite and emits nothing
    function testZeroLiquidityDoesNotCallDolomite() public {
        _configureInstantWithdraw(_ACCOUNT_FILLED, 0);
        _setDolomiteLiquidity(0);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_REQUEST, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _REQUEST, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), 0, "no Dolomite payout");
        assertEq(_count(logs, "DolomiteSupplyFuseExitFailed(address,address,uint256,uint256)"), 0, "no ExitFailed");
        assertEq(_count(logs, "InstantWithdrawalFuseFailed(address,uint256,bytes4)"), 0, "no failed entry event");
    }

    /// @notice The ALPHA exit is not capped at the liquidity: the full request reaches the router and the revert is
    ///         the vendor's `Token: transfer failed` (observed with -vvvv: the USDC transfer out of DolomiteMargin exceeds its balance)
    function testAlphaExitAboveLiquidityStillReverts() public {
        _setDolomiteLiquidity(_LIQUIDITY);

        // the router is asked for the whole request, not for the 200k liquidity
        vm.expectCall(_DEPOSIT_WITHDRAWAL_ROUTER, _withdrawWeiCalldata(_REQUEST));
        vm.prank(_alpha);
        vm.expectRevert(bytes("Token: transfer failed"));
        PlasmaVault(_plasmaVault).execute(_exitActions(_REQUEST, 0, _ACCOUNT_FILLED));
    }

    /// @notice ALPHA exit of an empty account number with minAmountOut reverts with the full payload
    function testAlphaExitEmptyAccountWithMinAmountOutReverts() public {
        FuseAction[] memory exits = _exitActions(_REQUEST, 1, _ACCOUNT_EMPTY);
        vm.prank(_alpha);
        vm.expectRevert(
            abi.encodeWithSelector(DolomiteSupplyFuse.DolomiteSupplyFuseWithdrawAmountTooSmall.selector, 0, 1)
        );
        PlasmaVault(_plasmaVault).execute(exits);
    }

    /// @notice ALPHA exit with amount 0 and minAmountOut reverts with the full payload
    function testAlphaExitZeroAmountWithMinAmountOutReverts() public {
        FuseAction[] memory exits = _exitActions(0, 1, _ACCOUNT_FILLED);
        vm.prank(_alpha);
        vm.expectRevert(
            abi.encodeWithSelector(DolomiteSupplyFuse.DolomiteSupplyFuseWithdrawAmountTooSmall.selector, 0, 1)
        );
        PlasmaVault(_plasmaVault).execute(exits);
    }

    /// @notice ALPHA exit of a liquid position whose minAmountOut is above the amount: the venue pays the amount and
    ///         the post-check reverts with (received, min); on the instant path the same case would be skipped
    function testAlphaExitLiquidPositionMinAmountOutAboveAmountReverts() public {
        FuseAction[] memory exits = _exitActions(_REQUEST, _REQUEST + 1, _ACCOUNT_FILLED);
        vm.prank(_alpha);
        vm.expectRevert(
            abi.encodeWithSelector(
                DolomiteSupplyFuse.DolomiteSupplyFuseWithdrawAmountTooSmall.selector,
                _REQUEST,
                _REQUEST + 1
            )
        );
        PlasmaVault(_plasmaVault).execute(exits);
    }

    /// @notice Word 4 equal to the capped liquidity: the entry pays exactly the liquidity
    function testWordFourEqualToCappedLiquidityPaysLiquidity() public {
        _configureInstantWithdraw(_ACCOUNT_FILLED, _LIQUIDITY);
        _setDolomiteLiquidity(_LIQUIDITY);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_REQUEST, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _REQUEST, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), _LIQUIDITY, "Dolomite pays exactly the liquidity");
        assertEq(_count(logs, "DolomiteSupplyFuseExitFailed(address,address,uint256,uint256)"), 0, "no ExitFailed");
        assertEq(ERC20(_USDC).balanceOf(_DOLOMITE_MARGIN), 0, "Dolomite liquidity fully used");
        assertEq(
            ERC20(_USDC).balanceOf(_source),
            _SOURCE_FUNDS - (_REQUEST - _LIQUIDITY) - _VAULT_OFFSET,
            "source paid the rest"
        );
    }

    /// @notice Word 4 one above the capped liquidity: the entry is skipped without a Dolomite call
    function testWordFourOneAboveCappedLiquiditySkipsEntry() public {
        _configureInstantWithdraw(_ACCOUNT_FILLED, _LIQUIDITY + 1);
        _setDolomiteLiquidity(_LIQUIDITY);

        vm.recordLogs();
        vm.prank(_user);
        PlasmaVault(_plasmaVault).withdraw(_REQUEST, _user, _user);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_user), _REQUEST, "user received the payout");
        assertEq(_dolomiteExitAmount(logs), 0, "Dolomite entry skipped");
        assertEq(_count(logs, "DolomiteSupplyFuseExitFailed(address,address,uint256,uint256)"), 0, "no ExitFailed");
        assertEq(_count(logs, "InstantWithdrawalFuseFailed(address,uint256,bytes4)"), 0, "no failed entry event");
        assertEq(ERC20(_USDC).balanceOf(_DOLOMITE_MARGIN), _LIQUIDITY, "Dolomite not called");
        assertEq(ERC20(_USDC).balanceOf(_source), _SOURCE_FUNDS - _REQUEST - _VAULT_OFFSET, "source paid everything");
    }

    // ============ Helpers ============

    /// @dev Calldata of the router call the fuse makes: withdrawWei(0, account 0, Dolomite market id, amount, None)
    function _withdrawWeiCalldata(uint256 amount_) private view returns (bytes memory) {
        (bool ok, bytes memory ret) = _DOLOMITE_MARGIN.staticcall(
            abi.encodeWithSignature("getMarketIdByTokenAddress(address)", _USDC)
        );
        require(ok, "market id lookup failed");
        return
            abi.encodeWithSignature(
                "withdrawWei(uint256,uint256,uint256,uint256,uint8)",
                0,
                uint256(_ACCOUNT_FILLED),
                abi.decode(ret, (uint256)),
                amount_,
                uint8(0)
            );
    }

    function _exitActions(
        uint256 amount_,
        uint256 minAmountOut_,
        uint8 account_
    ) private view returns (FuseAction[] memory exits) {
        exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeCall(
                _supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: _USDC,
                        amount: amount_,
                        minAmountOut: minAmountOut_,
                        subAccountId: account_,
                        isolationModeMarketId: 0
                    })
                )
            )
        });
    }

    /// @dev Sets the USDC balance DolomiteMargin holds, which is what a withdrawal can pay out
    function _setDolomiteLiquidity(uint256 amount_) private {
        deal(_USDC, _DOLOMITE_MARGIN, amount_);
    }

    /// @dev Instant withdraw list: entry 0 = Dolomite fuse for the account, entry 1 = the second source
    function _configureInstantWithdraw(uint8 account_, uint256 minAmountOut_) private {
        bytes32[] memory dolomiteParams = new bytes32[](5);
        dolomiteParams[1] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        dolomiteParams[2] = bytes32(uint256(account_));
        dolomiteParams[3] = bytes32(0);
        dolomiteParams[4] = bytes32(minAmountOut_);

        bytes32[] memory sourceParams = new bytes32[](3);
        sourceParams[1] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        sourceParams[2] = PlasmaVaultConfigLib.addressToBytes32(_source);

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](2);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: address(_supplyFuse), params: dolomiteParams});
        iw[1] = InstantWithdrawalFusesParamsStruct({fuse: address(_sourceFuse), params: sourceParams});
        vm.prank(_admin);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);
    }

    function _supply(uint256 amount_, uint8 account_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeCall(
                _supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: _USDC,
                        amount: amount_,
                        minBalanceIncrease: 0,
                        subAccountId: account_,
                        isolationModeMarketId: 0
                    })
                )
            )
        });
        vm.prank(_alpha);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _count(Vm.Log[] memory logs_, string memory signature_) private view returns (uint256 count) {
        bytes32 topic = keccak256(bytes(signature_));
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) ++count;
        }
    }

    /// @dev Sum of the amounts of DolomiteSupplyFuseExit events (data: version, asset, marketId, amount, subAccountId)
    function _dolomiteExitAmount(Vm.Log[] memory logs_) private view returns (uint256 total) {
        bytes32 topic = keccak256("DolomiteSupplyFuseExit(address,address,uint256,uint256,uint8)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, , , uint256 amount, ) = abi.decode(logs_[i].data, (address, address, uint256, uint256, uint8));
                total += amount;
            }
        }
    }

    function _setupPriceOracle() private {
        vm.startPrank(_admin);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_BASE_CURRENCY_PRICE_SOURCE);
        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", _admin))
        );
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _USDC;
        sources[0] = _CHAINLINK_USDC_USD;
        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function _deployPlasmaVault() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = _admin;
        usersToRoles.atomist = _admin;
        address[] memory alphas = new address[](1);
        alphas[0] = _alpha;
        usersToRoles.alphas = alphas;
        _accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));

        vm.startPrank(_admin);
        address withdrawManager = address(new WithdrawManager(_accessManager));
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Dolomite Instant Liquidity Test Vault",
                assetSymbol: "DILVault",
                underlyingToken: _USDC,
                priceOracleMiddleware: _priceOracle,
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            _plasmaVault,
            IporFusionAccessManager(_accessManager),
            withdrawManager
        );

        vm.startPrank(_admin);
        address[] memory fuses = new address[](2);
        fuses[0] = address(_supplyFuse);
        fuses[1] = address(_sourceFuse);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(_DOLOMITE_MARKET_ID, address(_balanceFuse));

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: _USDC, subAccountId: _ACCOUNT_FILLED, canBorrow: false})
        );
        substrates[1] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: _USDC, subAccountId: _ACCOUNT_EMPTY, canBorrow: false})
        );
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(_DOLOMITE_MARKET_ID, substrates);
        vm.stopPrank();
    }
}
