#!/bin/bash

# This script installs necessary dependencies for the Uniswap V4 Flash Liquidation Hook

# Output colorization
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up dependencies for Uniswap V4 Flash Liquidation Hook...${NC}"

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo -e "${RED}Foundry (forge) not found. Please install Foundry first:${NC}"
    echo "curl -L https://foundry.paradigm.xyz | bash"
    echo "foundryup"
    exit 1
fi

# Install Forge dependencies
echo -e "${YELLOW}Installing Forge dependencies...${NC}"
forge install Uniswap/v4-core --no-commit -- --branch main
forge install Uniswap/v4-periphery --no-commit -- --branch main
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install foundry-rs/forge-std --no-commit

# Build the project
echo -e "${YELLOW}Building the project...${NC}"
forge build

echo -e "${GREEN}Setup complete! You can now start developing with the Uniswap V4 Flash Liquidation Hook.${NC}"
