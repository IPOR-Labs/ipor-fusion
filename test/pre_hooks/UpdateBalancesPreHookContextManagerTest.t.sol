// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev IL-8310 / IL-8322: ContextManager-relayed calls on selectors wired to UpdateBalancesPreHook or
///      UpdateBalancesIgnoreDustPreHook (directly or nested under ExchangeRateValidatorPreHook). The hooks self-call
///      PlasmaVault.updateMarketsBalances; PlasmaVault must authorize that self-call against the vault, not against
///      the context sender, without granting the context sender any role it does not hold.
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {PlasmaVault, PlasmaVaultInitData} from "contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultCloneLib} from "test/test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultBase} from "contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress,
    InitializationData
} from "contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeAccount} from "contracts/managers/fee/FeeAccount.sol";
import {ZeroBalanceFuse} from "contracts/fuses/ZeroBalanceFuse.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {ContextManager, ExecuteData, ContextDataWithSender} from "contracts/managers/context/ContextManager.sol";
import {UpdateBalancesPreHook} from "contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {UpdateBalancesIgnoreDustPreHook} from "contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesIgnoreDustPreHook.sol";
import {ExchangeRateValidatorPreHook} from "contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorPreHook.sol";
import {
    ExchangeRateValidatorConfigLib,
    ExchangeRateValidatorConfig,
    Hook,
    HookType
} from "contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
import {FeeConfigHelper} from "test/test_helpers/FeeConfigHelper.sol";
import {IPreHook} from "contracts/handlers/pre_hooks/IPreHook.sol";
import {IPlasmaVaultGovernance} from "contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "contracts/libraries/Roles.sol";

contract UpdateBalancesContextMockToken is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

contract UpdateBalancesContextMockOracle is IPriceOracleMiddleware {
    function QUOTE_CURRENCY() external pure returns (address) {
        return address(0x0000000000000000000000000000000000000348);
    }

    function QUOTE_CURRENCY_DECIMALS() external pure returns (uint256) {
        return 8;
    }

    function getAssetPrice(address) external pure returns (uint256, uint256) {
        return (1e8, 8);
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external pure returns (uint256[] memory prices, uint256[] memory decimalsList) {
        prices = new uint256[](assets_.length);
        decimalsList = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            prices[i] = 1e8;
            decimalsList[i] = 8;
        }
    }

    function getSourceOfAssetPrice(address) external pure returns (address) {
        return address(0);
    }

    function setAssetsPricesSources(address[] calldata, address[] calldata) external {}
}

/// @dev Self-calls a restricted function hosted in PlasmaVaultBase (reached through the PlasmaVault fallback)
contract SelfCallBaseGovernancePreHook is IPreHook {
    uint256 public constant NEW_TOTAL_SUPPLY_CAP = 123_456e18;

    function run(bytes4) external {
        IPlasmaVaultGovernance(address(this)).setTotalSupplyCap(NEW_TOTAL_SUPPLY_CAP);
    }
}

