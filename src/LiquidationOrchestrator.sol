// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FlashLiquidationHook} from "./FlashLiquidationHook.sol";
import {ILiquidationProtocol} from "./interfaces/ILiquidationProtocol.sol";

/**
 * @title LiquidationOrchestrator
 * @notice A contract to manage and orchestrate liquidations using the FlashLiquidationHook
 * @dev This would be the entry point for a liquidation bot that monitors for underwater positions
 */
contract LiquidationOrchestrator {
    // The flash liquidation hook contract
    FlashLiquidationHook public flashLiquidationHook;
    
    // Minimum profit required for a liquidation to be executed
    uint256 public minProfitAmount;
    
    // Address that receives profits from liquidations
    address public profitReceiver;
    
    // Array of token pairs to monitor for liquidation opportunities
    struct TokenPair {
        address debtToken;
        address collateralToken;
    }
    
    TokenPair[] public tokenPairs;
    
    // Event emitted when a liquidation is executed
    event LiquidationExecuted(
        address indexed borrower,
        address indexed debtToken,
        address indexed collateralToken,
        uint256 debtAmount
    );
    
    /**
     * @notice Constructor initializes the orchestrator
     * @param _flashLiquidationHook The flash liquidation hook contract
     * @param _minProfitAmount Minimum profit required for a liquidation
     * @param _profitReceiver Address that receives profits
     */
    constructor(
        FlashLiquidationHook _flashLiquidationHook,
        uint256 _minProfitAmount,
        address _profitReceiver
    ) {
        flashLiquidationHook = _flashLiquidationHook;
        minProfitAmount = _minProfitAmount;
        profitReceiver = _profitReceiver;
    }
    
    /**
     * @notice Add a token pair to monitor for liquidation opportunities
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     */
    function addTokenPair(address debtToken, address collateralToken) external {
        tokenPairs.push(TokenPair(debtToken, collateralToken));
    }
    
    /**
     * @notice Set the minimum profit required for a liquidation
     * @param _minProfitAmount New minimum profit amount
     */
    function setMinProfitAmount(uint256 _minProfitAmount) external {
        minProfitAmount = _minProfitAmount;
    }
    
    /**
     * @notice Set the profit receiver address
     * @param _profitReceiver New profit receiver address
     */
    function setProfitReceiver(address _profitReceiver) external {
        profitReceiver = _profitReceiver;
    }
    
    /**
     * @notice Execute a liquidation for a specific borrower
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     * @param borrower The borrower address
     * @param debtAmount The amount of debt to liquidate (0 = max available)
     */
    function executeLiquidation(
        address debtToken,
        address collateralToken,
        address borrower,
        uint256 debtAmount
    ) external {
        // Check if the position is liquidatable
        (bool liquidatable, uint256 maxDebtAmount, uint256 estimatedProfit) = 
            flashLiquidationHook.checkLiquidationProfitability(
                debtToken,
                collateralToken,
                borrower
            );
        
        require(liquidatable, "Position not liquidatable");
        require(estimatedProfit >= minProfitAmount, "Insufficient profit");
        
        // If debtAmount is 0, use the maximum available
        if (debtAmount == 0) {
            debtAmount = maxDebtAmount;
        }
        
        // Execute the flash liquidation
        flashLiquidationHook.flashLiquidate(
            debtToken,
            collateralToken,
            borrower,
            debtAmount,
            minProfitAmount
        );
        
        emit LiquidationExecuted(
            borrower,
            debtToken,
            collateralToken,
            debtAmount
        );
    }
    
    /**
     * @notice Scan all token pairs for liquidation opportunities
     * @param borrowers Array of borrower addresses to check
     * @return borrowersToLiquidate Array of borrowers that can be liquidated
     * @return debtTokens Corresponding debt tokens
     * @return collateralTokens Corresponding collateral tokens
     * @return debtAmounts Corresponding debt amounts to liquidate
     */
    function scanForLiquidations(address[] calldata borrowers) external view returns (
        address[] memory borrowersToLiquidate,
        address[] memory debtTokens,
        address[] memory collateralTokens,
        uint256[] memory debtAmounts
    ) {
        // Count potential liquidations
        uint256 count = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            for (uint256 j = 0; j < tokenPairs.length; j++) {
                (bool liquidatable, uint256 maxDebtAmount, uint256 estimatedProfit) = 
                    flashLiquidationHook.checkLiquidationProfitability(
                        tokenPairs[j].debtToken,
                        tokenPairs[j].collateralToken,
                        borrowers[i]
                    );
                
                if (liquidatable && estimatedProfit >= minProfitAmount) {
                    count++;
                }
            }
        }
        
        // Initialize arrays with the correct size
        borrowersToLiquidate = new address[](count);
        debtTokens = new address[](count);
        collateralTokens = new address[](count);
        debtAmounts = new uint256[](count);
        
        // Fill arrays with liquidation data
        uint256 index = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            for (uint256 j = 0; j < tokenPairs.length; j++) {
                (bool liquidatable, uint256 maxDebtAmount, uint256 estimatedProfit) = 
                    flashLiquidationHook.checkLiquidationProfitability(
                        tokenPairs[j].debtToken,
                        tokenPairs[j].collateralToken,
                        borrowers[i]
                    );
                
                if (liquidatable && estimatedProfit >= minProfitAmount) {
                    borrowersToLiquidate[index] = borrowers[i];
                    debtTokens[index] = tokenPairs[j].debtToken;
                    collateralTokens[index] = tokenPairs[j].collateralToken;
                    debtAmounts[index] = maxDebtAmount;
                    index++;
                }
            }
        }
        
        return (borrowersToLiquidate, debtTokens, collateralTokens, debtAmounts);
    }
}
