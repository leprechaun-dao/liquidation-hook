// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockOracle} from "../src/mock/oracle/MockOracle.sol";
import {MockLiquidationProtocol} from "../src/mock/MockLiquidationProtocol.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {FlashLiquidationHook} from "../src/FlashLiquidationHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title MockPoolManager
 * @notice A simplified mock for the Uniswap V4 PoolManager used for testing the hook
 */
contract MockPoolManager is IPoolManager {
    // Track balances to simulate flash loans and swaps
    mapping(address => uint256) public tokenBalances;
    
    // Track hook calls
    bool public afterSwapCalled;
    address public lastSwapSender;
    PoolKey public lastPoolKey;
    bytes public lastHookData;
    
    // Track loans
    mapping(address => uint256) public flashLoans;
    
    // Add tokens to the pool
    function addTokens(address token, uint256 amount) external {
        tokenBalances[token] += amount;
    }
    
    // Mocked swap function that simulates a flash loan
    function swap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        // Record the swap details
        afterSwapCalled = true;
        lastSwapSender = msg.sender;
        lastPoolKey = key;
        lastHookData = hookData;
        
        // Parse the tokens
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        address borrowToken = params.zeroForOne ? token1 : token0;
        
        // For negative amountSpecified, we're doing a flash loan
        if (params.amountSpecified < 0) {
            uint256 borrowAmount = uint256(-params.amountSpecified);
            
            // Record the flash loan
            flashLoans[borrowToken] = borrowAmount;
            
            // Transfer tokens to the borrower
            MockERC20(borrowToken).transfer(msg.sender, borrowAmount);
            
            // Call the hook to handle the flash loan
            IHooks(address(key.hooks)).afterSwap(
                msg.sender,
                key,
                params,
                BalanceDelta.wrap(0, 0), // Simplified for test
                hookData
            );
            
            // Ensure loan is repaid
            require(flashLoans[borrowToken] <= tokenBalances[borrowToken], "Flash loan not repaid");
            flashLoans[borrowToken] = 0;
        } else {
            // Regular swap
            address sellToken = params.zeroForOne ? token0 : token1;
            address buyToken = params.zeroForOne ? token1 : token0;
            
            uint256 sellAmount = uint256(params.amountSpecified);
            uint256 buyAmount = (sellAmount * 98) / 100; // Simple 2% slippage
            
            // Transfer tokens
            MockERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
            MockERC20(buyToken).transfer(msg.sender, buyAmount);
            
            // Update balances
            tokenBalances[sellToken] += sellAmount;
            tokenBalances[buyToken] -= buyAmount;
            
            // Set delta
            if (params.zeroForOne) {
                delta = BalanceDelta.wrap(int128(int256(sellAmount)), -int128(int256(buyAmount)));
            } else {
                delta = BalanceDelta.wrap(-int128(int256(buyAmount)), int128(int256(sellAmount)));
            }
        }
        
        return delta;
    }
    
    // Mocked sync function
    function sync(Currency currency) external returns (int256 delta) {
        // No-op for testing
        return 0;
    }
    
    // Mocked settle function for flash loans
    function settle() external returns (uint256) {
        // No-op for testing
        return 0;
    }
    
    // Mocked mint function for tokens
    function mint(
        Currency currency,
        address to,
        uint256 amount
    ) external {
        address token = Currency.unwrap(currency);
        MockERC20(token).transfer(to, amount);
    }
    
    // This is needed to silence compiler warnings - the mock is incomplete
    function initialize(PoolKey calldata, uint160, bytes calldata) external pure returns (int24) { return 0; }
    function modifyLiquidity(PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure returns (BalanceDelta) { return BalanceDelta.wrap(0, 0); }
    function donate(PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) { return BalanceDelta.wrap(0, 0); }
    function take(Currency, address, uint256) external pure returns (uint256) { return 0; }
    function settle(Currency) external pure returns (uint256) { return 0; }
    function lock(bytes calldata) external pure returns (bytes memory) { return ""; }
    function unlock(bytes calldata) external pure {}
    function getSlot0(PoolKey calldata) external pure returns (uint160, int24, uint16, uint16, uint8, bool) { return (0, 0, 0, 0, 0, false); }
    function getPosition(PoolKey calldata, address, int24, int24) external pure returns (int128, uint256, uint256, uint128, uint256) { return (0, 0, 0, 0, 0); }
}

