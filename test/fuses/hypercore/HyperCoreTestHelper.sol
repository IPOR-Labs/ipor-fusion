// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {HyperCoreHookWiringLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreHookWiringLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockHyperCorePrecompiles, HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";

/// @title HyperCoreMockUsdc
/// @notice Minimal USDC-like ERC20 mock (6 decimals) used as the underlying token for HyperCore
/// vault test fixtures built by `HyperCoreTestHelper.deployVaultWithHyperCoreMarket`.
contract HyperCoreMockUsdc is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test double for the IL-8529 wiring gate: carries the CapitalFlow marker but does nothing, so unit
///      fixtures that never exercised the hook keep their behaviour while the action fuses see a wired vault.
contract HyperCoreMarkerOnlyCapitalFlowPreHook {
    function HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID() external pure returns (bytes32) {
        return HyperCoreHookWiringLib.CAPITAL_FLOW_PRE_HOOK_ID;
    }

    function run(bytes4) external {}
}

/// @title HyperCoreTestHelper
/// @notice Test-only helper wiring the HyperCore mocks (`MockCoreWriter`, `MockHyperCorePrecompiles`)
/// and a minimal `PlasmaVault` for HyperCore fuse / lib unit tests. Substrate encoding helpers live in
/// `HyperCoreSubstrateLib` (owned separately) and are not duplicated here.
library HyperCoreTestHelper {
    /// @dev PlasmaVaultStorageLib.CFG_PLASMA_VAULT_PRE_HOOKS (slot of PreHooksConfig.hooksImplementation).
    bytes32 internal constant PRE_HOOKS_SLOT = 0xd334d8b26e68f82b7df26f2f64b6ffd2aaae5e2fc0e8c144c4b3598dcddd4b00;

    /// @notice Points the six share-priced selectors of `target_` (a vault or a delegatecall harness) at `hook_`.
    function wireFlows(address target_, address hook_) internal {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        bytes4[6] memory flows = [
            PlasmaVault.deposit.selector,
            PlasmaVault.depositWithPermit.selector,
            PlasmaVault.mint.selector,
            PlasmaVault.withdraw.selector,
            PlasmaVault.redeem.selector,
            PlasmaVault.redeemFromRequest.selector
        ];
        for (uint256 i; i < flows.length; ++i) {
            vm.store(
                target_,
                keccak256(abi.encode(bytes32(flows[i]), PRE_HOOKS_SLOT)),
                bytes32(uint256(uint160(hook_)))
            );
        }
    }

    /// @dev Real HyperEVM CoreWriter system-contract address (see chat/INTERFACES.md).
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;

    /// @dev First HyperCore read-precompile address (`position`).
    address internal constant PRECOMPILE_RANGE_START = 0x0000000000000000000000000000000000000800;

    /// @dev Precompile addresses 0x800..0x810 inclusive.
    uint256 internal constant PRECOMPILE_COUNT = 17;

    /// @dev `position2` precompile address. Etched separately from the `PRECOMPILE_RANGE_START` loop
    /// since it is not contiguous with `0x800`..`0x810` (`0x811`/`0x812` stay un-etched).
    address internal constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;

    /// @notice Deploys the shared `HyperCoreMockState` and `vm.etch`es `MockHyperCorePrecompiles`
    /// (byte-identical code) at every HyperCore read-precompile address `0x800`..`0x810`, plus the
    /// non-contiguous `position2` address `0x813`, wiring each etched address to the state contract
    /// via a `vm.store` write to its slot-0 `state` variable.
    /// @return state The shared mock state contract; use its setters to configure fixture data.
    function etchPrecompiles(Vm vm) internal returns (HyperCoreMockState state) {
        MockHyperCorePrecompiles template = new MockHyperCorePrecompiles();
        bytes memory code = address(template).code;

        state = new HyperCoreMockState();
        bytes32 stateSlotValue = bytes32(uint256(uint160(address(state))));

        for (uint256 i; i < PRECOMPILE_COUNT; ++i) {
            address precompile = address(uint160(uint160(PRECOMPILE_RANGE_START) + i));
            vm.etch(precompile, code);
            vm.store(precompile, bytes32(0), stateSlotValue);
        }

        vm.etch(POSITION2_PRECOMPILE, code);
        vm.store(POSITION2_PRECOMPILE, bytes32(0), stateSlotValue);
    }

    /// @notice Deploys `MockCoreWriter` and `vm.etch`es it at the real CoreWriter address so
    /// `HyperCoreLib.sendRawAction` calls land on the mock during tests.
    function etchCoreWriter(Vm vm) internal returns (MockCoreWriter coreWriter) {
        MockCoreWriter template = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(template).code);
        coreWriter = MockCoreWriter(CORE_WRITER);
    }

    /// @notice Deploys a minimal `PlasmaVault` (mock 6-decimal USDC underlying, zero fees) intended
    /// for HyperCore fuse/lib tests. Does not add fuses, grant substrates, or register market 55 —
    /// callers wire those with `PlasmaVaultHelper`/`PlasmaVaultConfigurator` as needed.
    /// @return plasmaVault The deployed vault.
    /// @return withdrawManager The vault's withdraw manager.
    /// @return usdc The mock 6-decimal USDC underlying token.
    /// @return priceOracleMiddleware The deployed price oracle middleware (no sources configured).
    function deployVaultWithHyperCoreMarket(
        address atomist
    )
        internal
        returns (
            PlasmaVault plasmaVault,
            address withdrawManager,
            HyperCoreMockUsdc usdc,
            PriceOracleMiddleware priceOracleMiddleware
        )
    {
        usdc = new HyperCoreMockUsdc();
        priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(atomist, address(0));

        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(
            DeployMinimalPlasmaVaultParams({
                underlyingToken: address(usdc),
                underlyingTokenName: "USDC",
                priceOracleMiddleware: address(priceOracleMiddleware),
                atomist: atomist
            })
        );
        wireFlows(address(plasmaVault), address(new HyperCoreMarkerOnlyCapitalFlowPreHook()));
    }
}
