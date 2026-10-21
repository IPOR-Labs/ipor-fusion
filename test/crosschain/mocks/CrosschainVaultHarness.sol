// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";

import {
    StargateCrosschainSupplyFuse,
    StargateCrosschainSupplyFuseEnterData,
    StargateCrosschainSupplyFuseExitData
} from "../../../contracts/fuses/crosschain/stargate/StargateCrosschainSupplyFuse.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData
} from "../../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseEnterData,
    CcipSupplyFuseExitData
} from "../../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandFuseEnterData
} from "../../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {CrosschainRecoveryContextTestLib} from "./CrosschainRecoveryContextTestLib.sol";
import {IPreHook} from "../../../contracts/handlers/pre_hooks/IPreHook.sol";

/// @title CrosschainVaultHarness
/// @notice Minimal PlasmaVault stand-in (storage context) that delegatecalls the crosschain fuses, mirroring
///         `test/fuses/PlasmaVaultMock.sol`. Exposes `asset()` (the supply fuse reads it), substrate grants,
///         the price-oracle-middleware setter, and typed fuse entries + a pre-hook runner.
contract CrosschainVaultHarness {
    using Address for address;

    address public immutable UNDERLYING;

    address public supplyFuse;
    address public claimFuse;
    address public commandFuse;
    address public balanceFuse;
    address public ccipSupplyFuse;
    address public ccipCommandFuse;

    constructor(address underlying_) {
        UNDERLYING = underlying_;
    }

    /// @notice The vault underlying asset (read by `StargateCrosschainSupplyFuse.enter` via `IERC4626(this).asset()`).
    function asset() external view returns (address) {
        return UNDERLYING;
    }

    function setFuses(address supplyFuse_, address claimFuse_, address commandFuse_, address balanceFuse_) external {
        supplyFuse = supplyFuse_;
        claimFuse = claimFuse_;
        commandFuse = commandFuse_;
        balanceFuse = balanceFuse_;
    }

    function setCcipFuses(address supplyFuse_, address commandFuse_) external {
        ccipSupplyFuse = supplyFuse_;
        ccipCommandFuse = commandFuse_;
    }

    function grantSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    /// @notice Mirrors `PlasmaVaultGovernance.getMarketSubstrates` (read by `isNavHealthy`).
    function getMarketSubstrates(uint256 marketId_) external view returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
    }

    function setPriceOracleMiddleware(address priceOracleMiddleware_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function setCachedMarketBalance(uint256 marketId_, uint256 balance_) external {
        PlasmaVaultLib.updateTotalAssetsInMarket(marketId_, balance_);
    }

    // ---------------------------------------------------------------------
    // Typed fuse entries (delegatecall into the vault storage context)
    // ---------------------------------------------------------------------

    function enterSupply(StargateCrosschainSupplyFuseEnterData memory data_) external {
        supplyFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainSupplyFuse.enter, (data_)));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(supplyFuse));
    }

    function exitSupply(StargateCrosschainSupplyFuseExitData memory data_) external {
        supplyFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainSupplyFuse.exit, (data_)));
    }

    function enterClaim(CrosschainClaimFuseEnterData memory data_) external {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (data_)));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(claimFuse));
    }

    function enterCommand(StargateCrosschainCommandFuseEnterData memory data_) external {
        commandFuse.functionDelegateCall(abi.encodeCall(StargateCrosschainCommandFuse.enter, (data_)));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(commandFuse));
    }

    function enterCcipSupply(CcipSupplyFuseEnterData memory data_) external {
        ccipSupplyFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainSupplyFuse.enter, (data_)));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(ccipSupplyFuse));
    }

    function exitCcipSupply(CcipSupplyFuseExitData memory data_) external {
        ccipSupplyFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainSupplyFuse.exit, (data_)));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(ccipSupplyFuse));
    }

    function enterCcipCommand(CcipCommandFuseEnterData memory data_) external {
        ccipCommandFuse.functionDelegateCall(abi.encodeCall(CcipCrosschainCommandFuse.enter, (data_)));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(ccipCommandFuse));
    }

    function balanceOf() external returns (uint256) {
        bytes memory ret = balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()"));
        return abi.decode(ret, (uint256));
    }

    /// @notice Run a claim and then read the market balance WITHOUT clearing the transient recovery
    ///         context in between — the shape `PlasmaVault.execute` has, where `_updateMarketsBalances`
    ///         runs at the end of the same transaction as the fuse calls.
    function enterClaimThenBalanceOf(CrosschainClaimFuseEnterData memory data_) external returns (uint256 value) {
        claimFuse.functionDelegateCall(abi.encodeCall(CrosschainClaimFuse.enter, (data_)));
        bytes memory ret = balanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()"));
        value = abi.decode(ret, (uint256));
        CrosschainRecoveryContextTestLib.clearContext(_marketIdOf(claimFuse));
    }

    function _marketIdOf(address fuse_) private view returns (uint256) {
        return abi.decode(fuse_.functionStaticCall(abi.encodeWithSignature("MARKET_ID()")), (uint256));
    }

    function runPreHook(address preHook_, bytes4 selector_) external {
        preHook_.functionDelegateCall(abi.encodeCall(IPreHook.run, (selector_)));
    }
}
