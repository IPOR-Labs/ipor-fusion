// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {
    CcipCrosschainDispatcher,
    CcipObservation
} from "../../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {TrackedVaultPricingLib} from "../../../contracts/crosschain/lib/TrackedVaultPricingLib.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";

/// @notice Fork, Ethereum block 26186300 (IL-8602 review G-1): a real `CcipCrosschainDispatcher` (this contract plays
///         the factory) holding 1000 USDC in each of four live MetaMorpho USDC vaults (8-12 markets) and one IPOR
///         PlasmaVault. `observation()` prices every one of them with the view budget.
///         Needs ETHEREUM_PROVIDER_URL (archive node), like the other fork suites.
contract TrackedVaultViewBudgetEthereumForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint256 internal constant ETHEREUM_FORK_BLOCK = 26_186_300;

    CcipCrosschainDispatcher internal dispatcher;
    address[] internal vaults;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), ETHEREUM_FORK_BLOCK);
        MockCcipRouter router = new MockCcipRouter();
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(0xE1EC),
            feeToken: address(0),
            messageGasLimit: 3_000_000,
            tokenGasLimit: 3_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            address(this),
            USDC,
            keccak256("USDC"),
            6,
            8453,
            back,
            address(0xA11),
            address(0xB22),
            3 days
        );
        vaults.push(0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB); // MetaMorpho Steakhouse USDC, 12 markets
        vaults.push(0xdd0f28e19C1780eb6396170735D45153D261490d); // MetaMorpho Gauntlet USDC Prime, 8
        vaults.push(0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458); // MetaMorpho Gauntlet USDC Core, 11
        vaults.push(0xd63070114470f685b75B74D60EEc7c1113d33a3D); // MetaMorpho Usual Boosted USDC, 9
        vaults.push(0xc825779C89120eeEf746C51130B362478E181d39); // IPOR PlasmaVault TESS USDC Lending Optimiser
        dispatcher.configureVaults(vaults, true);
        for (uint256 i; i < vaults.length; ++i) {
            try this.depositExt(vaults[i]) {} catch {
                deal(vaults[i], address(dispatcher), 10 ** IERC20Metadata(vaults[i]).decimals());
            }
        }
    }

    function depositExt(address vault_) external {
        deal(USDC, address(this), 1_000e6);
        IERC20(USDC).approve(vault_, 1_000e6);
        IERC4626(vault_).deposit(1_000e6, address(dispatcher));
    }

    /// @notice Before the fix this reported ~2.05 USDC (four vaults unpriced, codes 170) instead of ~4002.05 USDC.
    function testShouldPriceLiveMetaMorphoVaultsInObservation() public {
        CcipObservation memory obs = dispatcher.observation();
        uint256 truth;
        for (uint256 i; i < vaults.length; ++i) {
            truth += IERC4626(vaults[i]).convertToAssets(IERC20(vaults[i]).balanceOf(address(dispatcher)));
        }
        assertEq(obs.unpricedCount, 0, "every live vault priced");
        assertEq(obs.unpricedCodes, 0, "no reason codes");
        assertApproxEqAbs(obs.accountedBalance, truth, 5, "the view reports the real value");
        assertGt(obs.accountedBalance, 4_000e6, "about 4000 USDC in the vaults");
    }
}

/// @notice Runs the pricing library against a live vault, as the dispatcher's views and responses do.
contract TrackedVaultPricingProbe {
    function priceOnChain(address vault_, address holder_, address asset_) external view returns (uint256, uint8) {
        return TrackedVaultPricingLib.price(vault_, holder_, asset_);
    }

    function priceView(address vault_, address holder_, address asset_) external view returns (uint256, uint8) {
        return TrackedVaultPricingLib.price(vault_, holder_, asset_, TrackedVaultPricingLib.VIEW_CONVERT_GAS);
    }
}

/// @notice Fork, Base block 52569400: the same cold vault is unpriced under the on-chain budget and priced under the
///         view budget. Needs BASE_PROVIDER_URL (archive node).
contract TrackedVaultViewBudgetBaseForkTest is Test {
    address internal constant HOLDER = address(0xE0E0E0);
    address internal constant STEAKHOUSE_USDC_BASE = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;
    uint256 internal constant BASE_FORK_BLOCK = 52_569_400;

    TrackedVaultPricingProbe internal probe;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), BASE_FORK_BLOCK);
        probe = new TrackedVaultPricingProbe();
        address asset = IERC4626(STEAKHOUSE_USDC_BASE).asset();
        deal(asset, address(this), 1_000e6);
        IERC20(asset).approve(STEAKHOUSE_USDC_BASE, 1_000e6);
        IERC4626(STEAKHOUSE_USDC_BASE).deposit(1_000e6, HOLDER);
    }

    function testShouldPriceAColdMultiMarketVaultUnderTheViewBudgetOnly() public {
        address v = STEAKHOUSE_USDC_BASE;
        address asset = IERC4626(v).asset();
        (uint256 onChainAssets, uint8 onChainReason) = probe.priceOnChain(v, HOLDER, asset);
        assertEq(onChainReason, TrackedVaultPricingLib.UNPRICED_CONVERT_TO_ASSETS, "cold read exceeds 200k");
        assertEq(onChainAssets, 0, "on-chain budget: counted as zero");
        vm.cool(v); // the failed on-chain read leaves it cold anyway; make the view read independent of that
        (uint256 viewAssets, uint8 viewReason) = probe.priceView(v, HOLDER, asset);
        assertEq(viewReason, TrackedVaultPricingLib.PRICED, "the view budget covers the cold read");
        assertEq(viewAssets, IERC4626(v).convertToAssets(IERC20(v).balanceOf(HOLDER)), "full value");
    }
}