contract UpdateBalancesPreHookContextManagerTest is Test {
    uint256 internal constant MARKET_ID = 9001;
    uint256 internal constant ERV_MARKET_ID = 9002;

    address internal constant _ATOMIST = address(1111111);
    address internal constant _ALPHA = address(2222222);
    address internal constant _USER = address(3333333);

    uint256 internal constant _USER2_PK = 0xA11CE;
    address internal _user2;

    UpdateBalancesContextMockToken internal _token;
    UpdateBalancesContextMockOracle internal _oracle;
    address internal _accessManager;
    address internal _plasmaVault;
    address internal _withdrawManager;
    ContextManager internal _contextManager;

    UpdateBalancesPreHook internal _updateBalancesPreHook;
    UpdateBalancesIgnoreDustPreHook internal _ignoreDustPreHook;
    ExchangeRateValidatorPreHook internal _exchangeRateValidatorPreHook;

    function setUp() public {
        _user2 = vm.addr(_USER2_PK);
        _token = new UpdateBalancesContextMockToken();
        _oracle = new UpdateBalancesContextMockOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));

        _withdrawManager = address(new WithdrawManager(_accessManager));
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: address(_token),
                priceOracleMiddleware: address(_oracle),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: _withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = _plasmaVault;
        _contextManager = new ContextManager(_accessManager, approvedTargets);

        _initAccessManager();

        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(MARKET_ID, address(new ZeroBalanceFuse(MARKET_ID)));

        _updateBalancesPreHook = new UpdateBalancesPreHook();
        _ignoreDustPreHook = new UpdateBalancesIgnoreDustPreHook();
        _exchangeRateValidatorPreHook = new ExchangeRateValidatorPreHook(ERV_MARKET_ID);

        _depositDirect(_USER, 1_000e18);
        _depositDirect(_ALPHA, 1_000e18);
    }

    // ---------------------------------------------------------------- helpers

    function _depositDirect(address who_, uint256 amount_) internal {
        _token.mint(who_, amount_);
        vm.startPrank(who_);
        IERC20(address(_token)).approve(_plasmaVault, amount_);
        PlasmaVault(_plasmaVault).deposit(amount_, who_);
        vm.stopPrank();
    }

    function _wire(bytes4 selector_, address hook_, bytes32[] memory hookSubstrates_) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory hooks = new address[](1);
        hooks[0] = hook_;
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = hookSubstrates_;
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).setPreHookImplementations(selectors, hooks, substrates);
    }

    function _wireUpdateBalances(bytes4 selector_) internal {
        _wire(selector_, address(_updateBalancesPreHook), new bytes32[](0));
    }

    function _wireIgnoreDust(bytes4 selector_) internal {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(uint256(0)); // dust threshold 0 -> every active market is refreshed
        _wire(selector_, address(_ignoreDustPreHook), s);
    }

    /// @dev ExchangeRateValidatorPreHook on the selector, UpdateBalancesPreHook nested as its pre-hook #0
    function _wireNestedUnderExchangeRateValidator(bytes4 selector_) internal {
        bytes32[] memory ervSubstrates = new bytes32[](1);
        ervSubstrates[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(
                    Hook({hookAddress: address(_updateBalancesPreHook), index: 0})
                )
            })
        );
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(ERV_MARKET_ID, ervSubstrates);
        _wire(selector_, address(_exchangeRateValidatorPreHook), new bytes32[](0));
    }

    function _relay(address sender_, bytes memory data_) internal {
        address[] memory targets = new address[](1);
        targets[0] = _plasmaVault;
        bytes[] memory datas = new bytes[](1);
        datas[0] = data_;
        vm.prank(sender_);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: datas}));
    }

    function _relaySigned(uint256 pk_, bytes memory data_) internal {
        address sender = vm.addr(pk_);
        uint256 expiration = block.timestamp + 1 hours;
        uint256 nonce = 1;
        bytes32 digest = keccak256(
            abi.encodePacked(address(_contextManager), expiration, nonce, block.chainid, _plasmaVault, data_)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk_, digest);
        ContextDataWithSender[] memory batch = new ContextDataWithSender[](1);
        batch[0] = ContextDataWithSender({
            sender: sender,
            expirationTime: expiration,
            nonce: nonce,
            target: _plasmaVault,
            data: data_,
            signature: abi.encodePacked(r, s, v)
        });
        vm.prank(address(0xBEEF)); // any relayer
        _contextManager.runWithContextAndSignature(batch);
    }

    function _withdrawData(address owner_, address receiver_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PlasmaVault.withdraw.selector, 10e18, receiver_, owner_);
    }

    function _redeemData(address owner_, address receiver_) internal pure returns (bytes memory) {
        // 5e18 assets worth of shares (PlasmaVault decimals offset = 2)
        return abi.encodeWithSelector(PlasmaVault.redeem.selector, uint256(5e20), receiver_, owner_);
    }

    function _unauthorized(address who_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, who_);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;
        address[] memory updateBalancesAccounts = new address[](1);
        updateBalancesAccounts[0] = _ALPHA; // only ALPHA (and the vault itself) hold UPDATE_MARKETS_BALANCES_ROLE

        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: new address[](0),
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: updateBalancesAccounts,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(_contextManager),
                priceOracleMiddlewareManager: address(0x123)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.prank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
    }

    // ---------------------------------------------------------------- controls

    function testShouldWithdrawDirectlyWithUpdateBalancesPreHook() public {
        _wireUpdateBalances(PlasmaVault.withdraw.selector);
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(10e18, address(0xB0B), _USER);
        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
    }

    function testShouldWithdrawThroughContextManagerWithoutHook() public {
        _relay(_USER, _withdrawData(_USER, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
    }

    // ---------------------------------------------------------------- IL-8310: relayed calls with the hook wired

    function testShouldWithdrawThroughContextManagerWithUpdateBalancesPreHook() public {
        _wireUpdateBalances(PlasmaVault.withdraw.selector);
        _relay(_USER, _withdrawData(_USER, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
    }

    function testShouldRedeemThroughContextManagerWithUpdateBalancesPreHook() public {
        _wireUpdateBalances(PlasmaVault.redeem.selector);
        _relay(_USER, _redeemData(_USER, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 5e18);
    }

    function testShouldRedeemThroughContextManagerWithIgnoreDustPreHook() public {
        _wireIgnoreDust(PlasmaVault.redeem.selector);
        _relay(_USER, _redeemData(_USER, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 5e18);
    }

    function testShouldWithdrawThroughContextManagerWithIgnoreDustPreHook() public {
        _wireIgnoreDust(PlasmaVault.withdraw.selector);
        _relay(_USER, _withdrawData(_USER, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
    }

    function testShouldDepositThroughContextManagerWithUpdateBalancesPreHook() public {
        _wireUpdateBalances(PlasmaVault.deposit.selector);
        _token.mint(_USER, 100e18);
        vm.prank(_USER);
        IERC20(address(_token)).approve(_plasmaVault, 100e18);
        uint256 sharesBefore = PlasmaVault(_plasmaVault).balanceOf(_USER);
        _relay(_USER, abi.encodeWithSelector(PlasmaVault.deposit.selector, 100e18, _USER));
        assertGt(PlasmaVault(_plasmaVault).balanceOf(_USER), sharesBefore);
    }

    function testShouldDepositThroughContextManagerWithIgnoreDustPreHook() public {
        _wireIgnoreDust(PlasmaVault.deposit.selector);
        _token.mint(_USER, 100e18);
        vm.prank(_USER);
        IERC20(address(_token)).approve(_plasmaVault, 100e18);
        uint256 sharesBefore = PlasmaVault(_plasmaVault).balanceOf(_USER);
        _relay(_USER, abi.encodeWithSelector(PlasmaVault.deposit.selector, 100e18, _USER));
        assertGt(PlasmaVault(_plasmaVault).balanceOf(_USER), sharesBefore);
    }

    function testShouldWithdrawThroughContextManagerWithUpdateBalancesNestedUnderExchangeRateValidator() public {
        _wireNestedUnderExchangeRateValidator(PlasmaVault.withdraw.selector);
        _relay(_USER, _withdrawData(_USER, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
    }

    function testShouldDepositThroughSignedContextWithUpdateBalancesPreHook() public {
        _wireUpdateBalances(PlasmaVault.deposit.selector);
        _token.mint(_user2, 100e18);
        vm.prank(_user2);
        IERC20(address(_token)).approve(_plasmaVault, 100e18);
        _relaySigned(_USER2_PK, abi.encodeWithSelector(PlasmaVault.deposit.selector, 100e18, _user2));
        assertGt(PlasmaVault(_plasmaVault).balanceOf(_user2), 0);
    }

    function testShouldWithdrawThroughSignedContextWithIgnoreDustPreHook() public {
        _wireIgnoreDust(PlasmaVault.withdraw.selector);
        _depositDirect(_user2, 100e18);
        _relaySigned(_USER2_PK, _withdrawData(_user2, address(0xB0B)));
        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
    }

    function testShouldWithdrawThroughContextManagerByUpdateBalancesRoleHolder() public {
        _wireUpdateBalances(PlasmaVault.withdraw.selector);
        _relay(_ALPHA, _withdrawData(_ALPHA, address(0xA1FA)));
        assertEq(_token.balanceOf(address(0xA1FA)), 10e18);
    }

    // ---------------------------------------------------------------- IL-8310: no privilege leak to the context sender

    /// @dev The outer relayed call has the ContextManager as msg.sender, so it is still authorized against the user
    function testShouldRevertWhenUserUpdatesMarketsBalancesThroughContextManager() public {
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        vm.expectRevert(_unauthorized(_USER));
        _relay(_USER, abi.encodeWithSelector(PlasmaVault.updateMarketsBalances.selector, markets));
    }

    function testShouldRevertWhenUserUpdatesMarketsBalancesDirectly() public {
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        vm.expectRevert(_unauthorized(_USER));
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets);
    }

    function testShouldRevertWhenUserExecutesThroughContextManager() public {
        vm.expectRevert(_unauthorized(_USER));
        _relay(_USER, abi.encodeWithSignature("execute((address,bytes)[])", new bytes[](0)));
    }

    function testShouldRevertWhenUserExecutesThroughContextManagerWithHookOnExecute() public {
        _wireUpdateBalances(PlasmaVault.execute.selector);
        vm.expectRevert(_unauthorized(_USER));
        _relay(_USER, abi.encodeWithSignature("execute((address,bytes)[])", new bytes[](0)));
    }

    // ---------------------------------------------------------------- IL-8310: self-calls into PlasmaVaultBase

    function testShouldWithdrawThroughContextManagerWithHookSelfCallingPlasmaVaultBase() public {
        address hook = address(new SelfCallBaseGovernancePreHook());
        vm.prank(_ATOMIST);
        IporFusionAccessManager(_accessManager).grantRole(Roles.ATOMIST_ROLE, _plasmaVault, 0);
        _wire(PlasmaVault.withdraw.selector, hook, new bytes32[](0));

        _relay(_USER, _withdrawData(_USER, address(0xB0B)));

        assertEq(_token.balanceOf(address(0xB0B)), 10e18);
        assertEq(
            IPlasmaVaultGovernance(_plasmaVault).getTotalSupplyCap(),
            SelfCallBaseGovernancePreHook(hook).NEW_TOTAL_SUPPLY_CAP()
        );
    }

    function testShouldRevertWhenUserCallsPlasmaVaultBaseGovernanceThroughContextManager() public {
        vm.expectRevert(_unauthorized(_USER));
        _relay(_USER, abi.encodeWithSelector(IPlasmaVaultGovernance.setTotalSupplyCap.selector, uint256(1)));
    }
}
