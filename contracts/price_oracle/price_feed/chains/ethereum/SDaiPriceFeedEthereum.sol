// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../../../ext/AggregatorV3Interface.sol";

import {IPriceFeed} from "../../IPriceFeed.sol";
import {ISavingsDai} from "../../ext/ISavingsDai.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";

/// @title Price feed for sDai on Ethereum Mainnet
contract SDaiPriceFeedEthereum is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev  Price Oracle for pair DAI USD on Ethereum Mainnet
    address public constant DAI_CHAINLINK_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;

    constructor() {
        /// @def Notice! It is enough to check during construction not during runtime because DAI_CHAINLINK_FEED is immutable not upgradeable contract and decimals are not expected to change.
        if (_decimals() != AggregatorV3Interface(DAI_CHAINLINK_FEED).decimals()) {
            revert Errors.WrongDecimals();
        }
    }

    function decimals() external view override returns (uint8) {
        return _decimals();
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound)
    {
        (, int256 answer, , , ) = AggregatorV3Interface(DAI_CHAINLINK_FEED).latestRoundData();
        uint256 sdaiExchangeRatio = ISavingsDai(SDAI).convertToAssets(1e18);
        return (uint80(0), Math.mulDiv(answer.toUint256(), sdaiExchangeRatio, 1e18).toInt256(), 0, 0, 0);
    }

    function _decimals() internal view returns (uint8) {
        return 8;
    }
}
