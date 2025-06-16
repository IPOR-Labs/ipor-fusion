// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {CollateralTokenOnMorphoMarketPriceFeed} from "./CollateralTokenOnMorphoMarketPriceFeed.sol";

struct PriceFeed {
    address morphoOracle;
    address collateralToken;
    address loanToken;
    address fusionPriceMiddleware;
    address priceFeed;
    address creator;
}

contract CollateralTokenOnMorphoMarketPriceFeedFactory {
    event PriceFeedCreated(
        address priceFeed,
        address creator,
        address morphoOracle,
        address collateralToken,
        address loanToken,
        address fusionPriceMiddleware
    );

    error ZeroAddress();
    error PriceFeedAlreadyExists();

    mapping(bytes32 key => PriceFeed priceFeed) private priceFeedsByKeys;
    address[] public priceFeeds;

    mapping(address creator_ => bool) public isCreator;
    address[] public creators;

    function createPriceFeed(
        address morphoOracle_,
        address collateralToken_,
        address loanToken_,
        address fusionPriceMiddleware_
    ) external returns (address priceFeed) {
        if (morphoOracle_ == address(0)) revert ZeroAddress();
        if (collateralToken_ == address(0)) revert ZeroAddress();
        if (loanToken_ == address(0)) revert ZeroAddress();
        if (fusionPriceMiddleware_ == address(0)) revert ZeroAddress();

        if (
            getPriceFeed(msg.sender, morphoOracle_, collateralToken_, loanToken_, fusionPriceMiddleware_) != address(0)
        ) {
            revert PriceFeedAlreadyExists();
        }

        priceFeed = address(
            new CollateralTokenOnMorphoMarketPriceFeed(
                morphoOracle_,
                collateralToken_,
                loanToken_,
                fusionPriceMiddleware_
            )
        );

        if (!isCreator[msg.sender]) {
            isCreator[msg.sender] = true;
            creators.push(msg.sender);
        }

        bytes32 key = generateKey(msg.sender, morphoOracle_, collateralToken_, loanToken_, fusionPriceMiddleware_);
        priceFeedsByKeys[key] = PriceFeed(
            morphoOracle_,
            collateralToken_,
            loanToken_,
            fusionPriceMiddleware_,
            priceFeed,
            msg.sender
        );

        priceFeeds.push(priceFeed);

        emit PriceFeedCreated(
            priceFeed,
            msg.sender,
            morphoOracle_,
            collateralToken_,
            loanToken_,
            fusionPriceMiddleware_
        );

        return priceFeed;
    }

    function getPriceFeedAddress(
        address creator_,
        address morphoOracle_,
        address collateralToken_,
        address loanToken_,
        address fusionPriceMiddleware_
    ) external view returns (address) {
        bytes32 key = generateKey(creator_, morphoOracle_, collateralToken_, loanToken_, fusionPriceMiddleware_);
        return priceFeedsByKeys[key].priceFeed;
    }

    function getPriceFeed(
        address creator_,
        address morphoOracle_,
        address collateralToken_,
        address loanToken_,
        address fusionPriceMiddleware_
    ) public view returns (address) {
        bytes32 key = generateKey(creator_, morphoOracle_, collateralToken_, loanToken_, fusionPriceMiddleware_);
        return priceFeedsByKeys[key].priceFeed;
    }

    function generateKey(
        address creator_,
        address morphoOracle_,
        address collateralToken_,
        address loanToken_,
        address fusionPriceMiddleware_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(creator_, morphoOracle_, collateralToken_, loanToken_, fusionPriceMiddleware_));
    }
}
