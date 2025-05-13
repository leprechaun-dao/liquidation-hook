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
// Import our local version of SwapParams
import {SwapParams} from "./types/PoolOperation.sol";

/**
 * @title FlashLiquidationHook
 * @notice A Uniswap V4 hook that enables flash swap functionality for liquidations
 * @dev This hook implements the afterSwap function to perform flash liquidations
 */
contract FlashLiquidationHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // Interface to the protocol that has positions that can be liquidated
    ILiquidationProtocol public immutable liquidationProtocol;
    
    // Mapping to track if we're in a liquidation process (prevents reentrancy)
    mapping(PoolId => bool) public isLiquidating;
    
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
        uint256 minProfitAmount; // Minimum profit required (optional)
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
     * @return LiquidationParams struct with decoded data
     */
    function decodeLiquidationParams(bytes calldata data) internal pure returns (LiquidationParams memory) {
        if (data.length == 0) {
            return LiquidationParams(address(0), address(0), address(0), 0, 0);
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
        address debtToken;
        uint256 debtAmount;
        
        if (params.zeroForOne) {
            // We're swapping token0 for token1, so token1 is what we receive
            debtToken = Currency.unwrap(key.currency1);
            debtAmount = uint256(int256(-delta.amount1()));
        } else {
            // We're swapping token1 for token0, so token0 is what we receive
            debtToken = Currency.unwrap(key.currency0);
            debtAmount = uint256(int256(-delta.amount0()));
        }
        
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
        
        // Using block-scoped variables to handle liquidation logic
        bool success = false;
        string memory errorReason = "Unknown error";
        uint256 collateralAmount = 0;
        uint256 debtTokenReceived = 0;
        uint256 profit = 0;
        
        // Execute liquidation logic
        try liquidationProtocol.liquidate(
            liquidationParams.borrower,
            liquidationParams.debtToken,
            liquidationParams.collateralToken,
            debtAmount
        ) returns (uint256 _collateralAmount) {
            collateralAmount = _collateralAmount;
            
            // Approve collateral for use by PoolManager
            IERC20(liquidationParams.collateralToken).approve(address(poolManager), collateralAmount);
            
            // Now swap the collateral for debt token through a new swap
            try this.executeCollateralSwap(
                liquidationParams.collateralToken,
                liquidationParams.debtToken,
                collateralAmount
            ) returns (uint256 _debtTokenReceived) {
                debtTokenReceived = _debtTokenReceived;
                
                // Ensure we got enough debt tokens back
                if (debtTokenReceived < debtAmount) {
                    errorReason = "Not enough tokens to repay debt";
                    revert(errorReason);
                }
                
                // Return the debt token to the original pool through a sync and settle operation
                try this.settleDebtToken(liquidationParams.debtToken) {
                    // Calculate profit
                    if (debtTokenReceived > debtAmount) {
                        profit = debtTokenReceived - debtAmount;
                        
                        // Check if profit meets minimum requirement
                        if (profit >= liquidationParams.minProfitAmount) {
                            // Transfer profit to the caller
                            IERC20(liquidationParams.debtToken).transfer(sender, profit);
                        }
                    }
                    
                    success = true;
                } catch Error(string memory reason) {
                    errorReason = reason;
                    success = false;
                } catch {
                    errorReason = "Failed to settle debt";
                    success = false;
                    revert(errorReason);
                }
            } catch Error(string memory reason) {
                errorReason = reason;
                success = false;
                revert(errorReason);
            } catch {
                errorReason = "Failed to swap collateral";
                success = false;
                revert(errorReason);
            }
        } catch Error(string memory reason) {
            errorReason = reason;
            success = false;
            revert(errorReason);
        } catch {
            errorReason = "Failed to liquidate position";
            success = false;
            revert(errorReason);
        }
        
        // Reset the liquidation flag
        isLiquidating[poolId] = false;
        
        if (success) {
            // Emit liquidation success event
            emit LiquidationExecuted(
                liquidationParams.borrower,
                liquidationParams.debtToken,
                liquidationParams.collateralToken,
                debtAmount,
                collateralAmount,
                profit
            );
        } else {
            // Emit liquidation failure event
            emit LiquidationFailed(
                liquidationParams.borrower,
                liquidationParams.debtToken,
                liquidationParams.collateralToken,
                debtAmount,
                errorReason
            );
        }
        
        // Return the appropriate function selector and a zero delta
        // This indicates we don't want to modify the swap delta
        return (IHooks.afterSwap.selector, 0);
    }
    
    /**
     * @notice Executes a swap to convert collateral to debt token
     * @param collateralToken The collateral token to swap
     * @param debtToken The debt token to receive
     * @param collateralAmount The amount of collateral to swap
     * @return debtTokenReceived The amount of debt tokens received
     */
    function executeCollateralSwap(
        address collateralToken,
        address debtToken,
        uint256 collateralAmount
    ) external returns (uint256 debtTokenReceived) {
        // Only allow this contract to call this function
        require(msg.sender == address(this), "Only self-call allowed");
        
        // Get the pool key for swapping collateral to debt token
        PoolKey memory collateralPool = getPoolKey(collateralToken, debtToken);
        
        // Sync the collateral token to update balances
        poolManager.sync(Currency.wrap(collateralToken));
        
        // Determine swap direction
        bool zeroForOne = collateralToken < debtToken;
        
        // Execute swap
        BalanceDelta swapDelta = poolManager.swap(
            collateralPool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(collateralAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
            }),
            ""
        );
        
        // Calculate received debt tokens
        if (zeroForOne) {
            debtTokenReceived = uint256(int256(-swapDelta.amount1()));
        } else {
            debtTokenReceived = uint256(int256(-swapDelta.amount0()));
        }
        
        return debtTokenReceived;
    }
    
    // Constants for swap price limits
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    
    /**
     * @notice Settle debt with the pool manager
     * @param debtToken The debt token to settle
     */
    function settleDebtToken(address debtToken) external {
        // Only allow this contract to call this function
        require(msg.sender == address(this), "Only self-call allowed");
        
        // Return the debt token to the original pool
        poolManager.sync(Currency.wrap(debtToken));
        poolManager.settle();
    }
    
    /**
     * @notice Helper to get a pool key for two tokens
     * @param tokenA First token
     * @param tokenB Second token
     * @return PoolKey for the token pair
     */
    function getPoolKey(address tokenA, address tokenB) internal view returns (PoolKey memory) {
        // Sort tokens to get currency0 and currency1
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
            
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3% fee tier
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
    }
    
    /**
     * @notice Initiates a flash liquidation
     * @param debtToken Token to borrow for liquidation
     * @param collateralToken Token used as collateral
     * @param borrower Address of the borrower to liquidate
     * @param debtAmount Amount of debt to liquidate
     * @param minProfitAmount Minimum profit required (optional)
     */
    function flashLiquidate(
        address debtToken,
        address collateralToken,
        address borrower,
        uint256 debtAmount,
        uint256 minProfitAmount
    ) external {
        // Check if the position is liquidatable first
        (bool liquidatable, uint256 maxDebtAmount) = liquidationProtocol.isLiquidatable(
            borrower,
            debtToken,
            collateralToken
        );
        
        require(liquidatable, "Position not liquidatable");
        
        // Cap debt amount to maximum liquidatable amount
        if (debtAmount > maxDebtAmount) {
            debtAmount = maxDebtAmount;
        }
        
        // Create the pool key
        PoolKey memory key = getPoolKey(debtToken, collateralToken);
        
        // Encode the liquidation parameters
        bytes memory hookData = abi.encode(
            LiquidationParams({
                borrower: borrower,
                debtToken: debtToken,
                collateralToken: collateralToken,
                debtAmount: debtAmount,
                minProfitAmount: minProfitAmount
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
     */
    function checkLiquidationProfitability(
        address debtToken,
        address collateralToken,
        address borrower
    ) external view returns (
        bool liquidatable,
        uint256 maxDebtAmount,
        uint256 estimatedProfit
    ) {
        // Check if position is liquidatable
        (liquidatable, maxDebtAmount) = liquidationProtocol.isLiquidatable(
            borrower,
            debtToken,
            collateralToken
        );
        
        if (!liquidatable || maxDebtAmount == 0) {
            return (false, 0, 0);
        }
        
        // This would require a simulation of the swap to be accurate
        // For an MVP, we'll just return 0 for estimated profit
        // In a production environment, you'd simulate the swap and liquidation
        estimatedProfit = 0;
        
        return (liquidatable, maxDebtAmount, estimatedProfit);
    }
}
