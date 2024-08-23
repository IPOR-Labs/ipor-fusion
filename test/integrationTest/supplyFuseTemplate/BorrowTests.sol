// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {TestAccountSetup} from "./TestAccountSetup.sol";
import {TestPriceOracleSetup} from "./TestPriceOracleSetup.sol";
import {TestVaultSetup} from "./TestVaultSetup.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";

abstract contract BorrowTest is TestAccountSetup, TestPriceOracleSetup, TestVaultSetup {
    uint256 public constant ERROR_DELTA = 100;
    address public borrowAsset;

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

    function setupBorrowAsset() public virtual;

    function setupPriceOracle() public virtual override returns (address[] memory assets, address[] memory sources);

    function setupMarketConfigs() public virtual override returns (MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual override;

    function setupBalanceFuses() public virtual override returns (MarketBalanceFuseConfig[] memory balanceFuses);

    function getMarketId() public view virtual returns (uint256) {
        return 1;
    }

    function getEnterFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data);

    function getExitFuseData(
        uint256 amount_,
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data);

    function generateEnterCallsData(
        uint256 amount_,
        bytes32[] memory data_
    ) private returns (FuseAction[] memory enterCalls) {
        bytes[] memory enterData = getEnterFuseData(amount_, data_);
        uint256 len = enterData.length;
        enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fuses[i], abi.encodeWithSignature("enter(bytes)", enterData[i]));
        }
        return enterCalls;
    }

    function generateExitCallsData(
        uint256 amount_,
        bytes32[] memory data_
    ) private returns (FuseAction[] memory enterCalls) {
        (address[] memory fusesSetup, bytes[] memory enterData) = getExitFuseData(amount_, data_);
        uint256 len = enterData.length;
        enterCalls = new FuseAction[](len);
        for (uint256 i = 0; i < len; ++i) {
            enterCalls[i] = FuseAction(fusesSetup[i], abi.encodeWithSignature("exit(bytes)", enterData[i]));
        }
        return enterCalls;
    }
}
