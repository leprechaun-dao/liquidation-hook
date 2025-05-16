// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockOracle} from "../src/mock/oracle/MockOracle.sol";
import {MockLiquidationProtocol} from "../src/mock/MockLiquidationProtocol.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {FlashLiquidationHook} from "../src/FlashLiquidationHook.sol";
import {LiquidationOrchestrator} from "../src/LiquidationOrchestrator.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title MockPoolManager
 * @notice A simplified mock for the Uniswap V4 PoolManager used for testing
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
    
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }
    
    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (BalanceDelta) { return BalanceDelta.wrap(0, 0); }
    function donate(PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) { return BalanceDelta.wrap(0, 0); }
    function take(Currency, address, uint256) external pure returns (uint256) { return 0; }
    function settle(Currency) external pure returns (uint256) { return 0; }
    function lock(bytes calldata) external pure returns (bytes memory) { return ""; }
    function unlock(bytes calldata) external pure {}
    function getSlot0(PoolKey calldata) external pure returns (uint160, int24, uint16, uint16, uint8, bool) { return (0, 0, 0, 0, 0, false); }
    function getPosition(PoolKey calldata, address, int24, int24) external pure returns (int128, uint256, uint256, uint128, uint256) { return (0, 0, 0, 0, 0); }
}

/**
 * @title MockFlashLiquidationHook
 * @notice A mock implementation of the FlashLiquidationHook to use in orchestrator tests
 * @dev This allows us to test the orchestrator without needing the complex hook logic
 */
contract MockFlashLiquidationHook {
    MockLiquidationProtocol public liquidationProtocol;
    
    // Tracking variables for test verification
    address public lastDebtToken;
    address public lastCollateralToken;
    address public lastBorrower;
    uint256 public lastDebtAmount;
    uint256 public lastMinProfitAmount;
    uint256 public lastMinCollateralAmount;
    uint24 public lastFeeTier;
    
    // Simulate liquidation results
    bool public shouldSucceed = true;
    uint256 public simulatedProfit = 1 ether;
    uint256 public simulatedCollateral = 2 ether;
    
    constructor(MockLiquidationProtocol _protocol) {
        liquidationProtocol = _protocol;
    }
    
    // Mock the flash liquidate function
    function flashLiquidate(
        address debtToken,
        address collateralToken,
        address borrower,
        uint256 debtAmount,
        uint256 minProfitAmount,
        uint256 minCollateralAmount,
        uint24 feeTier
    ) external {
        // Record call parameters
        lastDebtToken = debtToken;
        lastCollateralToken = collateralToken;
        lastBorrower = borrower;
        lastDebtAmount = debtAmount;
        lastMinProfitAmount = minProfitAmount;
        lastMinCollateralAmount = minCollateralAmount;
        lastFeeTier = feeTier;
        
        // Check if we should succeed
        require(shouldSucceed, "Mock liquidation failed");
        
        // Check if profit is sufficient
        require(simulatedProfit >= minProfitAmount, "Profit below minimum requirement");
        
        // Check if collateral is sufficient
        require(simulatedCollateral >= minCollateralAmount, "Received collateral below minimum");
    }
    
    // Mock the check liquidation profitability function
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
        // Delegate to the real protocol for liquidatable check
        (liquidatable, maxDebtAmount) = liquidationProtocol.isLiquidatable(
            borrower,
            debtToken,
            collateralToken
        );
        
        if (liquidatable) {
            estimatedProfit = simulatedProfit;
            estimatedCollateral = simulatedCollateral;
        } else {
            estimatedProfit = 0;
            estimatedCollateral = 0;
        }
        
        return (liquidatable, maxDebtAmount, estimatedProfit, estimatedCollateral);
    }
    
    // Configure simulation parameters
    function setSimulationParams(bool _shouldSucceed, uint256 _profit, uint256 _collateral) external {
        shouldSucceed = _shouldSucceed;
        simulatedProfit = _profit;
        simulatedCollateral = _collateral;
    }
}