/**
 * @title FlashLiquidationHookTest
 * @notice Tests for the FlashLiquidationHook
 */
contract FlashLiquidationHookTest is Test {
    MockOracle public oracle;
    MockLiquidationProtocol public protocol;
    MockPoolManager public poolManager;
    FlashLiquidationHook public hook;
    
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public lepToken;
    
    address public feeCollector;
    address public alice;
    address public bob;
    address public liquidator;
    
    function setUp() public {
        // Create users
        feeCollector = makeAddr("feeCollector");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        liquidator = makeAddr("liquidator");
        
        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lepToken = new MockERC20("Leprechaun Synthetic", "LEP", 18);
        
        // Deploy oracle
        oracle = new MockOracle();
        
        // Set token prices
        oracle.setTokenPrice(address(weth), 2000e18, 18); // WETH = $2000
        oracle.setTokenPrice(address(usdc), 1e18, 6);     // USDC = $1
        oracle.setTokenPrice(address(lepToken), 10e18, 18); // LEP = $10
        
        // Deploy mock protocol
        protocol = new MockLiquidationProtocol(address(oracle), feeCollector);
        
        // Configure protocol
        protocol.setDefaultMinCollateralRatio(15000); // 150%
        protocol.setAssetAuctionDiscount(address(lepToken), 1000); // 10% discount
        protocol.setAssetAuctionDiscount(address(weth), 1000); // 10% discount
        protocol.setAssetAuctionDiscount(address(usdc), 1000); // 10% discount
        
        // Deploy mock pool manager
        poolManager = new MockPoolManager();
        
        // Deploy flash liquidation hook
        hook = new FlashLiquidationHook(IPoolManager(address(poolManager)), protocol);
        
        // Set up pools with liquidity
        weth.mint(address(poolManager), 100 ether);
        usdc.mint(address(poolManager), 200_000 * 10**6);
        lepToken.mint(address(poolManager), 200 ether);
        
        poolManager.addTokens(address(weth), 100 ether);
        poolManager.addTokens(address(usdc), 200_000 * 10**6);
        poolManager.addTokens(address(lepToken), 200 ether);
        
        // Set up test position for alice (an underwater position)
        weth.mint(address(protocol), 10 ether);
        lepToken.mint(address(protocol), 1000 ether);
        
        uint256 positionId = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            1 ether,
            100 ether
        );
        
        // Make position underwater
        oracle.setTokenPrice(address(weth), 500e18, 18); // Price drop to $500
        
        // Give liquidator some tokens to pay for transactions
        lepToken.mint(liquidator, 100 ether);
        weth.mint(liquidator, 5 ether);
        usdc.mint(liquidator, 10_000 * 10**6);
    }
    
    function test_HookPermissions() public {
        // Get the hook permissions
        Hooks.Permissions memory perms = hook.getHookPermissions();
        
        // Verify that only the afterSwap hook is enabled
        assertFalse(perms.beforeInitialize, "beforeInitialize should be disabled");
        assertFalse(perms.afterInitialize, "afterInitialize should be disabled");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity should be disabled");
        assertFalse(perms.afterAddLiquidity, "afterAddLiquidity should be disabled");
        assertFalse(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be disabled");
        assertFalse(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be disabled");
        assertFalse(perms.beforeSwap, "beforeSwap should be disabled");
        assertTrue(perms.afterSwap, "afterSwap should be enabled");
        assertFalse(perms.beforeDonate, "beforeDonate should be disabled");
        assertFalse(perms.afterDonate, "afterDonate should be disabled");
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be disabled");
        assertFalse(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be disabled");
        assertFalse(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be disabled");
        assertFalse(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be disabled");
    }
    
    function test_CheckLiquidationProfitability() public {
        // Check the liquidation profitability
        (bool liquidatable, uint256 maxDebtAmount, uint256 estimatedProfit, uint256 estimatedCollateral) = 
            hook.checkLiquidationProfitability(
                address(lepToken),
                address(weth),
                alice
            );
        
        assertTrue(liquidatable, "Position should be liquidatable");
        assertEq(maxDebtAmount, 100 ether, "Max debt amount should be 100 LEP");
        assertGt(estimatedCollateral, 0, "Estimated collateral should be greater than 0");
        
        console.log("Estimated collateral:", estimatedCollateral);
        console.log("Estimated profit:", estimatedProfit);
        
        // Expected calculation:
        // 100 LEP = $1000 debt value
        // With 10% auction discount = $1100 discounted debt value
        // At $500 per WETH, that's 2.2 WETH ($1100 / $500)
        uint256 expectedCollateral = 2.2 ether;
        assertApproxEqAbs(estimatedCollateral, expectedCollateral, 0.1 ether, "Collateral estimate should be around 2.2 WETH");
    }
    
    function test_SimulateLiquidation() public {
        // Use the hook's simulate function to estimate returns
        (uint256 estimatedCollateral, uint256 estimatedProfit) = hook.simulateLiquidation(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        
        console.log("Simulated collateral:", estimatedCollateral);
        console.log("Simulated profit:", estimatedProfit);
        
        // Expected as above
        uint256 expectedCollateral = 2.2 ether;
        assertApproxEqAbs(estimatedCollateral, expectedCollateral, 0.1 ether, "Simulated collateral should be around 2.2 WETH");
        assertGt(estimatedProfit, 0, "Should estimate some profit");
    }
    
    function test_FlashLiquidate() public {
        // Flash liquidate the position
        vm.startPrank(liquidator);
        
        // Approve tokens for repayment
        lepToken.approve(address(protocol), 100 ether);
        
        // Initial balance
        uint256 initialBalance = lepToken.balanceOf(liquidator);
        
        // Execute flash liquidation
        hook.flashLiquidate(
            address(lepToken),
            address(weth),
            alice,
            100 ether,
            0,            // Min profit
            2 ether,      // Min collateral
            3000          // Fee tier
        );
        
        // Final balance - check if got a profit
        uint256 finalBalance = lepToken.balanceOf(liquidator);
        
        vm.stopPrank();
        
        // Verify transaction success
        assertEq(initialBalance, finalBalance, "No LEP should be spent (flash loan repaid from collateral)");
        
        // Verify position was liquidated
        (bool stillLiquidatable, ) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(weth)
        );
        
        assertFalse(stillLiquidatable, "Position should no longer be liquidatable");
    }
    
    function test_FlashLiquidateWithMinimumProfit() public {
        // Set minimum profit to a high value
        uint256 highMinProfit = 10 ether; // Very high profit requirement
        
        vm.startPrank(liquidator);
        lepToken.approve(address(protocol), 100 ether);
        
        // Should revert due to insufficient profit
        vm.expectRevert("Profit below minimum requirement");
        hook.flashLiquidate(
            address(lepToken),
            address(weth),
            alice,
            100 ether,
            highMinProfit,
            2 ether,
            3000
        );
        
        vm.stopPrank();
    }
    
    function test_FlashLiquidateWithMinimumCollateral() public {
        // Set minimum collateral to a high value
        uint256 highMinCollateral = 3 ether; // More than expected 2.2 WETH
        
        vm.startPrank(liquidator);
        lepToken.approve(address(protocol), 100 ether);
        
        // Should revert due to insufficient collateral
        vm.expectRevert("Received collateral below minimum");
        hook.flashLiquidate(
            address(lepToken),
            address(weth),
            alice,
            100 ether,
            0,
            highMinCollateral,
            3000
        );
        
        vm.stopPrank();
    }
    
    function test_NonLiquidatablePosition() public {
        // Set the price back to $2000, making position healthy
        oracle.setTokenPrice(address(weth), 2000e18, 18);
        
        vm.startPrank(liquidator);
        lepToken.approve(address(protocol), 100 ether);
        
        // Should revert because position is not liquidatable
        vm.expectRevert("Position not liquidatable");
        hook.flashLiquidate(
            address(lepToken),
            address(weth),
            alice,
            100 ether,
            0,
            1 ether,
            3000
        );
        
        vm.stopPrank();
    }
    
    function test_SetDefaultPoolConfig() public {
        // Test changing the default fee tier and tick spacing
        uint24 newFeeTier = 500;  // 0.05%
        int24 newTickSpacing = 10;
        
        hook.setDefaultPoolConfig(newFeeTier, newTickSpacing);
        
        assertEq(hook.defaultFeeTier(), newFeeTier, "Fee tier should be updated");
        assertEq(hook.defaultTickSpacing(), newTickSpacing, "Tick spacing should be updated");
    }
}
