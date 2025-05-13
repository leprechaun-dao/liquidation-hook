# Uniswap V4 Flash Liquidation Hook

A Uniswap V4 hook implementation that enables flash swap-like functionality for liquidations in lending protocols. This hook allows liquidators to execute liquidations without requiring upfront capital.

## Overview

Traditional liquidations in DeFi lending protocols require liquidators to have the debt token on hand to repay the borrower's debt and claim the collateral. This creates a capital requirement that limits participation in the liquidation market.

This Flash Liquidation Hook leverages Uniswap V4's hook system and flash accounting to enable capital-efficient liquidations similar to Uniswap V2's flash swaps but with improved architecture.

## How It Works

### User Flow

1. A liquidator identifies an underwater position in a lending protocol
2. The liquidator calls `flashLiquidate()` on the hook, specifying:
   - The debt token (token to borrow for liquidation)
   - The collateral token (token that will be seized)
   - The borrower's address
   - The amount of debt to liquidate
   - Minimum profit requirement (optional)
3. The hook executes a swap to borrow the debt token
4. Within the same transaction, it liquidates the position, sells the collateral, repays the debt, and sends any profit to the liquidator

### Code Flow

1. **Initial Call**: Liquidator calls `flashLiquidate()`
2. **Flash Swap**: Hook performs a swap to obtain the debt tokens
3. **afterSwap Hook**: The hook's `afterSwap` function is triggered automatically
4. **Liquidation**: Inside `afterSwap`, the hook:
   - Identifies the underwater position
   - Calls the lending protocol's `liquidate()` function
   - Receives collateral from the liquidation
   - Swaps the collateral for the debt token in another Uniswap pool
   - Settles the debt to the original pool
   - Sends any profit to the liquidator
5. **Transaction Completion**: The entire process happens atomically in a single transaction

## Components

### FlashLiquidationHook

The main hook contract that implements the flash liquidation logic.

- **Implements**: `afterSwap` hook from Uniswap V4
- **Key Functions**:
  - `flashLiquidate()`: Entry point for liquidators
  - `afterSwap()`: Handles the liquidation logic
  - `checkLiquidationProfitability()`: Helper to check if a liquidation would be profitable

### ILiquidationProtocol

Interface for interacting with the lending protocol.

- **Key Functions**:
  - `liquidate()`: Liquidates a borrower's position
  - `isLiquidatable()`: Checks if a position can be liquidated

### MockLiquidationProtocol

A mock implementation of the lending protocol for testing and demonstration purposes.

## Key Benefits

1. **Capital Efficiency**: Liquidators don't need to hold debt tokens beforehand
2. **Atomic Execution**: The entire liquidation happens in a single transaction
3. **Risk Reduction**: If the liquidation doesn't yield enough to repay the flash loan, the transaction reverts
4. **Gas Efficiency**: Uses V4's singleton architecture and flash accounting
5. **Accessibility**: Lowers the barrier to entry for liquidators

## Prerequisites

- Uniswap V4 deployed on your network
- Access to a lending protocol that supports liquidations
- Foundry for development and deployment

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/liquidation-hook.git
cd liquidation-hook

# Install dependencies
forge install
```

## Getting Started

1. Install dependencies:
   ```bash
   bash setup.sh
   ```

2. Build the project:
   ```bash
   forge build
   ```

3. Edit the deployment script (`script/Deploy.s.sol`) with appropriate addresses.

4. Deploy the contract:
   ```bash
   forge script script/Deploy.s.sol:DeployScript --rpc-url [your_rpc_url] --broadcast
   ```
   
## Usage

### Check for Liquidatable Positions

```solidity
// Query the hook to check if a position is liquidatable and potentially profitable
(bool liquidatable, uint256 maxDebtAmount, uint256 estimatedProfit) = 
    flashLiquidationHook.checkLiquidationProfitability(
        debtToken,
        collateralToken,
        borrower
    );
```

### Execute a Flash Liquidation

```solidity
// Execute the liquidation if profitable
flashLiquidationHook.flashLiquidate(
    debtToken,        // Token to borrow (e.g., USDC)
    collateralToken,  // Token used as collateral (e.g., WETH)
    borrower,         // Address of the underwater position
    debtAmount,       // Amount of debt to liquidate
    minProfitAmount   // Minimum profit required (optional)
);
```

## Development

### Build

```shell
$ forge build
```

### Deploy

```shell
$ forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

## Integration with Lending Protocols

To integrate with a specific lending protocol:

1. Implement the `ILiquidationProtocol` interface for your target protocol
2. Deploy the `FlashLiquidationHook` with the appropriate protocol implementation
3. Create pools with the hook attached
4. Develop liquidation bots that monitor for liquidation opportunities and call the hook

## Security Considerations

- **Reentrancy**: The hook uses a state variable to prevent reentrancy attacks
- **Minimum Profit**: Optional parameter to ensure liquidations are profitable enough
- **Slippage Protection**: Could be extended to include more advanced slippage protection
- **Gas Optimization**: The implementation is designed to be gas-efficient

## TODO

1. **Multi-Collateral Support**: Extend to handle positions with multiple collateral types
2. **Oracle Integration**: Add price feeds to validate liquidation values
3. **Fee Distribution**: Share liquidation profits with protocol or affected LPs
4. **Partial Liquidations**: Enable liquidating only a portion of a position
5. **MEV Protection**: Add mechanisms to prevent liquidation front-running

## License

This project is licensed under MIT - see the LICENSE file for details.

## Acknowledgements

- [Uniswap V4](https://github.com/Uniswap/v4-core) - For the hook system and flash accounting
- [Foundry](https://github.com/foundry-rs/foundry) - For the development framework
