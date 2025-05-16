// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILiquidationProtocol} from "../interfaces/ILiquidationProtocol.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IMockOracle} from "./oracle/IMockOracle.sol";

/**
 * @title MockLiquidationProtocol
 * @notice An improved mock implementation of the ILiquidationProtocol
 * @dev This implementation more closely matches the Leprechaun Protocol's liquidation mechanism
 */
contract MockLiquidationProtocol is ILiquidationProtocol {
    // Mock oracle for price data
    IMockOracle public oracle;
    
    // Protocol fee (basis points)
    uint256 public protocolFee = 50; // 0.5%
    
    // Fee collector address
    address public feeCollector;
    
    // Default minimum collateral ratio (scaled by 10000)
    uint256 public defaultMinCollateralRatio = 15000; // 150%
    
    // Asset-specific minimum collateral ratios
    mapping(address => uint256) public assetMinCollateralRatio;
    
    // Asset-specific auction discounts
    mapping(address => uint256) public assetAuctionDiscount;
    
    // Collateral risk multipliers
    mapping(address => uint256) public collateralRiskMultiplier;
    
    // User positions
    struct Position {
        address syntheticAsset;
        address collateralAsset;
        uint256 collateralAmount;
        uint256 debtAmount;
        bool isActive;
    }
    
    // Mapping of user to position ID to position
    mapping(address => mapping(uint256 => Position)) public userPositions;
    
    // Mapping of user to position count
    mapping(address => uint256) public userPositionCount;
    
    // Events
    event PositionCreated(
        address indexed user,
        uint256 indexed positionId,
        address syntheticAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    );
    
    event PositionLiquidated(
        address indexed user,
        uint256 indexed positionId,
        address liquidator,
        address syntheticAsset,
        address collateralAsset,
        uint256 debtAmount,
        uint256 collateralSeized
    );
    
    /**
     * @notice Constructor
     * @param _oracle The mock oracle address
     * @param _feeCollector The fee collector address
     */
    constructor(address _oracle, address _feeCollector) {
        oracle = IMockOracle(_oracle);
        feeCollector = _feeCollector;
    }
    
    /**
     * @notice Set the protocol fee
     * @param _protocolFee The new protocol fee (basis points)
     */
    function setProtocolFee(uint256 _protocolFee) external {
        protocolFee = _protocolFee;
    }
    
    /**
     * @notice Set the fee collector
     * @param _feeCollector The new fee collector address
     */
    function setFeeCollector(address _feeCollector) external {
        feeCollector = _feeCollector;
    }
    
    /**
     * @notice Set the default minimum collateral ratio
     * @param _ratio The new default minimum collateral ratio (scaled by 10000)
     */
    function setDefaultMinCollateralRatio(uint256 _ratio) external {
        defaultMinCollateralRatio = _ratio;
    }
    
    /**
     * @notice Set an asset-specific minimum collateral ratio
     * @param syntheticAsset The synthetic asset address
     * @param ratio The minimum collateral ratio (scaled by 10000)
     */
    function setAssetMinCollateralRatio(address syntheticAsset, uint256 ratio) external {
        assetMinCollateralRatio[syntheticAsset] = ratio;
    }
    
    /**
     * @notice Set an asset-specific auction discount
     * @param syntheticAsset The synthetic asset address
     * @param discount The auction discount (basis points)
     */
    function setAssetAuctionDiscount(address syntheticAsset, uint256 discount) external {
        assetAuctionDiscount[syntheticAsset] = discount;
    }
    
    /**
     * @notice Set a collateral risk multiplier
     * @param collateralAsset The collateral asset address
     * @param multiplier The risk multiplier (scaled by 10000)
     */
    function setCollateralRiskMultiplier(address collateralAsset, uint256 multiplier) external {
        collateralRiskMultiplier[collateralAsset] = multiplier;
    }
    
    /**
     * @notice Create a new position
     * @param syntheticAsset The synthetic asset address
     * @param collateralAsset The collateral asset address
     * @param collateralAmount The collateral amount
     * @param debtAmount The debt amount
     * @return positionId The ID of the created position
     */
    function createPosition(
        address syntheticAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external returns (uint256) {
        require(collateralAmount > 0, "Collateral amount must be greater than 0");
        require(debtAmount > 0, "Debt amount must be greater than 0");
        
        // Calculate the minimum required collateral
        uint256 requiredCollateral = calculateRequiredCollateral(
            syntheticAsset,
            collateralAsset,
            debtAmount
        );
        
        require(collateralAmount >= requiredCollateral, "Insufficient collateral");
        
        // Create new position
        uint256 positionId = userPositionCount[msg.sender]++;
        Position storage position = userPositions[msg.sender][positionId];
        
        position.syntheticAsset = syntheticAsset;
        position.collateralAsset = collateralAsset;
        position.collateralAmount = collateralAmount;
        position.debtAmount = debtAmount;
        position.isActive = true;
        
        // Transfer collateral from user
        IERC20(collateralAsset).transferFrom(msg.sender, address(this), collateralAmount);
        
        // Mint synthetic asset to user
        // In a real implementation, this would call a mint function
        // Here we just simulate it by transferring tokens
        IERC20(syntheticAsset).transfer(msg.sender, debtAmount);
        
        emit PositionCreated(
            msg.sender,
            positionId,
            syntheticAsset,
            collateralAsset,
            collateralAmount,
            debtAmount
        );
        
        return positionId;
    }
    
    /**
     * @notice Calculate required collateral for a given debt amount
     * @param syntheticAsset The synthetic asset address
     * @param collateralAsset The collateral asset address
     * @param debtAmount The debt amount
     * @return requiredCollateral The required collateral amount
     */
    function calculateRequiredCollateral(
        address syntheticAsset,
        address collateralAsset,
        uint256 debtAmount
    ) public view returns (uint256) {
        if (debtAmount == 0) return 0;
        
        // Get effective collateral ratio
        uint256 effectiveRatio = getEffectiveCollateralRatio(syntheticAsset, collateralAsset);
        
        // Calculate synthetic asset USD value
        uint256 syntheticUsdValue = oracle.getUsdValue(syntheticAsset, debtAmount);
        
        // Calculate required USD value based on collateralization ratio
        uint256 requiredUsdValue = (syntheticUsdValue * effectiveRatio) / 10000;
        
        // Convert USD value to collateral tokens
        return oracle.getTokenAmount(collateralAsset, requiredUsdValue);
    }
    
    /**
     * @notice Calculate a position's collateral ratio
     * @param user The user address
     * @param positionId The position ID
     * @return collateralRatio The collateral ratio (scaled by 10000)
     */
    function calculateCollateralRatio(address user, uint256 positionId) public view returns (uint256) {
        Position storage position = userPositions[user][positionId];
        
        if (position.debtAmount == 0) {
            return type(uint256).max; // Infinite ratio if no debt
        }
        
        if (position.collateralAmount == 0) {
            return 0; // Zero ratio if no collateral
        }
        
        // Calculate the USD value of the collateral
        uint256 collateralUsdValue = oracle.getUsdValue(
            position.collateralAsset, 
            position.collateralAmount
        );
        
        // Calculate the USD value of the debt
        uint256 debtUsdValue = oracle.getUsdValue(
            position.syntheticAsset,
            position.debtAmount
        );
        
        // Calculate collateral ratio: (collateralUsdValue * 10000) / debtUsdValue
        return (collateralUsdValue * 10000) / debtUsdValue;
    }
    
    /**
     * @notice Get the effective collateral ratio for a synthetic asset and collateral pair
     * @param syntheticAsset The synthetic asset address
     * @param collateralAsset The collateral asset address
     * @return effectiveRatio The effective collateral ratio (scaled by 10000)
     */
    function getEffectiveCollateralRatio(address syntheticAsset, address collateralAsset) 
        public view returns (uint256) 
    {
        uint256 assetRatio = assetMinCollateralRatio[syntheticAsset];
        if (assetRatio == 0) assetRatio = defaultMinCollateralRatio;
        
        uint256 riskMultiplier = collateralRiskMultiplier[collateralAsset];
        if (riskMultiplier == 0) riskMultiplier = 10000; // Default 1.0
        
        return (assetRatio * riskMultiplier) / 10000;
    }
    
    /**
     * @notice Check if a position is liquidatable
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
        // Check all positions for this borrower
        for (uint256 i = 0; i < userPositionCount[borrower]; i++) {
            Position storage position = userPositions[borrower][i];
            
            if (position.syntheticAsset == debtToken && 
                position.collateralAsset == collateralToken &&
                position.isActive) {
                
                uint256 currentRatio = calculateCollateralRatio(borrower, i);
                uint256 requiredRatio = getEffectiveCollateralRatio(debtToken, collateralToken);
                
                if (currentRatio < requiredRatio) {
                    return (true, position.debtAmount);
                }
            }
        }
        
        return (false, 0);
    }
    
    /**
     * @notice Liquidate a borrower's position
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
        // Find the liquidatable position
        for (uint256 i = 0; i < userPositionCount[borrower]; i++) {
            Position storage position = userPositions[borrower][i];
            
            if (position.syntheticAsset == debtToken && 
                position.collateralAsset == collateralToken &&
                position.isActive) {
                
                // Check if liquidatable
                uint256 currentRatio = calculateCollateralRatio(borrower, i);
                uint256 requiredRatio = getEffectiveCollateralRatio(debtToken, collateralToken);
                
                require(currentRatio < requiredRatio, "Position not liquidatable");
                require(debtAmount <= position.debtAmount, "Liquidation amount too high");
                
                // In Leprechaun, we liquidate the entire position
                // Keeping for consistency with their approach
                debtAmount = position.debtAmount;
                
                // Get auction discount for this synthetic asset
                uint256 auctionDiscount = assetAuctionDiscount[debtToken];
                if (auctionDiscount == 0) auctionDiscount = 1000; // Default 10%
                
                // Calculate collateral to seize with discount
                uint256 debtUsdValue = oracle.getUsdValue(debtToken, debtAmount);
                uint256 discountedDebtValue = (debtUsdValue * (10000 + auctionDiscount)) / 10000;
                uint256 collateralToSeize = oracle.getTokenAmount(
                    collateralToken, 
                    discountedDebtValue
                );
                
                // Cap to available collateral
                if (collateralToSeize > position.collateralAmount) {
                    collateralToSeize = position.collateralAmount;
                }
                
                // Calculate remaining collateral
                uint256 remainingCollateral = position.collateralAmount - collateralToSeize;
                
                // Calculate fee on remaining collateral
                uint256 fee = 0;
                if (remainingCollateral > 0) {
                    fee = (remainingCollateral * protocolFee) / 10000;
                }
                
                // Transfer collateral to liquidator
                IERC20(collateralToken).transfer(msg.sender, collateralToSeize);
                
                // Transfer fee to fee collector
                if (fee > 0) {
                    IERC20(collateralToken).transfer(feeCollector, fee);
                }
                
                // Transfer remaining collateral to position owner
                if (remainingCollateral > fee) {
                    IERC20(collateralToken).transfer(borrower, remainingCollateral - fee);
                }
                
                // Transfer debt tokens from liquidator to this contract
                IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
                
                // Close position
                position.collateralAmount = 0;
                position.debtAmount = 0;
                position.isActive = false;
                
                emit PositionLiquidated(
                    borrower,
                    i,
                    msg.sender,
                    debtToken,
                    collateralToken,
                    debtAmount,
                    collateralToSeize
                );
                
                return collateralToSeize;
            }
        }
        
        revert("No liquidatable position found");
    }
    
    /**
     * @notice Simulate a liquidation to determine profitability
     * @param borrower Address of the borrower
     * @param debtToken Token that was borrowed
     * @param collateralToken Token used as collateral
     * @param debtAmount Amount of debt to liquidate
     * @return collateralToSeize Amount of collateral that would be seized
     */
    function simulateLiquidation(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 debtAmount
    ) external view override returns (uint256) {
        // Find the liquidatable position
        for (uint256 i = 0; i < userPositionCount[borrower]; i++) {
            Position storage position = userPositions[borrower][i];
            
            if (position.syntheticAsset == debtToken && 
                position.collateralAsset == collateralToken &&
                position.isActive) {
                
                // Check if liquidatable
                uint256 currentRatio = calculateCollateralRatio(borrower, i);
                uint256 requiredRatio = getEffectiveCollateralRatio(debtToken, collateralToken);
                
                if (currentRatio < requiredRatio) {
                    // Force full liquidation for consistency with Leprechaun
                    if (debtAmount > position.debtAmount || debtAmount == 0) {
                        debtAmount = position.debtAmount;
                    }
                    
                    // Get auction discount for this synthetic asset
                    uint256 auctionDiscount = assetAuctionDiscount[debtToken];
                    if (auctionDiscount == 0) auctionDiscount = 1000; // Default 10%
                    
                    // Calculate collateral to seize with discount
                    uint256 debtUsdValue = oracle.getUsdValue(debtToken, debtAmount);
                    uint256 discountedDebtValue = (debtUsdValue * (10000 + auctionDiscount)) / 10000;
                    uint256 collateralToSeize = oracle.getTokenAmount(
                        collateralToken, 
                        discountedDebtValue
                    );
                    
                    // Cap to available collateral
                    if (collateralToSeize > position.collateralAmount) {
                        collateralToSeize = position.collateralAmount;
                    }
                    
                    return collateralToSeize;
                }
            }
        }
        
        return 0;
    }
    
    /**
     * @notice Helper function to get profit estimate in USD terms
     * @dev This is a helper for external contracts, not part of the interface
     * @param borrower Address of the borrower
     * @param debtToken Token that was borrowed
     * @param collateralToken Token used as collateral
     * @param debtAmount Amount of debt to liquidate
     * @return collateralToSeize Amount of collateral that would be seized
     * @return profitUsd Estimated profit in USD terms
     */
    function getSimulationDetails(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 debtAmount
    ) external view returns (uint256 collateralToSeize, uint256 profitUsd) {
        collateralToSeize = this.simulateLiquidation(borrower, debtToken, collateralToken, debtAmount);
        
        if (collateralToSeize > 0) {
            uint256 debtUsdValue = oracle.getUsdValue(debtToken, debtAmount);
            uint256 collateralUsdValue = oracle.getUsdValue(collateralToken, collateralToSeize);
            profitUsd = collateralUsdValue > debtUsdValue ? collateralUsdValue - debtUsdValue : 0;
        }
        
        return (collateralToSeize, profitUsd);
    }
    
    /**
     * @notice Helper function to manually add a position for testing
     * @param borrower The borrower address
     * @param syntheticAsset The synthetic asset address
     * @param collateralAsset The collateral asset address
     * @param collateralAmount The collateral amount
     * @param debtAmount The debt amount
     * @return positionId The position ID
     */
    function addTestPosition(
        address borrower,
        address syntheticAsset,
        address collateralAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    ) external returns (uint256) {
        uint256 positionId = userPositionCount[borrower]++;
        Position storage position = userPositions[borrower][positionId];
        
        position.syntheticAsset = syntheticAsset;
        position.collateralAsset = collateralAsset;
        position.collateralAmount = collateralAmount;
        position.debtAmount = debtAmount;
        position.isActive = true;
        
        return positionId;
    }
}
