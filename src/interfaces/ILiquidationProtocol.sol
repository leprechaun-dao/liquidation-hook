// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILiquidationProtocol
 * @notice Interface for interacting with a lending protocol to perform liquidations
 */
interface ILiquidationProtocol {
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
    ) external returns (uint256);
    
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
    ) external view returns (bool liquidatable, uint256 maxDebtAmount);
}
