// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockOracle
 * @notice A simple mock oracle for price feeds
 */
contract MockOracle {
    // Mapping of token address to price in USD (scaled by 1e18)
    mapping(address => uint256) public tokenPrices;
    
    // Mapping of token address to decimals
    mapping(address => uint8) public tokenDecimals;
    
    /**
     * @notice Set the price of a token
     * @param token The token address
     * @param priceUsd The price in USD (scaled by 1e18)
     * @param decimals The token decimals
     */
    function setTokenPrice(address token, uint256 priceUsd, uint8 decimals) external {
        tokenPrices[token] = priceUsd;
        tokenDecimals[token] = decimals;
    }
    
    /**
     * @notice Get the USD value of a token amount
     * @param token The token address
     * @param amount The token amount
     * @param decimals The token decimals (optional, will use stored value if 0)
     * @return The USD value (scaled by 1e18)
     */
    function getUsdValue(address token, uint256 amount, uint8 decimals) public view returns (uint256) {
        uint8 tokenDecimalsValue = decimals > 0 ? decimals : tokenDecimals[token];
        require(tokenDecimalsValue > 0, "Token decimals not set");
        
        uint256 price = tokenPrices[token];
        require(price > 0, "Token price not set");
        
        // Convert token amount to USD value
        // For a token with 18 decimals: 1 token = 10^18 units
        return (amount * price) / (10 ** tokenDecimalsValue);
    }
    
    /**
     * @notice Simplified version that uses stored decimals
     * @param token The token address
     * @param amount The token amount
     * @return The USD value (scaled by 1e18)
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        return getUsdValue(token, amount, 0);
    }
    
    /**
     * @notice Get the amount of tokens equivalent to a USD value
     * @param token The token address
     * @param usdValue The USD value (scaled by 1e18)
     * @param decimals The token decimals (optional, will use stored value if 0)
     * @return The token amount
     */
    function getTokenAmount(address token, uint256 usdValue, uint8 decimals) public view returns (uint256) {
        uint8 tokenDecimalsValue = decimals > 0 ? decimals : tokenDecimals[token];
        require(tokenDecimalsValue > 0, "Token decimals not set");
        
        uint256 price = tokenPrices[token];
        require(price > 0, "Token price not set");
        
        // Convert USD value to token amount
        return (usdValue * (10 ** tokenDecimalsValue)) / price;
    }
    
    /**
     * @notice Simplified version that uses stored decimals
     * @param token The token address
     * @param usdValue The USD value (scaled by 1e18)
     * @return The token amount
     */
    function getTokenAmount(address token, uint256 usdValue) public view returns (uint256) {
        return getTokenAmount(token, usdValue, 0);
    }
}
