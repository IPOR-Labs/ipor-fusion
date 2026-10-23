// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {HyperCoreTestHelper} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockPriceOracle} from "../aave_v4/MockPriceOracle.sol";

/// @dev 18-decimal underlying (not a 6-decimal token) so the stored-value conversion cannot be a fixed scale.
contract HyperCoreNavJumpUnderlying18 is ERC20 {
    constructor() ERC20("Mock 18", "M18") {}
}

/// @dev Minimal vault stand-in: `liveValueWad` runs in the harness storage context exactly like in a vault delegatecall.
contract HyperCoreNavJumpConversionHarness {
    uint256 private constant MARKET_ID = 55;

    address private _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function setOracle(address oracle_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
    }

    function grant(bytes32[] calldata substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(MARKET_ID, substrates_);
    }

    function setStored(uint256 stored_) external {
        PlasmaVaultLib.updateTotalAssetsInMarket(MARKET_ID, stored_);
    }

    function liveValueWad() external view returns (uint256) {
        return HyperCoreValuationLib.liveValueWad(MARKET_ID);
    }
}

/// @notice IL-8957 (C-036): the NAV jump breaker converts the stored market value (underlying units) to USD WAD with the
///         underlying's oracle price and decimals. The underlying here has 18 decimals and costs 2 USD, while the Core
///         leg is spot USDC at 1 USD, so any fixed-scale or price-less conversion changes the compared values.
contract HyperCoreNavJumpConversionTest is Test {
    uint64 private constant USDC_INDEX = 0;
    uint256 private constant STORED = 500e18;
    /// @dev 1 500 USDC in Core wei (8 decimals).
    uint64 private constant SPOT_AT_BOUNDARY = 1_500e8;

    HyperCoreMockState private _core;
    MockPriceOracle private _oracle;
    HyperCoreNavJumpUnderlying18 private _underlying;
    HyperCoreNavJumpConversionHarness private _harness;
    address private _usdcEvmAsset;

    function setUp() public {
        _core = HyperCoreTestHelper.etchPrecompiles(vm);
        _oracle = new MockPriceOracle();
        _underlying = new HyperCoreNavJumpUnderlying18();
        _usdcEvmAsset = makeAddr("coreUsdcEvmAsset");
        _harness = new HyperCoreNavJumpConversionHarness(address(_underlying));

        _oracle.setAssetPriceWithDecimals(address(_underlying), 2e8, 8); // underlying = 2 USD
        _oracle.setAssetPriceWithDecimals(_usdcEvmAsset, 1e8, 8); // Core USDC = 1 USD

        _harness.setOracle(address(_oracle));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, _usdcEvmAsset);
        _harness.grant(substrates);
        _core.setCoreUserExists(address(_harness), true);
        _harness.setStored(STORED); // 500e18 underlying * 2 USD = 1000e18 USD WAD
    }

    function testStoredValueIsConvertedWithUnderlyingPriceAndDecimals() public {
        // Exactly +50% over the converted stored value (1000e18 -> 1500e18): inside the default 5000 bps band.
        _setSpotUsdc(SPOT_AT_BOUNDARY);

        assertEq(_harness.liveValueWad(), 1_500e18, "live value at the boundary is returned");

        // A smaller live value is compared against the converted 1000e18 too: -50% is also exactly on the boundary.
        _setSpotUsdc(500e8);
        assertEq(_harness.liveValueWad(), 500e18, "-50% against the converted stored value is accepted");
    }

    function testJustAboveBoundaryRevertsWithExactConvertedArguments() public {
        // 1 500.00000001 USDC -> 1500.00000001e18 USD WAD, one Core wei above +50% of the converted 1000e18.
        _setSpotUsdc(SPOT_AT_BOUNDARY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector,
                1_000e18,
                150_000_000_001e10,
                5000
            )
        );
        _harness.liveValueWad();
    }

    function _setSpotUsdc(uint64 total_) private {
        _core.setSpotBalance(
            address(_harness),
            USDC_INDEX,
            HyperCoreMockState.SpotBalance({total: total_, hold: 0, entryNtl: 0})
        );
    }
}
