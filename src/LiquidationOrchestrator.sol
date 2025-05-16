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
    FlashLiquidationHook public immutable flashLiquidationHook;
    
    // Minimum profit required for a liquidation to be executed
    uint256 public minProfitAmount;
    
    // Default slippage tolerance (in basis points, e.g., 100 = 1%)
    uint256 public slippageTolerance = 100;
    
    // Address that receives profits from liquidations
    address public profitReceiver;
    
    // Address allowed to execute emergency liquidations (bypassing profit checks)
    address public emergencyLiquidator;
    
    // Array of token pairs to monitor for liquidation opportunities
    struct TokenPair {
        address debtToken;
        address collateralToken;
        uint24 feeTier; // 0 = use default
    }
    
    TokenPair[] public tokenPairs;
    
    // Event emitted when a liquidation is executed
    event LiquidationExecuted(
        address indexed borrower,
        address indexed debtToken,
        address indexed collateralToken,
        uint256 debtAmount,
        uint256 collateralReceived,
        uint256 profit
    );
    
    // Event emitted when a token pair is added
    event TokenPairAdded(
        address indexed debtToken,
        address indexed collateralToken,
        uint24 feeTier
    );
    
    // Event emitted when parameters are updated
    event ParametersUpdated(
        uint256 minProfitAmount,
        uint256 slippageTolerance,
        address profitReceiver,
        address emergencyLiquidator
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
        emergencyLiquidator = msg.sender;
    }
    
    /**
     * @notice Add a token pair to monitor for liquidation opportunities
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     * @param feeTier The fee tier to use (0 = use default)
     */
    function addTokenPair(
        address debtToken,
        address collateralToken,
        uint24 feeTier
    ) external {
        require(msg.sender == profitReceiver || msg.sender == emergencyLiquidator, "Not authorized");
        tokenPairs.push(TokenPair(debtToken, collateralToken, feeTier));
        emit TokenPairAdded(debtToken, collateralToken, feeTier);
    }
    
    /**
     * @notice Update the orchestrator parameters
     * @param _minProfitAmount New minimum profit amount
     * @param _slippageTolerance New slippage tolerance (basis points)
     * @param _profitReceiver New profit receiver address
     * @param _emergencyLiquidator New emergency liquidator address
     */
    function updateParameters(
        uint256 _minProfitAmount,
        uint256 _slippageTolerance,
        address _profitReceiver,
        address _emergencyLiquidator
    ) external {
        require(msg.sender == emergencyLiquidator, "Not authorized");
        minProfitAmount = _minProfitAmount;
        slippageTolerance = _slippageTolerance;
        profitReceiver = _profitReceiver;
        emergencyLiquidator = _emergencyLiquidator;
        
        emit ParametersUpdated(
            _minProfitAmount,
            _slippageTolerance,
            _profitReceiver,
            _emergencyLiquidator
        );
    }
    
    /**
     * @notice Scan all token pairs for liquidation opportunities
     * @param borrowers Array of borrower addresses to check
     * @return borrowersToLiquidate Array of borrowers that can be liquidated
     * @return debtTokens Corresponding debt tokens
     * @return collateralTokens Corresponding collateral tokens
     * @return debtAmounts Corresponding debt amounts to liquidate
     * @return profits Estimated profits from liquidations
     * @return feeTiers Fee tiers to use for swaps
     */
    function scanForLiquidations(address[] calldata borrowers) external view returns (
        address[] memory borrowersToLiquidate,
        address[] memory debtTokens,
        address[] memory collateralTokens,
        uint256[] memory debtAmounts,
        uint256[] memory profits,
        uint24[] memory feeTiers
    ) {
        // Count potential liquidations
        uint256 count = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            for (uint256 j = 0; j < tokenPairs.length; j++) {
                (
                    bool liquidatable,
                    uint256 maxDebtAmount,
                    uint256 estimatedProfit,
                    uint256 estimatedCollateral
                ) = flashLiquidationHook.checkLiquidationProfitability(
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
        profits = new uint256[](count);
        feeTiers = new uint24[](count);
        
        // Fill arrays with liquidation data
        uint256 index = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            for (uint256 j = 0; j < tokenPairs.length; j++) {
                (
                    bool liquidatable,
                    uint256 maxDebtAmount,
                    uint256 estimatedProfit,
                    uint256 estimatedCollateral
                ) = flashLiquidationHook.checkLiquidationProfitability(
                    tokenPairs[j].debtToken,
                    tokenPairs[j].collateralToken,
                    borrowers[i]
                );
                
                if (liquidatable && estimatedProfit >= minProfitAmount) {
                    borrowersToLiquidate[index] = borrowers[i];
                    debtTokens[index] = tokenPairs[j].debtToken;
                    collateralTokens[index] = tokenPairs[j].collateralToken;
                    debtAmounts[index] = maxDebtAmount;
                    profits[index] = estimatedProfit;
                    feeTiers[index] = tokenPairs[j].feeTier;
                    index++;
                }
            }
        }
        
        return (borrowersToLiquidate, debtTokens, collateralTokens, debtAmounts, profits, feeTiers);
    }
    
    /**
     * @notice Execute a liquidation for a specific borrower
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     * @param borrower The borrower address
     * @param debtAmount The amount of debt to liquidate (0 = max available)
     * @param feeTier The fee tier to use (0 = use default)
     * @param isEmergency Whether this is an emergency liquidation (bypasses profit checks)
     */
    function executeLiquidation(
        address debtToken,
        address collateralToken,
        address borrower,
        uint256 debtAmount,
        uint24 feeTier,
        bool isEmergency
    ) public {
        // Emergency liquidations can only be executed by the emergency liquidator
        if (isEmergency) {
            require(msg.sender == emergencyLiquidator, "Not emergency liquidator");
        }
        
        // Check if the position is liquidatable
        (
            bool liquidatable,
            uint256 maxDebtAmount,
            uint256 estimatedProfit,
            uint256 estimatedCollateral
        ) = flashLiquidationHook.checkLiquidationProfitability(
            debtToken,
            collateralToken,
            borrower
        );
        
        require(liquidatable, "Position not liquidatable");
        
        // Skip profit check for emergency liquidations
        if (!isEmergency) {
            require(estimatedProfit >= minProfitAmount, "Insufficient profit");
        }
        
        // If debtAmount is 0, use the maximum available
        if (debtAmount == 0) {
            debtAmount = maxDebtAmount;
        }
        
        // Calculate minimum collateral amount based on estimated collateral and slippage tolerance
        uint256 minCollateralAmount = estimatedCollateral;
        if (slippageTolerance > 0 && estimatedCollateral > 0) {
            minCollateralAmount = (estimatedCollateral * (10000 - slippageTolerance)) / 10000;
        }
        
        // Execute the flash liquidation
        flashLiquidationHook.flashLiquidate(
            debtToken,
            collateralToken,
            borrower,
            debtAmount,
            isEmergency ? 0 : minProfitAmount, // Skip profit check for emergency liquidations
            minCollateralAmount,
            feeTier
        );
        
        emit LiquidationExecuted(
            borrower,
            debtToken,
            collateralToken,
            debtAmount,
            estimatedCollateral,
            estimatedProfit
        );
    }
    
    /**
     * @notice Execute multiple liquidations in a single transaction
     * @param borrowers Array of borrower addresses
     * @param debtTokens Array of debt tokens
     * @param collateralTokens Array of collateral tokens
     * @param debtAmounts Array of debt amounts (0 = max)
     * @param feeTiers Array of fee tiers (0 = default)
     */
    function batchExecuteLiquidations(
        address[] calldata borrowers,
        address[] calldata debtTokens,
        address[] calldata collateralTokens,
        uint256[] calldata debtAmounts,
        uint24[] calldata feeTiers
    ) external {
        require(
            borrowers.length == debtTokens.length &&
            borrowers.length == collateralTokens.length &&
            borrowers.length == debtAmounts.length &&
            borrowers.length == feeTiers.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < borrowers.length; i++) {
            // Check if the position is liquidatable and profitable
            (
                bool liquidatable,
                uint256 maxDebtAmount,
                uint256 estimatedProfit,
                uint256 estimatedCollateral
            ) = flashLiquidationHook.checkLiquidationProfitability(
                debtTokens[i],
                collateralTokens[i],
                borrowers[i]
            );
            
            // Skip if not liquidatable or not profitable enough
            if (!liquidatable || estimatedProfit < minProfitAmount) continue;
            
            // Set debt amount to max if 0
            uint256 debtAmount = debtAmounts[i] == 0 ? maxDebtAmount : debtAmounts[i];
            
            // Calculate minimum collateral with slippage tolerance
            uint256 minCollateralAmount = estimatedCollateral;
            if (slippageTolerance > 0 && estimatedCollateral > 0) {
                minCollateralAmount = (estimatedCollateral * (10000 - slippageTolerance)) / 10000;
            }
            
            try flashLiquidationHook.flashLiquidate(
                debtTokens[i],
                collateralTokens[i],
                borrowers[i],
                debtAmount,
                minProfitAmount,
                minCollateralAmount,
                feeTiers[i]
            ) {
                emit LiquidationExecuted(
                    borrowers[i],
                    debtTokens[i],
                    collateralTokens[i],
                    debtAmount,
                    estimatedCollateral,
                    estimatedProfit
                );
            } catch {
                // Continue to next liquidation if one fails
                continue;
            }
        }
    }
    
    /**
     * @notice Execute an emergency liquidation with special permissions
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     * @param borrower The borrower address
     * @param debtAmount The debt amount (0 = max)
     * @param feeTier The fee tier (0 = default)
     */
    function emergencyLiquidate(
        address debtToken,
        address collateralToken,
        address borrower,
        uint256 debtAmount,
        uint24 feeTier
    ) external {
        require(msg.sender == emergencyLiquidator, "Not emergency liquidator");
        
        // Execute without profit checks
        executeLiquidation(
            debtToken,
            collateralToken,
            borrower,
            debtAmount,
            feeTier,
            true
        );
    }
}
