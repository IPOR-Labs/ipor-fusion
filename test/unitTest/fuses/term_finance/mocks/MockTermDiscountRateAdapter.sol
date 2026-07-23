// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

contract MockTermDiscountRateAdapter {
    mapping(address => uint256) public rates;
    mapping(address => uint256) public haircuts;
    address public currTermController;
    address public prevTermController;

    bool public getDiscountRateReverts;
    bool public haircutReverts;

    function setRate(address repoToken_, uint256 rate_) external {
        rates[repoToken_] = rate_;
    }

    function setHaircut(address repoToken_, uint256 hcut_) external {
        haircuts[repoToken_] = hcut_;
    }

    function setCurrTermController(address c_) external {
        currTermController = c_;
    }

    function setPrevTermController(address c_) external {
        prevTermController = c_;
    }

    function setGetDiscountRateReverts(bool r_) external {
        getDiscountRateReverts = r_;
    }

    function setHaircutReverts(bool r_) external {
        haircutReverts = r_;
    }

    function getDiscountRate(address repoToken_) external view returns (uint256) {
        if (getDiscountRateReverts) revert("MockAdapter: getDiscountRate reverts");
        return rates[repoToken_];
    }

    function getDiscountRate(address, address repoToken_) external view returns (uint256) {
        if (getDiscountRateReverts) revert("MockAdapter: getDiscountRate(addr,addr) reverts");
        return rates[repoToken_];
    }

    function repoRedemptionHaircut(address repoToken_) external view returns (uint256) {
        if (haircutReverts) revert("MockAdapter: haircut reverts");
        return haircuts[repoToken_];
    }

    function rateInvalid(address, bytes32) external pure returns (bool) {
        return false;
    }
}