/**
 * @title LiquidationOrchestratorTest
 * @notice Tests for the LiquidationOrchestrator
 */
contract LiquidationOrchestratorTest is Test {
    MockOracle public oracle;
    MockLiquidationProtocol public protocol;
    MockFlashLiquidationHook public hook;
    LiquidationOrchestrator public orchestrator;
    
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public lepToken;
    
    address public feeCollector;
    address public alice;
    address public bob;
    address public profitReceiver;
    address public emergencyLiquidator;
    
    function setUp() public {
        // Create users
        feeCollector = makeAddr("feeCollector");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        profitReceiver = makeAddr("profitReceiver");
        emergencyLiquidator = makeAddr("emergencyLiquidator");
        
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
        
        // Deploy mock hook (simplified for testing orchestrator)
        hook = new MockFlashLiquidationHook(protocol);
        
        // Set up simulation parameters
        hook.setSimulationParams(true, 1 ether, 2 ether);
        
        // Deploy orchestrator
        uint256 minProfitAmount = 0.1 ether;
        orchestrator = new LiquidationOrchestrator(
            hook,
            minProfitAmount,
            profitReceiver
        );
        
        // Create underwater positions for testing
        weth.mint(address(protocol), 10 ether);
        usdc.mint(address(protocol), 20_000 * 10**6);
        lepToken.mint(address(protocol), 1000 ether);
        
        // Create position 1: WETH collateral, LEP debt
        uint256 positionId1 = protocol.addTestPosition(
            alice,
            address(lepToken), // Debt token
            address(weth),     // Collateral token
            1 ether,           // 1 WETH collateral
            100 ether          // 100 LEP debt
        );
        
        // Create position 2: USDC collateral, LEP debt
        uint256 positionId2 = protocol.addTestPosition(
            bob,
            address(lepToken), // Debt token
            address(usdc),     // Collateral token
            2000 * 10**6,      // 2000 USDC collateral
            100 ether          // 100 LEP debt
        );
        
        // Make positions underwater
        oracle.setTokenPrice(address(weth), 500e18, 18); // WETH price drop
        oracle.setTokenPrice(address(usdc), 0.5e18, 6);  // USDC price drop
        
        // Add token pairs to the orchestrator
        vm.startPrank(profitReceiver);
        orchestrator.addTokenPair(address(lepToken), address(weth), 3000);
        orchestrator.addTokenPair(address(lepToken), address(usdc), 500);
        vm.stopPrank();
    }
    
    function test_AddTokenPair() public {
        // Try to add as unauthorized user
        vm.startPrank(alice);
        vm.expectRevert("Not authorized");
        orchestrator.addTokenPair(address(weth), address(usdc), 3000);
        vm.stopPrank();
        
        // Add as profit receiver (already authorized)
        vm.startPrank(profitReceiver);
        orchestrator.addTokenPair(address(weth), address(usdc), 3000);
        vm.stopPrank();
        
        // Add as emergency liquidator
        vm.prank(address(orchestrator));
        vm.expectRevert("Not authorized");
        orchestrator.addTokenPair(address(weth), address(usdc), 100);
        
        // Set the emergency liquidator
        vm.prank(address(this));
        orchestrator.setProfitReceiver(emergencyLiquidator);
        
        // Now try again as emergency liquidator
        vm.startPrank(emergencyLiquidator);
        orchestrator.addTokenPair(address(weth), address(usdc), 100);
        vm.stopPrank();
    }
    
    function test_SetMinProfitAmount() public {
        // Try as unauthorized user
        vm.startPrank(alice);
        vm.expectRevert("Not owner");
        orchestrator.setMinProfitAmount(0.2 ether);
        vm.stopPrank();
        
        // Update as authorized user
        orchestrator.setMinProfitAmount(0.2 ether);
        
        // Verify parameters were updated
        assertEq(orchestrator.minProfitAmount(), 0.2 ether, "Min profit should be updated");
    }
    
    function test_SetProfitReceiver() public {
        // Try as unauthorized user
        vm.startPrank(alice);
        vm.expectRevert("Not owner");
        orchestrator.setProfitReceiver(bob);
        vm.stopPrank();
        
        // Update as authorized user
        orchestrator.setProfitReceiver(bob);
        
        // Verify parameters were updated
        assertEq(orchestrator.profitReceiver(), bob, "Profit receiver should be updated");
    }
    
    function test_ExecuteLiquidation() public {
        // Execute a liquidation through the orchestrator
        vm.startPrank(alice);
        orchestrator.executeLiquidation(
            address(lepToken),
            address(weth),
            alice,
            0,              // 0 = max available debt
            3000           // Fee tier
        );
        vm.stopPrank();
        
        // Verify the hook was called with the correct parameters
        assertEq(hook.lastDebtToken(), address(lepToken), "Debt token should match");
        assertEq(hook.lastCollateralToken(), address(weth), "Collateral token should match");
        assertEq(hook.lastBorrower(), alice, "Borrower should match");
        
        // Since we passed 0 for debtAmount, it should use the max available
        (,uint256 maxDebtAmount,,) = hook.checkLiquidationProfitability(
            address(lepToken),
            address(weth),
            alice
        );
        assertEq(hook.lastDebtAmount(), maxDebtAmount, "Debt amount should be max available");
        
        // Verify min profit comes from orchestrator
        assertEq(hook.lastMinProfitAmount(), orchestrator.minProfitAmount(), "Min profit should match orchestrator setting");
    }
    
    function test_ExecuteLiquidation_WithMinimumProfitFailure() public {
        // Set the hook to simulate a lower profit than required
        hook.setSimulationParams(true, 0.05 ether, 2 ether);
        
        // Set a higher minimum profit in the orchestrator
        orchestrator.setMinProfitAmount(0.2 ether);
        
        // Try to execute liquidation - should fail due to insufficient profit
        vm.startPrank(alice);
        vm.expectRevert("Insufficient profit");
        orchestrator.executeLiquidation(
            address(lepToken),
            address(weth),
            alice,
            0,
            3000
        );
        vm.stopPrank();
    }
    
    function test_ScanForLiquidations() public {
        // Create an array of addresses to scan
        address[] memory borrowers = new address[](3);
        borrowers[0] = alice;
        borrowers[1] = bob;
        borrowers[2] = address(0x123); // Some random address with no liquidatable positions
        
        // Scan for liquidations
        (
            address[] memory borrowersToLiquidate,
            address[] memory debtTokens,
            address[] memory collateralTokens,
            uint256[] memory debtAmounts
        ) = orchestrator.scanForLiquidations(borrowers);
        
        // We should have two liquidatable positions: alice's and bob's
        assertEq(borrowersToLiquidate.length, 2, "Should find 2 liquidatable positions");
        
        // Verify the results
        bool foundAlice = false;
        bool foundBob = false;
        
        for (uint256 i = 0; i < borrowersToLiquidate.length; i++) {
            if (borrowersToLiquidate[i] == alice) {
                foundAlice = true;
                assertEq(debtTokens[i], address(lepToken), "Alice's debt token should be LEP");
                assertEq(collateralTokens[i], address(weth), "Alice's collateral token should be WETH");
            }
            
            if (borrowersToLiquidate[i] == bob) {
                foundBob = true;
                assertEq(debtTokens[i], address(lepToken), "Bob's debt token should be LEP");
                assertEq(collateralTokens[i], address(usdc), "Bob's collateral token should be USDC");
            }
        }
        
        assertTrue(foundAlice, "Should find Alice's position");
        assertTrue(foundBob, "Should find Bob's position");
    }
}
