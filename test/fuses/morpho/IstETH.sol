pragma solidity 0.8.26;

interface IstETH {
    /**
     * @notice Send funds to the pool with optional _referral parameter
     * @dev This function is alternative way to submit funds. Supports optional referral address.
     * @return Amount of StETH shares generated
     */
    function submit(address _referral) external payable returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
