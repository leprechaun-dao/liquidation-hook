// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {ILiquidationProtocol} from "./interfaces/ILiquidationProtocol.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title FlashLiquidationHook
 * @notice An improved Uniswap V4 hook that enables flash swap functionality for liquidations
 * @dev This hook implements the afterSwap function to perform flash liquidations with enhanced
 *      error handling, slippage protection, and gas optimization
 */
contract FlashLiquidationHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // Interface to the protocol that has positions that can be liquidated
    ILiquidationProtocol public immutable liquidationProtocol;
    
    // Mapping to track if we're in a liquidation process (prevents reentrancy)
    mapping(PoolId => bool) public isLiquidating;
    
    // Constants for swap price limits
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    
    // Fee tier for swaps (default to 0.3%)
    uint24 public defaultFeeTier = 3000;
    
    // Default tick spacing for 0.3% pools
    int24 public defaultTickSpacing = 60;
    
    // Event emitted when a liquidation is performed
    event LiquidationExecuted(
        address indexed borrower,
        address indexed debtToken,
        address indexed collateralToken,
        uint256 debtAmount,
        uint256 collateralAmount,
        uint256 profit
    );
    
    // Event emitted when a liquidation fails
    event LiquidationFailed(
        address indexed borrower,
        address indexed debtToken,
        address indexed collateralToken,
        uint256 debtAmount,
        string reason
    );
    
    /**
     * @notice Struct to hold liquidation parameters
     */
    struct LiquidationParams {
        address borrower;       // Address of the borrower to be liquidated
        address debtToken;      // Token borrowed (debt token)
        address collateralToken; // Token used as collateral
        uint256 debtAmount;     // Amount of debt to liquidate
        uint256 minProfitAmount; // Minimum profit required
        uint256 minCollateralAmount; // Minimum collateral to receive (slippage protection)
        uint24 feeTier;         // Fee tier to use for the swap
    }
    
    /**
     * @notice Struct to hold liquidation state
     * @dev Used to reduce stack usage and improve gas efficiency
     */
    struct LiquidationState {
        bool success;
        string errorReason;
        uint256 collateralAmount;
        uint256 debtTokenReceived;
        uint256 profit;
    }
    
    /**
     * @notice Constructor initializes the hook with pool manager and liquidation protocol
     * @param _poolManager The Uniswap V4 pool manager
     * @param _liquidationProtocol The protocol that manages positions that can be liquidated
     */
    constructor(
        IPoolManager _poolManager,
        ILiquidationProtocol _liquidationProtocol
    ) BaseHook(_poolManager) {
        liquidationProtocol = _liquidationProtocol;
    }
    
    /**
     * @notice Set the default fee tier and corresponding tick spacing
     * @param _feeTier The new default fee tier
     * @param _tickSpacing The corresponding tick spacing
     */
    function setDefaultPoolConfig(uint24 _feeTier, int24 _tickSpacing) external {
        defaultFeeTier = _feeTier;
        defaultTickSpacing = _tickSpacing;
    }
    
    /**
     * @notice Returns the permissions for this hook
     * @return Hooks.Permissions struct indicating which hooks are implemented
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    /**
     * @notice Helper to decode hook data into liquidation parameters
     * @param data Encoded liquidation parameters
     * @return params LiquidationParams struct with decoded data
     */
    function decodeLiquidationParams(bytes calldata data) internal pure returns (LiquidationParams memory params) {
        if (data.length == 0) {
            return LiquidationParams(
                address(0), 
                address(0), 
                address(0), 
                0, 
                0, 
                0, 
                0
            );
        }
        
        return abi.decode(data, (LiquidationParams));
    }
    
    /**
     * @notice afterSwap hook implementation for flash liquidations
     * @dev Implementation of the BaseHook's _afterSwap function
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // If we're already in a liquidation process, just return
        if (isLiquidating[poolId]) {
            return (IHooks.afterSwap.selector, 0);
        }
        
        // Decode the liquidation parameters
        LiquidationParams memory liquidationParams = decodeLiquidationParams(hookData);
        
        // If no liquidation parameters, just return
        if (liquidationParams.borrower == address(0)) {
            return (IHooks.afterSwap.selector, 0);
        }
        
        // Mark that we're in a liquidation process to prevent reentrancy
        isLiquidating[poolId] = true;
        
        // Determine which token we're receiving (debt token) and how much
        (address debtToken, uint256 debtAmount) = getFlashLoanDetails(key, params, delta);
        
        // Ensure debt token matches the expected one
        if (debtToken != liquidationParams.debtToken) {
            isLiquidating[poolId] = false;
            emit LiquidationFailed(
                liquidationParams.borrower,
                liquidationParams.debtToken,
                liquidationParams.collateralToken,
                debtAmount,
                "Debt token mismatch"
            );
            return (IHooks.afterSwap.selector, 0);
        }
        
        // Initialize liquidation state
        LiquidationState memory state = LiquidationState({
            success: false,
            errorReason: "Unknown error",
            collateralAmount: 0,
            debtTokenReceived: 0,
            profit: 0
        });
        
        // Execute the liquidation
        try this.executeLiquidationFlow(
            sender,
            liquidationParams,
            debtAmount
        ) returns (
            bool _success,
            string memory _errorReason,
            uint256 _collateralAmount,
            uint256 _debtTokenReceived,
            uint256 _profit
        ) {
            state.success = _success;
            state.errorReason = _errorReason;
            state.collateralAmount = _collateralAmount;
            state.debtTokenReceived = _debtTokenReceived;
            state.profit = _profit;
        } catch Error(string memory reason) {
            state.success = false;
            state.errorReason = reason;
        } catch {
            state.success = false;
            state.errorReason = "Liquidation execution failed";
        }
        
        // Reset the liquidation flag
        isLiquidating[poolId] = false;
        
        if (state.success) {
            // Emit liquidation success event
            emit LiquidationExecuted(
                liquidationParams.borrower,
                liquidationParams.debtToken,
                liquidationParams.collateralToken,
                debtAmount,
                state.collateralAmount,
                state.profit
            );
        } else {
            // Emit liquidation failure event
            emit LiquidationFailed(
                liquidationParams.borrower,
                liquidationParams.debtToken,
                liquidationParams.collateralToken,
                debtAmount,
                state.errorReason
            );
            
            // Revert to prevent completion of the flash loan if liquidation fails
            revert(state.errorReason);
        }
        
        // Return the appropriate function selector and a zero delta
        return (IHooks.afterSwap.selector, 0);
    }
    
    /**
     * @notice Extract flash loan details from the swap
     * @param key The pool key
     * @param params The swap parameters
     * @param delta The balance delta
     * @return token The token received in the flash loan
     * @return amount The amount received
     */
    function getFlashLoanDetails(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) internal pure returns (address token, uint256 amount) {
        if (params.zeroForOne) {
            // We're swapping token0 for token1, so token1 is what we receive
            token = Currency.unwrap(key.currency1);
            amount = uint256(int256(-delta.amount1()));
        } else {
            // We're swapping token1 for token0, so token0 is what we receive
            token = Currency.unwrap(key.currency0);
            amount = uint256(int256(-delta.amount0()));
        }
        
        return (token, amount);
    }
    
    /**
     * @notice Execute the liquidation flow
     * @param sender The original sender of the transaction
     * @param params The liquidation parameters
     * @param debtAmount The debt amount to liquidate
     * @return success Whether the liquidation was successful
     * @return errorReason The error reason if unsuccessful
     * @return collateralAmount The amount of collateral seized
     * @return debtTokenReceived The amount of debt tokens received from selling collateral
     * @return profit The profit amount
     */
    function executeLiquidationFlow(
        address sender,
        LiquidationParams memory params,
        uint256 debtAmount
    ) external returns (
        bool success,
        string memory errorReason,
        uint256 collateralAmount,
        uint256 debtTokenReceived,
        uint256 profit
    ) {
        // Only allow this contract to call this function
        require(msg.sender == address(this), "Only self-call allowed");
        
        // Execute the liquidation
        try liquidationProtocol.liquidate(
            params.borrower,
            params.debtToken,
            params.collateralToken,
            debtAmount
        ) returns (uint256 _collateralAmount) {
            collateralAmount = _collateralAmount;
            
            // Check if we received enough collateral
            if (collateralAmount < params.minCollateralAmount) {
                return (
                    false, 
                    "Received collateral below minimum",
                    collateralAmount,
                    0,
                    0
                );
            }
            
            // Swap the collateral for debt token
            (success, errorReason, debtTokenReceived) = swapCollateralForDebt(
                params.collateralToken,
                params.debtToken,
                collateralAmount,
                params.feeTier > 0 ? params.feeTier : defaultFeeTier
            );
            
            if (!success) {
                return (false, errorReason, collateralAmount, debtTokenReceived, 0);
            }
            
            // Ensure we got enough debt tokens back
            if (debtTokenReceived < debtAmount) {
                return (
                    false,
                    "Insufficient tokens to repay debt",
                    collateralAmount,
                    debtTokenReceived,
                    0
                );
            }
            
            // Calculate profit
            profit = debtTokenReceived > debtAmount ? debtTokenReceived - debtAmount : 0;
            
            // Check if profit meets minimum requirement
            if (profit < params.minProfitAmount) {
                return (
                    false,
                    "Profit below minimum requirement",
                    collateralAmount,
                    debtTokenReceived,
                    profit
                );
            }
            
            // Settle the debt token with the pool manager
            try poolManager.sync(Currency.wrap(params.debtToken)) {
                try poolManager.settle() {
                    // Transfer profit to the original sender
                    if (profit > 0) {
                        IERC20(params.debtToken).transfer(sender, profit);
                    }
                    
                    return (true, "", collateralAmount, debtTokenReceived, profit);
                } catch Error(string memory reason) {
                    return (false, string(abi.encodePacked("Failed to settle: ", reason)), collateralAmount, debtTokenReceived, 0);
                } catch {
                    return (false, "Failed to settle debt", collateralAmount, debtTokenReceived, 0);
                }
            } catch Error(string memory reason) {
                return (false, string(abi.encodePacked("Failed to sync: ", reason)), collateralAmount, debtTokenReceived, 0);
            } catch {
                return (false, "Failed to sync debt token", collateralAmount, debtTokenReceived, 0);
            }
        } catch Error(string memory reason) {
            return (false, string(abi.encodePacked("Liquidation failed: ", reason)), 0, 0, 0);
        } catch {
            return (false, "Failed to liquidate position", 0, 0, 0);
        }
    }
    
    /**
     * @notice Swap collateral for debt token
     * @param collateralToken The collateral token
     * @param debtToken The debt token
     * @param collateralAmount The amount of collateral to swap
     * @param feeTier The fee tier to use
     * @return success Whether the swap was successful
     * @return errorReason The error reason if unsuccessful
     * @return debtTokenReceived The amount of debt tokens received
     */
    function swapCollateralForDebt(
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint24 feeTier
    ) internal returns (
        bool success,
        string memory errorReason,
        uint256 debtTokenReceived
    ) {
        // Approve collateral for use by PoolManager
        try IERC20(collateralToken).approve(address(poolManager), collateralAmount) {
            // Get the pool key for swapping collateral to debt token
            PoolKey memory collateralPool = getPoolKey(collateralToken, debtToken, feeTier);
            
            // Sync the collateral token to update balances
            try poolManager.sync(Currency.wrap(collateralToken)) {
                // Determine swap direction
                bool zeroForOne = collateralToken < debtToken;
                
                // Execute swap
                try poolManager.swap(
                    collateralPool,
                    SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: int256(collateralAmount),
                        sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
                    }),
                    ""
                ) returns (BalanceDelta swapDelta) {
                    // Calculate received debt tokens
                    if (zeroForOne) {
                        debtTokenReceived = uint256(int256(-swapDelta.amount1()));
                    } else {
                        debtTokenReceived = uint256(int256(-swapDelta.amount0()));
                    }
                    
                    return (true, "", debtTokenReceived);
                } catch Error(string memory reason) {
                    return (false, string(abi.encodePacked("Collateral swap failed: ", reason)), 0);
                } catch {
                    return (false, "Collateral swap failed", 0);
                }
            } catch Error(string memory reason) {
                return (false, string(abi.encodePacked("Collateral sync failed: ", reason)), 0);
            } catch {
                return (false, "Failed to sync collateral token", 0);
            }
        } catch Error(string memory reason) {
            return (false, string(abi.encodePacked("Collateral approval failed: ", reason)), 0);
        } catch {
            return (false, "Failed to approve collateral token", 0);
        }
    }
    
    /**
     * @notice Helper to get a pool key for two tokens
     * @param tokenA First token
     * @param tokenB Second token
     * @param feeTier Fee tier to use
     * @return PoolKey for the token pair
     */
    function getPoolKey(
        address tokenA, 
        address tokenB, 
        uint24 feeTier
    ) internal view returns (PoolKey memory) {
        // Sort tokens to get currency0 and currency1
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
            
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: feeTier,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(this))
        });
    }
    
    /**
     * @notice Initiates a flash liquidation
     * @param debtToken Token to borrow for liquidation
     * @param collateralToken Token used as collateral
     * @param borrower Address of the borrower to liquidate
     * @param debtAmount Amount of debt to liquidate (0 for max available)
     * @param minProfitAmount Minimum profit required
     * @param minCollateralAmount Minimum collateral to receive (slippage protection)
     * @param feeTier Fee tier to use (0 for default)
     */
    function flashLiquidate(
        address debtToken,
        address collateralToken,
        address borrower,
        uint256 debtAmount,
        uint256 minProfitAmount,
        uint256 minCollateralAmount,
        uint24 feeTier
    ) external {
        // Check if the position is liquidatable first
        (bool liquidatable, uint256 maxDebtAmount) = liquidationProtocol.isLiquidatable(
            borrower,
            debtToken,
            collateralToken
        );
        
        require(liquidatable, "Position not liquidatable");
        
        // If debtAmount is 0, use the maximum liquidatable amount
        if (debtAmount == 0 || debtAmount > maxDebtAmount) {
            debtAmount = maxDebtAmount;
        }
        
        // Use default fee tier if none specified
        uint24 actualFeeTier = feeTier > 0 ? feeTier : defaultFeeTier;
        
        // Create the pool key
        PoolKey memory key = getPoolKey(debtToken, collateralToken, actualFeeTier);
        
        // Encode the liquidation parameters
        bytes memory hookData = abi.encode(
            LiquidationParams({
                borrower: borrower,
                debtToken: debtToken,
                collateralToken: collateralToken,
                debtAmount: debtAmount,
                minProfitAmount: minProfitAmount,
                minCollateralAmount: minCollateralAmount,
                feeTier: actualFeeTier
            })
        );
        
        // Figure out the swap direction
        bool zeroForOne = debtToken < collateralToken;
        
        // Execute the swap to get the flash loan
        // We're specifying a negative amount to indicate we want to receive exactly this much
        poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(debtAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
            }),
            hookData
        );
    }
    
    /**
     * @notice Check if a position is profitable to liquidate
     * @param debtToken Token to borrow for liquidation
     * @param collateralToken Token used as collateral
     * @param borrower Address of the borrower to liquidate
     * @return liquidatable Whether the position can be liquidated
     * @return maxDebtAmount Maximum amount of debt that can be liquidated
     * @return estimatedProfit Estimated profit from liquidation
     * @return estimatedCollateral Estimated collateral to receive
     */
    function checkLiquidationProfitability(
        address debtToken,
        address collateralToken,
        address borrower
    ) external view returns (
        bool liquidatable,
        uint256 maxDebtAmount,
        uint256 estimatedProfit,
        uint256 estimatedCollateral
    ) {
        // Check if position is liquidatable
        (liquidatable, maxDebtAmount) = liquidationProtocol.isLiquidatable(
            borrower,
            debtToken,
            collateralToken
        );
        
        if (!liquidatable || maxDebtAmount == 0) {
            return (false, 0, 0, 0);
        }
        
        // Estimate the collateral that would be received
        estimatedCollateral = liquidationProtocol.simulateLiquidation(
            borrower,
            debtToken,
            collateralToken,
            maxDebtAmount
        );
        
        // For profit estimation, we use a simplified approach since we can't 
        // directly simulate the swap in Uniswap V4 without making state changes
        // In a real implementation, you might want to use an external price oracle
        // or more sophisticated method to estimate the swap outcome
        
        // Simple estimation: assume a 2% slippage on collateral value
        uint256 estimatedDebtTokens = maxDebtAmount * 102 / 100;
        
        // Estimate profit as the difference between debt tokens received and debt tokens paid
        if (estimatedDebtTokens > maxDebtAmount) {
            estimatedProfit = estimatedDebtTokens - maxDebtAmount;
        }
        
        return (liquidatable, maxDebtAmount, estimatedProfit, estimatedCollateral);
    }
    
    /**
     * @notice Simulate a liquidation to estimate collateral received and potential profit
     * @param borrower Address of the borrower to liquidate
     * @param debtToken Token to borrow for liquidation
     * @param collateralToken Token used as collateral
     * @param debtAmount Amount of debt to liquidate
     * @return estimatedCollateral Estimated amount of collateral to receive
     * @return estimatedProfit Estimated profit from the liquidation
     */
    function simulateLiquidation(
        address borrower,
        address debtToken,
        address collateralToken,
        uint256 debtAmount
    ) public view returns (uint256 estimatedCollateral, uint256 estimatedProfit) {
        // Get the estimated collateral to be received from the liquidation
        estimatedCollateral = liquidationProtocol.simulateLiquidation(
            borrower,
            debtToken,
            collateralToken,
            debtAmount
        );
        
        if (estimatedCollateral == 0) {
            return (0, 0);
        }
        
        // Simplified profit estimation without using getQuote
        // In a real implementation, you would use a price oracle or other mechanism
        // to get a more accurate estimate of the swap outcome
        
        // Assume 2% profit (this is a very simplified approach)
        estimatedProfit = debtAmount * 2 / 100;
        
        return (estimatedCollateral, estimatedProfit);
    }
}
