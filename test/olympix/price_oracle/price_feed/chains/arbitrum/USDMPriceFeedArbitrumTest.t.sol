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
}