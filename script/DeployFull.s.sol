// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FlashLiquidationHook} from "../src/FlashLiquidationHook.sol";
import {MockLiquidationProtocol} from "../src/mock/MockLiquidationProtocol.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";
import {LiquidationOrchestrator} from "../src/LiquidationOrchestrator.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();
        
        // Replace with actual PoolManager address for the network you're deploying to
        address poolManagerAddress = 0x0000000000000000000000000000000000000000; // Placeholder
        
        // Deploy mock tokens for testing
        MockERC20 mockWETH = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        
        console.log("MockWETH deployed at:", address(mockWETH));
        console.log("MockUSDC deployed at:", address(mockUSDC));
        
        // Mint some tokens for testing
        mockWETH.mint(msg.sender, 100 ether);
        mockUSDC.mint(msg.sender, 100_000 * 1e6);
        
        // Deploy the mock liquidation protocol for testing
        MockLiquidationProtocol mockProtocol = new MockLiquidationProtocol();
        console.log("MockLiquidationProtocol deployed at:", address(mockProtocol));
        
        // Deploy the flash liquidation hook
        FlashLiquidationHook hook = new FlashLiquidationHook(
            IPoolManager(poolManagerAddress),
            mockProtocol
        );
        console.log("FlashLiquidationHook deployed at:", address(hook));
        
        // Deploy the liquidation orchestrator
        LiquidationOrchestrator orchestrator = new LiquidationOrchestrator(
            hook,
            1e18, // Minimum profit of 1 ETH
            msg.sender
        );
        console.log("LiquidationOrchestrator deployed at:", address(orchestrator));
        
        // Set up a test position
        mockWETH.mint(address(mockProtocol), 10 ether);
        mockUSDC.mint(address(mockProtocol), 20_000 * 1e6);
        
        // Create an underwater position
        mockProtocol.setupBorrowerPosition(
            address(0x1234), // Test borrower
            address(mockUSDC),
            address(mockWETH),
            5_000 * 1e6, // 5,000 USDC debt
            2 ether, // 2 WETH collateral
            true // Mark as underwater
        );
        
        console.log("Test position created for borrower:", address(0x1234));
        console.log("USDC debt:", 5_000 * 1e6);
        console.log("WETH collateral:", 2 ether);
        
        vm.stopBroadcast();
    }
}
