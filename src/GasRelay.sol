// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GasRelay
/// @author TheGreatAxios
/// @notice A contract that allows users to send gas (ETH) through the contract to specified receivers
/// @dev This contract provides a secure way to relay gas payments with event emission for tracking
contract GasRelay is Ownable, Pausable, ReentrancyGuard {

    /// @notice Emitted when gas is successfully relayed to a receiver
    /// @param sender The address that initiated the gas relay
    /// @param receiver The address that received the gas
    /// @param amount The amount of gas (ETH) that was relayed
    /// @param blockNumber The block number when the relay occurred
    /// @param blockTimestamp The timestamp when the relay occurred
    event GasRelayed(
        address indexed sender,
        address indexed receiver,
        uint256 amount,
        uint256 blockNumber,
        uint256 blockTimestamp
    );

    /// @notice Emitted when the contract receives ETH directly (fallback/receive)
    /// @param sender The address that sent the ETH
    /// @param amount The amount of ETH received
    event GasReceived(address indexed sender, uint256 amount);

    /// @dev Custom errors for better gas efficiency and clarity
    error InvalidReceiver();
    error InsufficientAmount();
    error TransferFailed();

    /// @notice Constructor to initialize the contract
    /// @param _owner The initial owner of the contract
    constructor(address _owner) Ownable(_owner) {}

    /// @notice Relay gas to a specified receiver
    /// @dev Forwards the sent ETH to the receiver and emits a GasRelayed event
    /// @param receiver The address to receive the gas (must not be zero address)
    function relayGas(address receiver) external payable nonReentrant whenNotPaused {
        // Input validation
        if (receiver == address(0)) {
            revert InvalidReceiver();
        }
        if (msg.value == 0) {
            revert InsufficientAmount();
        }

        // Forward the gas to the receiver
        (bool success, ) = payable(receiver).call{value: msg.value}("");
        if (!success) {
            revert TransferFailed();
        }

        // Emit event with transaction details
        // Note: tx.hash is not available during execution, but the event will be
        // included in the transaction receipt which contains the transaction hash
        emit GasRelayed(
            msg.sender,
            receiver,
            msg.value,
            block.number,
            block.timestamp
        );
    }

    /// @notice Emergency function to withdraw stuck ETH (only owner)
    /// @dev Allows the owner to recover any ETH that might be stuck in the contract
    /// @param amount The amount of ETH to withdraw
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        if (amount > address(this).balance) {
            revert InsufficientAmount();
        }

        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    /// @notice Get the current balance of the contract
    /// @return The ETH balance of the contract
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Fallback function to receive ETH
    /// @dev Emits GasReceived event when ETH is sent directly to the contract
    receive() external payable {
        emit GasReceived(msg.sender, msg.value);
    }

    /// @notice Fallback function for calls with data
    /// @dev Required for proper fallback handling
    fallback() external payable {
        emit GasReceived(msg.sender, msg.value);
    }
}
