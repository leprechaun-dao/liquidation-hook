// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {FlashLiquidationHook} from "../src/FlashLiquidationHook.sol";
import {MockLiquidationProtocol} from "../src/mock/MockLiquidationProtocol.sol";
import {SimpleMockLiquidationProtocol} from "../src/mock/SimpleMockLiquidationProtocol.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {MockOracle} from "../src/mock/oracle/MockOracle.sol";
import {LiquidationOrchestrator} from "../src/LiquidationOrchestrator.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();
        
        // Replace with actual PoolManager address for the network you're deploying to
        address poolManagerAddress = 0x0000000000000000000000000000000000000000; // Placeholder
        
        // Deploy mock tokens for testing
        MockERC20 mockWETH = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        
        // Mint some tokens for testing
        mockWETH.mint(msg.sender, 100 ether);
        mockUSDC.mint(msg.sender, 100_000 * 1e6);
        
        // Deploy mock oracle
        MockOracle oracle = new MockOracle();
        
        // Set token prices
        oracle.setTokenPrice(address(mockWETH), 2000e18, 18); // WETH = $2000
        oracle.setTokenPrice(address(mockUSDC), 1e18, 6);     // USDC = $1
        
        // Deploy fee collector
        address feeCollector = msg.sender;
        
        // Deploy the improved mock liquidation protocol
        MockLiquidationProtocol mockProtocol = new MockLiquidationProtocol(
            address(oracle),
            feeCollector
        );
        
        // Configure the protocol
        mockProtocol.setDefaultMinCollateralRatio(15000); // 150%
        mockProtocol.setAssetAuctionDiscount(address(mockUSDC), 1000); // 10% discount
        
        // Deploy the flash liquidation hook
        FlashLiquidationHook hook = new FlashLiquidationHook(
            IPoolManager(poolManagerAddress),
            mockProtocol
        );
        
        // Deploy the liquidation orchestrator
        LiquidationOrchestrator orchestrator = new LiquidationOrchestrator(
            hook,
            1e18, // Minimum profit of 1 ETH
            msg.sender
        );
        
        // Send tokens to the protocol
        mockWETH.mint(address(mockProtocol), 10 ether);
        mockUSDC.mint(address(mockProtocol), 20_000 * 1e6);
        
        // Create an underwater position using the new method
        address testBorrower = address(0x1234); // Test borrower
        
        // Create position with insufficient collateral
        uint256 positionId = mockProtocol.addTestPosition(
            testBorrower,
            address(mockUSDC), // Debt token
            address(mockWETH), // Collateral token
            2 ether,          // 2 WETH as collateral
            5_000 * 1e6       // 5,000 USDC as debt
        );
        
        // Simulate price drop to make the position underwater
        // 2 WETH at $2000 = $4000, which is just 80% collateralization for $5000 debt
        // This is below the 150% requirement
        oracle.setTokenPrice(address(mockWETH), 1000e18, 18); // WETH price drops to $1000
        
        // Alternative approach: use SimpleMockLiquidationProtocol
        // Uncomment the following code if you prefer to use the simple version:
        
        /*
        // Deploy the simple mock liquidation protocol
        SimpleMockLiquidationProtocol simpleMockProtocol = new SimpleMockLiquidationProtocol();
        
        // Deploy another hook with the simple protocol
        FlashLiquidationHook simpleHook = new FlashLiquidationHook(
            IPoolManager(poolManagerAddress),
            simpleMockProtocol
        );
        
        // Configure the simple protocol
        simpleMockProtocol.setLiquidationBonus(1.1e18); // 10% bonus
        
        // Send tokens to the protocol
        mockWETH.mint(address(simpleMockProtocol), 10 ether);
        mockUSDC.mint(address(simpleMockProtocol), 20_000 * 1e6);
        
        // Create an underwater position
        simpleMockProtocol.setupBorrowerPosition(
            address(0x1234), // Test borrower
            address(mockUSDC),
            address(mockWETH),
            5_000 * 1e6, // 5,000 USDC debt
            2 ether, // 2 WETH collateral
            true // Mark as underwater
        );
        */
        
        vm.stopBroadcast();
    }
}
