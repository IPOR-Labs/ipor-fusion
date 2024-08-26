// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../../../ext/AggregatorV3Interface.sol";

import {IPriceFeed} from "../../IPriceFeed.sol";
import {IWstETH} from "../../ext/IWstETH.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";

/// @title Price feed for sDai on Ethereum Mainnet
contract WstETHPriceFeedEthereum is IPriceFeed {
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @dev  Price Oracle for pair stETH USD on Ethereum Mainnet
    address public constant ST_ETH_CHAINLINK_FEED = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    constructor() {
        /// @def Notice! It is enough to check during construction not during runtime because DAI_CHAINLINK_FEED is immutable not upgradeable contract and decimals are not expected to change.
        if (_decimals() != AggregatorV3Interface(ST_ETH_CHAINLINK_FEED).decimals()) {
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
        (, int256 answer, , , ) = AggregatorV3Interface(ST_ETH_CHAINLINK_FEED).latestRoundData();

        uint256 stEthRatio = IWstETH(WST_ETH).getStETHByWstETH(1e18);

        return (uint80(0), Math.mulDiv(answer.toUint256(), stEthRatio, 1e18).toInt256(), 0, 0, 0);
    }

    function _decimals() internal view returns (uint8) {
        return 8;
    }
}
