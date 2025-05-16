// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockOracle} from "../src/mock/oracle/MockOracle.sol";
import {MockLiquidationProtocol} from "../src/mock/MockLiquidationProtocol.sol";
import {FlashLiquidationHook} from "../src/FlashLiquidationHook.sol";
import {LiquidationOrchestrator} from "../src/LiquidationOrchestrator.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";

/**
 * @title DeployImprovedScript
 * @notice Script to deploy the improved liquidation hook and related contracts
 */
contract DeployImprovedScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy mock tokens for testing
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 lepToken = new MockERC20("Leprechaun Synthetic", "LEP", 18);
        
        // Set up initial supplies
        weth.mint(msg.sender, 1000 ether);
        usdc.mint(msg.sender, 1000000 * 10**6);
        lepToken.mint(msg.sender, 1000 ether);
        
        // Deploy MockOracle
        MockOracle oracle = new MockOracle();
        
        // Set token prices in the oracle
        oracle.setTokenPrice(address(weth), 2000e18, 18); // WETH = $2000
        oracle.setTokenPrice(address(usdc), 1e18, 6);     // USDC = $1
        oracle.setTokenPrice(address(lepToken), 10e18, 18); // LEP = $10
        
        // Deploy MockLiquidationProtocol
        address feeCollector = msg.sender;
        MockLiquidationProtocol liquidationProtocol = new MockLiquidationProtocol(
            address(oracle),
            feeCollector
        );
        
        // Configure liquidation protocol
        liquidationProtocol.setDefaultMinCollateralRatio(15000); // 150%
        liquidationProtocol.setAssetAuctionDiscount(address(lepToken), 1000); // 10% discount
        liquidationProtocol.setAssetMinCollateralRatio(address(lepToken), 15000); // 150%
        liquidationProtocol.setCollateralRiskMultiplier(address(weth), 10000); // 1.0
        liquidationProtocol.setCollateralRiskMultiplier(address(usdc), 9000); // 0.9 (slightly higher risk for stablecoins)
        
        // Allow the liquidation protocol to mint/burn tokens
        // In a real implementation, this would be handled by the protocol's own logic
        weth.mint(address(liquidationProtocol), 10000 ether);
        usdc.mint(address(liquidationProtocol), 20000000 * 10**6);
        lepToken.mint(address(liquidationProtocol), 10000 ether);
        
        // Get the Uniswap V4 Pool Manager address
        // This would be a real address on a live network
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        IPoolManager poolManager = IPoolManager(poolManagerAddress);
        
        // Deploy FlashLiquidationHook
        FlashLiquidationHook flashLiquidationHook = new FlashLiquidationHook(
            poolManager,
            liquidationProtocol
        );
        
        // Deploy LiquidationOrchestrator
        uint256 minProfitAmount = 100 * 10**6; // 100 USDC minimum profit
        LiquidationOrchestrator liquidationOrchestrator = new LiquidationOrchestrator(
            flashLiquidationHook,
            minProfitAmount,
            msg.sender
        );
        
        // Add token pairs to monitor
        liquidationOrchestrator.addTokenPair(address(usdc), address(weth), 3000); // 0.3% fee tier
        liquidationOrchestrator.addTokenPair(address(lepToken), address(weth), 3000); // 0.3% fee tier
        liquidationOrchestrator.addTokenPair(address(lepToken), address(usdc), 500); // 0.05% fee tier
        
        // Set up a test underwater position
        address testUser = vm.addr(1); // Test user address
        
        // Create a position for the test user
        liquidationProtocol.addTestPosition(
            testUser,
            address(lepToken), // Synthetic asset (debt)
            address(weth),     // Collateral
            1 ether,           // 1 WETH as collateral
            100 ether          // 100 LEP as debt
        );
        
        // Set position as underwater (collateral value dropped)
        // 1 WETH = $2000, 100 LEP = $1000, so collateralization ratio = 200%
        // But if WETH price drops to $1000, ratio would be 100% (underwater)
        // We simulate this by setting the position as underwater
        oracle.setTokenPrice(address(weth), 1000e18, 18); // WETH price drop to $1000
        
        vm.stopBroadcast();
        
        console.log("Deployment completed:");
        console.log("WETH address:", address(weth));
        console.log("USDC address:", address(usdc));
        console.log("LEP token address:", address(lepToken));
        console.log("Oracle address:", address(oracle));
        console.log("Liquidation Protocol address:", address(liquidationProtocol));
        console.log("Flash Liquidation Hook address:", address(flashLiquidationHook));
        console.log("Liquidation Orchestrator address:", address(liquidationOrchestrator));
        console.log("Test user with underwater position:", testUser);
    }
}
