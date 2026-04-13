// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../../test/OlympixUnitTest.sol";
import {USDMPriceFeedArbitrum} from "../../../../../../contracts/price_oracle/price_feed/chains/arbitrum/USDMPriceFeedArbitrum.sol";

import {USDMPriceFeedArbitrum} from "contracts/price_oracle/price_feed/chains/arbitrum/USDMPriceFeedArbitrum.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {IChronicle} from "contracts/price_oracle/ext/IChronicle.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
contract USDMPriceFeedArbitrumTest is OlympixUnitTest("USDMPriceFeedArbitrum") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_RevertsWhenChroniclePriceZero() public {
            // Deploy feed (constructor will call CHRONICLE.decimals on the real address, which on-local fails).
            // To avoid that, we mock the decimals() call BEFORE deployment so constructor succeeds.
            address chronicle = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    
            // Mock decimals() during construction so the constructor's check passes
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.decimals.selector),
                abi.encode(uint8(18))
            );
    
            USDMPriceFeedArbitrum feed = new USDMPriceFeedArbitrum();
    
            // Now mock read() to return 0 so that wUsdMPriceUSD == 0 and we enter the opix-target-branch-56-True path
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.read.selector),
                abi.encode(uint256(0))
            );
    
            // Expect revert with custom error WrongValue when wUsdMPriceUSD == 0
            vm.expectRevert(Errors.WrongValue.selector);
            feed.latestRoundData();
        }

    function test_decimals_Returns8_HitsTrueBranch() public {
        // The constructor of USDMPriceFeedArbitrum calls CHRONICLE.decimals() on
        // the real Chronicle address. On a local test chain this would revert
        // unless we mock it beforehand.
        address chronicle = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    
        // Mock decimals() so constructor check passes
        vm.mockCall(
            chronicle,
            abi.encodeWithSelector(IChronicle.decimals.selector),
            abi.encode(uint8(18))
        );
    
        USDMPriceFeedArbitrum feed = new USDMPriceFeedArbitrum();
    
        // decimals() has an `if (true)` branch (opix-target-branch-43-True)
        // that returns _decimals(), which itself returns 8 behind another
        // `if (true)` branch. Just calling decimals() is enough to hit both.
        uint8 d = feed.decimals();
    
        assertEq(d, 8, "USDMPriceFeedArbitrum: decimals should be 8");
    }

    function test_latestRoundData_ChronicleNonZero_EntersElseBranch() public {
            address chronicle = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
            address wusdm = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
    
            // Mock decimals() so constructor check passes
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.decimals.selector),
                abi.encode(uint8(18))
            );
    
            USDMPriceFeedArbitrum feed = new USDMPriceFeedArbitrum();
    
            // Make Chronicle.read() return non‑zero so wUsdMPriceUSD != 0 and we hit the opix-target-branch-58 else-branch
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.read.selector),
                abi.encode(uint256(1e18))
            );
    
            // Mock IERC4626(WUSDM).totalSupply() to non‑zero so we also hit its else-branch.
            // We cannot reference IERC4626.totalSupply.selector directly (interface not visible here),
            // so we hardcode the selector via keccak256.
            vm.mockCall(
                wusdm,
                abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
                abi.encode(uint256(1e18))
            );
    
            // Mock totalAssets() so price computation is non‑zero and final WrongValue revert is not triggered
            vm.mockCall(
                wusdm,
                abi.encodeWithSelector(bytes4(keccak256("totalAssets()"))),
                abi.encode(uint256(2e18))
            );
    
            // Call should succeed (no revert) and thus execute the opix-target-branch-58-False else-branch
            (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed.latestRoundData();
    
            assertEq(roundId, 0);
            assertGt(price, 0);
            assertEq(startedAt, 0);
            assertEq(time, 0);
            assertEq(answeredInRound, 0);
        }

    function test_latestRoundData_RevertsWhenTotalSupplyZero() public {
            address chronicle = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
            address wusdm = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
    
            // Mock Chronicle.decimals() for constructor so it does not revert
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.decimals.selector),
                abi.encode(uint8(18))
            );
    
            USDMPriceFeedArbitrum feed = new USDMPriceFeedArbitrum();
    
            // Mock Chronicle.read() to return non-zero price so we pass the first check
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.read.selector),
                abi.encode(uint256(1e18))
            );
    
            // Mock IERC4626(WUSDM).totalSupply() to return 0 to trigger opix-target-branch-64-True path
            // IERC4626 is an interface, we just encode its selector manually as a bytes4
            vm.mockCall(
                wusdm,
                abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
                abi.encode(uint256(0))
            );
    
            // Expect revert with WrongValue when totalSupply == 0
            vm.expectRevert(Errors.WrongValue.selector);
            feed.latestRoundData();
        }

    function test_latestRoundData_RevertsWhenUsdmPriceZero() public {
            address chronicle = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
            address wusdm = 0x57F5E098CaD7A3D1Eed53991D4d66C45C9AF7812;
    
            // Make constructor succeed (decimals check)
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.decimals.selector),
                abi.encode(uint8(18))
            );
    
            USDMPriceFeedArbitrum feed = new USDMPriceFeedArbitrum();
    
            // Chronicle price non-zero so first check passes
            vm.mockCall(
                chronicle,
                abi.encodeWithSelector(IChronicle.read.selector),
                abi.encode(uint256(1e18))
            );
    
            // totalSupply non-zero so second check passes (use raw selector to avoid IERC4626 import issues)
            vm.mockCall(
                wusdm,
                abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))),
                abi.encode(uint256(1e18))
            );
    
            // totalAssets == 0 → wUsdMUsdmExchangeRate == 0 → usdmPriceUSD == 0 → hits opix-target-branch-78-True
            vm.mockCall(
                wusdm,
                abi.encodeWithSelector(bytes4(keccak256("totalAssets()"))),
                abi.encode(uint256(0))
            );
    
            vm.expectRevert(Errors.WrongValue.selector);
            feed.latestRoundData();
        }
}