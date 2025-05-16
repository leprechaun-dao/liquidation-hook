// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMockOracle
 * @notice Interface for the mock oracle
 */
interface IMockOracle {
    /**
     * @notice Get the USD value of a token amount
     * @param token The token address
     * @param amount The token amount
     * @param decimals The token decimals (optional)
     * @return The USD value (scaled by 1e18)
     */
    function getUsdValue(address token, uint256 amount, uint8 decimals) external view returns (uint256);
    
    /**
     * @notice Simplified version that uses stored decimals
     * @param token The token address
     * @param amount The token amount
     * @return The USD value (scaled by 1e18)
     */
    function getUsdValue(address token, uint256 amount) external view returns (uint256);
    
    /**
     * @notice Get the amount of tokens equivalent to a USD value
     * @param token The token address
     * @param usdValue The USD value (scaled by 1e18)
     * @param decimals The token decimals (optional)
     * @return The token amount
     */
    function getTokenAmount(address token, uint256 usdValue, uint8 decimals) external view returns (uint256);
    
    /**
     * @notice Simplified version that uses stored decimals
     * @param token The token address
     * @param usdValue The USD value (scaled by 1e18)
     * @return The token amount
     */
    function getTokenAmount(address token, uint256 usdValue) external view returns (uint256);
}
