// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILiquidationProtocol} from "../interfaces/ILiquidationProtocol.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/**
 * @title MockLiquidationProtocol
 * @notice A mock implementation of the ILiquidationProtocol for testing and demonstration
 */
contract MockLiquidationProtocol is ILiquidationProtocol {
    // Liquidation bonus (1.1 = 10% bonus)
    uint256 public liquidationBonus = 1.1e18;
    
    // Mapping to track collateral of users
    mapping(address => mapping(address => uint256)) public userCollateral;
    
    // Mapping to track debt of users
    mapping(address => mapping(address => uint256)) public userDebt;
    
    // Mapping to track if a position is flagged as underwater
    mapping(address => mapping(address => mapping(address => bool))) public isUnderwater;
    
    /**
     * @notice Set up a borrower position for testing
     * @param borrower The borrower address
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     * @param debtAmount The debt amount
     * @param collateralAmount The collateral amount
     * @param underwater Whether the position should be marked as underwater
     */
    function setupBorrowerPosition(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 debtAmount,
        uint256 collateralAmount,
        bool underwater
    ) external {
        userDebt[borrower][debtToken] = debtAmount;
        userCollateral[borrower][collateralToken] = collateralAmount;
        isUnderwater[borrower][debtToken][collateralToken] = underwater;
    }
    
    /**
     * @notice Deposit collateral as a borrower
     * @param collateralToken The collateral token
     * @param amount The amount to deposit
     */
    function depositCollateral(address collateralToken, uint256 amount) external {
        IERC20(collateralToken).transferFrom(msg.sender, address(this), amount);
        userCollateral[msg.sender][collateralToken] += amount;
    }
    
    /**
     * @notice Borrow tokens
     * @param debtToken The token to borrow
     * @param amount The amount to borrow
     */
    function borrow(address debtToken, uint256 amount) external {
        userDebt[msg.sender][debtToken] += amount;
        IERC20(debtToken).transfer(msg.sender, amount);
    }

    /**
     * @notice Flag a position as underwater (for testing)
     * @param borrower The borrower address
     * @param debtToken The debt token
     * @param collateralToken The collateral token
     * @param underwater Whether the position is underwater
     */
    function setPositionUnderwater(
        address borrower,
        address debtToken,
        address collateralToken,
        bool underwater
    ) external {
        isUnderwater[borrower][debtToken][collateralToken] = underwater;
    }
    
    /**
     * @notice Set the liquidation bonus
     * @param newBonus The new liquidation bonus (1e18 scale, e.g., 1.1e18 for 10% bonus)
     */
    function setLiquidationBonus(uint256 newBonus) external {
        liquidationBonus = newBonus;
    }
    
    /**
     * @notice Checks if a position is liquidatable
     * @param borrower Address of the borrower
     * @param debtToken Token that was borrowed
     * @param collateralToken Token used as collateral
     * @return liquidatable Whether the position can be liquidated
     * @return maxDebtAmount Maximum amount of debt that can be liquidated
     */
    function isLiquidatable(
        address borrower,
        address debtToken,
        address collateralToken
    ) external view override returns (bool liquidatable, uint256 maxDebtAmount) {
        liquidatable = isUnderwater[borrower][debtToken][collateralToken];
        
        if (liquidatable) {
            // In a real implementation, this would typically be a percentage of the total debt
            // For this mock, we'll allow liquidation of the full debt amount
            maxDebtAmount = userDebt[borrower][debtToken];
        } else {
            maxDebtAmount = 0;
        }
        
        return (liquidatable, maxDebtAmount);
    }
    
    /**
     * @notice Liquidates a borrower's position
     * @param borrower Address of the borrower
     * @param debtToken Token that was borrowed
     * @param collateralToken Token used as collateral
     * @param debtAmount Amount of debt to liquidate
     * @return Amount of collateral seized
     */
    function liquidate(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 debtAmount
    ) external override returns (uint256) {
        (bool liquidatable, uint256 maxDebtAmount) = this.isLiquidatable(
            borrower, 
            debtToken, 
            collateralToken
        );
        
        require(liquidatable, "Position not liquidatable");
        require(debtAmount <= maxDebtAmount, "Liquidation amount too high");
        
        // Calculate collateral to seize (with bonus)
        uint256 collateralToSeize = (debtAmount * liquidationBonus) / 1e18;
        
        // Ensure there's enough collateral
        require(
            collateralToSeize <= userCollateral[borrower][collateralToken],
            "Insufficient collateral"
        );
        
        // Update borrower's debt and collateral
        userDebt[borrower][debtToken] -= debtAmount;
        userCollateral[borrower][collateralToken] -= collateralToSeize;
        
        // If debt is fully cleared, mark position as no longer underwater
        if (userDebt[borrower][debtToken] == 0) {
            isUnderwater[borrower][debtToken][collateralToken] = false;
        }
        
        // Transfer the collateral to the liquidator
        IERC20(collateralToken).transfer(msg.sender, collateralToSeize);
        
        // Transfer the debt tokens from the liquidator to this contract
        IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
        
        return collateralToSeize;
    }
}
