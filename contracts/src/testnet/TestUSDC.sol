// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title TestUSDC
/// @notice Six-decimal collateral token for testnet, with an open faucet.
/// @dev Anyone may mint. Worthless by construction — never deploy on mainnet.
contract TestUSDC is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 100_000e6;

    error FaucetCooldown(uint256 availableAt);

    mapping(address => uint256) public lastClaim;

    function name() public pure override returns (string memory) {
        return "Test USD Coin";
    }

    function symbol() public pure override returns (string memory) {
        return "tUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Claim faucet tokens, once per address per day.
    function claim() external {
        uint256 next = lastClaim[msg.sender] + 1 days;
        if (lastClaim[msg.sender] != 0 && block.timestamp < next) revert FaucetCooldown(next);
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Unrestricted mint, for seeding pools during deployment.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
