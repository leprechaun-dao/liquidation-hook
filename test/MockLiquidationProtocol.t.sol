// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockOracle} from "../src/mock/oracle/MockOracle.sol";
import {MockLiquidationProtocol} from "../src/mock/MockLiquidationProtocol.sol";
import {MockERC20} from "../src/mock/MockERC20.sol";

/**
 * @title LiquidationProtocolTest
 * @notice Test for the improved mock liquidation protocol
 */
contract LiquidationProtocolTest is Test {
    MockOracle public oracle;
    MockLiquidationProtocol public protocol;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockERC20 public lepToken;
    
    address public feeCollector;
    address public alice;
    address public bob;
    
    function setUp() public {
        // Create users
        feeCollector = makeAddr("feeCollector");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        
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
        
        // Deploy protocol
        protocol = new MockLiquidationProtocol(address(oracle), feeCollector);
        
        // Configure protocol
        protocol.setDefaultMinCollateralRatio(15000); // 150%
        protocol.setAssetAuctionDiscount(address(lepToken), 1000); // 10% discount for LEP
        protocol.setAssetAuctionDiscount(address(weth), 1000); // 10% discount for WETH
        protocol.setAssetAuctionDiscount(address(usdc), 1000); // 10% discount for USDC
        protocol.setAssetMinCollateralRatio(address(lepToken), 15000); // 150%
        protocol.setAssetMinCollateralRatio(address(weth), 15000); // 150%
        protocol.setAssetMinCollateralRatio(address(usdc), 15000); // 150%
        protocol.setCollateralRiskMultiplier(address(weth), 10000); // 1.0
        protocol.setCollateralRiskMultiplier(address(usdc), 9000); // 0.9
        
        // Set up test tokens
        weth.mint(address(protocol), 1000 ether);
        usdc.mint(address(protocol), 1000000 * 10**6);
        lepToken.mint(address(protocol), 1000 ether);
        
        weth.mint(alice, 10 ether);
        usdc.mint(alice, 20000 * 10**6);
        lepToken.mint(alice, 100 ether);
        
        weth.mint(bob, 10 ether);
        usdc.mint(bob, 20000 * 10**6);
        lepToken.mint(bob, 100 ether);
    }
    
    function test_CalculateCollateralRatio() public {
        // Set up a position with:
        // - 1 WETH ($2000) as collateral
        // - 100 LEP ($1000) as debt
        // Expected ratio: 200% or 20000 in the scaled format
        uint256 positionId = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            1 ether,
            100 ether
        );
        
        uint256 ratio = protocol.calculateCollateralRatio(alice, positionId);
        assertEq(ratio, 20000, "Collateral ratio should be 200%");
        
        // Simulate price drop to $1000 for WETH
        oracle.setTokenPrice(address(weth), 1000e18, 18);
        
        ratio = protocol.calculateCollateralRatio(alice, positionId);
        assertEq(ratio, 10000, "Collateral ratio should be 100% after price drop");
    }
    
    function test_IsLiquidatable() public {
        // Position with 200% collateralization, not liquidatable
        uint256 positionId1 = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            1 ether,
            100 ether
        );
        
        (bool liquidatable, uint256 maxDebtAmount) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(weth)
        );
        
        assertFalse(liquidatable, "Position should not be liquidatable at 200% ratio");
        assertEq(maxDebtAmount, 0, "Max debt amount should be 0 for non-liquidatable position");
        
        // Simulate price drop to $900 for WETH, making it undercollateralized
        oracle.setTokenPrice(address(weth), 900e18, 18);
        
        (liquidatable, maxDebtAmount) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(weth)
        );
        
        assertTrue(liquidatable, "Position should be liquidatable after price drop");
        assertEq(maxDebtAmount, 100 ether, "Max debt amount should be the full debt amount");
    }
    
    function test_Liquidate() public {
        // Set up a position for alice with 200% collateralization
        uint256 positionId = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            1 ether,
            100 ether
        );
        
        // Approve bob's tokens for liquidation
        vm.startPrank(bob);
        lepToken.approve(address(protocol), 100 ether);
        
        // Try to liquidate when the position is not underwater
        vm.expectRevert("Position not liquidatable");
        protocol.liquidate(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        
        // Make the position underwater
        oracle.setTokenPrice(address(weth), 900e18, 18);
        
        // Now bob can liquidate alice's position
        uint256 collateralSeized = protocol.liquidate(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        vm.stopPrank();
        
        // Check logging for debugging
        console.log("Collateral seized:", collateralSeized);
        
        // Bob should have received the collateral with a 10% bonus
        // 100 LEP = $1000, with 10% bonus = $1100
        // At $900 per WETH, that's approximately 1.22 WETH
        assertGt(collateralSeized, 1.2 ether, "Bob should receive collateral with bonus");
        assertLt(collateralSeized, 1.3 ether, "Bob should not receive too much collateral");
        
        // Check that the position is now closed
        (bool liquidatable, ) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(weth)
        );
        assertFalse(liquidatable, "Position should no longer be liquidatable");
    }
    
    function test_ProtocolFee() public {
        // Set up a position for alice with 200% collateralization
        uint256 positionId = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            2 ether,
            100 ether
        );
        
        // Set protocol fee to 5%
        protocol.setProtocolFee(500);
        
        // Make the position underwater
        oracle.setTokenPrice(address(weth), 750e18, 18); // Make sure it's clearly underwater
        
        // Record initial fee collector balance
        uint256 initialFeeCollectorBalance = weth.balanceOf(feeCollector);
        
        // Bob liquidates alice's position
        vm.startPrank(bob);
        lepToken.approve(address(protocol), 100 ether);
        
        // Check the liquidation status first
        (bool isLiquidatable, uint256 maxDebtAmount) = protocol.isLiquidatable(
            alice, 
            address(lepToken), 
            address(weth)
        );
        console.log("Is liquidatable:", isLiquidatable ? 1 : 0);
        console.log("Max debt amount:", maxDebtAmount);
        
        // Perform the liquidation
        protocol.liquidate(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        vm.stopPrank();
        
        // Check fee collector received a fee
        uint256 newFeeCollectorBalance = weth.balanceOf(feeCollector);
        uint256 feeCollected = newFeeCollectorBalance - initialFeeCollectorBalance;
        
        assertGt(feeCollected, 0, "Fee collector should have received a fee");
    }
    
    function test_SimulateLiquidation() public {
        // Set up a position for alice with 200% collateralization
        uint256 positionId = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            1 ether,
            100 ether
        );
        
        // Position is not liquidatable yet
        uint256 collateralToSeize = protocol.simulateLiquidation(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        
        assertEq(collateralToSeize, 0, "No collateral to seize when position is not liquidatable");
        
        // Make the position underwater
        oracle.setTokenPrice(address(weth), 900e18, 18);
        
        // Simulate liquidation
        collateralToSeize = protocol.simulateLiquidation(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        
        console.log("Collateral to seize in simulation:", collateralToSeize);
        
        // Expected:
        // 100 LEP = $1000, with 10% bonus = $1100
        // At $900 per WETH, that's approximately 1.22 WETH
        assertGt(collateralToSeize, 1.2 ether, "Collateral to seize should include bonus");
        assertLt(collateralToSeize, 1.3 ether, "Collateral to seize calculation should be precise");
        
        // Get the simulation details with profit estimate
        (uint256 collateralAmount, uint256 profitUsd) = protocol.getSimulationDetails(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        
        // Verify the collateral amount matches
        assertEq(collateralAmount, collateralToSeize, "Collateral amounts should match");
        
        // Expected profit in USD:
        // $1100 (collateral value with bonus) - $1000 (debt value) = $100
        assertGt(profitUsd, 90e18, "Expected profit around $100");
        assertLt(profitUsd, 110e18, "Expected profit around $100");
    }
    
    function test_RequiredCollateral() public {
        // Calculate required collateral for 100 LEP with 150% minimum ratio
        uint256 requiredCollateral = protocol.calculateRequiredCollateral(
            address(lepToken),
            address(weth),
            100 ether
        );
        
        // 100 LEP = $1000, with 150% ratio = $1500
        // At $2000 per WETH, that's 0.75 WETH
        assertEq(requiredCollateral, 0.75 ether, "Required collateral should be 0.75 WETH");
        
        // Change the minimum ratio to 200%
        protocol.setAssetMinCollateralRatio(address(lepToken), 20000);
        
        // Recalculate required collateral
        requiredCollateral = protocol.calculateRequiredCollateral(
            address(lepToken),
            address(weth),
            100 ether
        );
        
        // 100 LEP = $1000, with 200% ratio = $2000
        // At $2000 per WETH, that's 1.0 WETH
        assertEq(requiredCollateral, 1 ether, "Required collateral should be 1.0 WETH with 200% ratio");
    }
    
    function test_EffectiveCollateralRatio() public {
        // Default: 150% minimum ratio, 1.0 risk multiplier = 150% effective ratio
        uint256 effectiveRatio = protocol.getEffectiveCollateralRatio(
            address(lepToken),
            address(weth)
        );
        
        assertEq(effectiveRatio, 15000, "Effective ratio should be 150%");
        
        // Set a risk multiplier of 1.2 for WETH
        protocol.setCollateralRiskMultiplier(address(weth), 12000);
        
        // Recalculate: 150% * 1.2 = 180%
        effectiveRatio = protocol.getEffectiveCollateralRatio(
            address(lepToken),
            address(weth)
        );
        
        assertEq(effectiveRatio, 18000, "Effective ratio should be 180% with 1.2 risk multiplier");
    }
    
    function test_MultiplePositions() public {
        // Create two positions for Alice
        uint256 position1 = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(weth),
            1 ether,
            100 ether
        );
        
        uint256 position2 = protocol.addTestPosition(
            alice,
            address(lepToken),
            address(usdc),
            2000 * 10**6, // $2000 in USDC
            100 ether      // $1000 in LEP
        );
        
        // Make only the WETH position underwater
        oracle.setTokenPrice(address(weth), 900e18, 18);
        
        // Check if each position is liquidatable
        (bool liquidatable1, ) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(weth)
        );
        
        (bool liquidatable2, ) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(usdc)
        );
        
        assertTrue(liquidatable1, "WETH position should be liquidatable");
        assertFalse(liquidatable2, "USDC position should not be liquidatable");
        
        // Liquidate the WETH position
        vm.startPrank(bob);
        lepToken.approve(address(protocol), 100 ether);
        protocol.liquidate(
            alice,
            address(lepToken),
            address(weth),
            100 ether
        );
        vm.stopPrank();
        
        // Check that only the WETH position is closed
        (liquidatable1, ) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(weth)
        );
        
        (liquidatable2, ) = protocol.isLiquidatable(
            alice,
            address(lepToken),
            address(usdc)
        );
        
        assertFalse(liquidatable1, "WETH position should no longer be liquidatable");
        assertFalse(liquidatable2, "USDC position should still not be liquidatable");
    }
    
    function test_CreatePosition() public {
        // Alice creates a position with 1 WETH and 50 LEP
        vm.startPrank(alice);
        weth.approve(address(protocol), 1 ether);
        
        uint256 positionId = protocol.createPosition(
            address(lepToken),
            address(weth),
            1 ether,
            50 ether
        );
        vm.stopPrank();
        
        // Verify position details
        uint256 ratio = protocol.calculateCollateralRatio(alice, positionId);
        assertEq(ratio, 40000, "Collateral ratio should be 400%");
        
        // Try to create a position with insufficient collateral
        vm.startPrank(alice);
        weth.approve(address(protocol), 0.3 ether);
        
        vm.expectRevert("Insufficient collateral");
        protocol.createPosition(
            address(lepToken),
            address(weth),
            0.3 ether, // 0.3 WETH = $600, not enough for 150% of 100 LEP ($1000)
            100 ether
        );
        vm.stopPrank();
    }
}
