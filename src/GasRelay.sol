// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GasRelay
/// @author TheGreatAxios
/// @notice A contract that allows users to send gas (ETH) through the contract to specified receivers with batch payment capabilities
/// @dev This contract provides a secure way to relay gas payments with event emission for tracking, distribution tracking, and batch processing
contract GasRelay is Ownable, Pausable, ReentrancyGuard {

    /// @notice Structure to track payment distributions per wallet
    struct Distribution {
        uint256 totalReceived;    // Total amount received by this wallet
        uint256 totalPaid;        // Total amount already paid out to this wallet
        uint256 pendingAmount;    // Amount currently pending settlement
        uint256 lastPaymentBlock; // Block number of last payment
        uint256 transactionCount; // Number of transactions involving this wallet
    }

    /// @notice Structure to track transaction details
    struct TransactionRecord {
        bytes32 txHash;           // Transaction hash (from transaction receipt)
        address sender;           // Address that initiated the transaction
        address receiver;         // Address that received the payment
        uint256 amount;           // Amount transferred
        uint256 blockNumber;      // Block number when transaction occurred
        uint256 timestamp;        // Timestamp when transaction occurred
        bool settled;             // Whether this transaction has been settled
    }

    /// @notice Mapping of wallet addresses to their distribution records
    mapping(address => Distribution) public distributions;

    /// @notice Array to store all transaction records
    TransactionRecord[] public transactionHistory;

    /// @notice Mapping to track transaction indices for quick lookup
    mapping(bytes32 => uint256) public transactionIndex;

    /// @notice Mapping to track pending batch settlements
    mapping(address => uint256) public pendingSettlements;

    /// @notice Total amount currently pending settlement across all wallets
    uint256 public totalPendingSettlements;

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

    /// @notice Emitted when a transaction is recorded with its hash
    /// @param txHash The transaction hash
    /// @param sender The address that initiated the transaction
    /// @param receiver The address that received the payment
    /// @param amount The amount transferred
    event TransactionRecorded(
        bytes32 indexed txHash,
        address indexed sender,
        address indexed receiver,
        uint256 amount
    );

    /// @notice Emitted when distributions are updated for a wallet
    /// @param wallet The wallet address whose distribution was updated
    /// @param totalReceived New total received amount
    /// @param pendingAmount New pending amount
    event DistributionUpdated(
        address indexed wallet,
        uint256 totalReceived,
        uint256 pendingAmount
    );

    /// @notice Emitted when a batch settlement is executed
    /// @param wallets Array of wallet addresses that were settled
    /// @param amounts Array of amounts paid to each wallet
    /// @param totalAmount Total amount paid in the batch
    event BatchSettlementExecuted(
        address[] wallets,
        uint256[] amounts,
        uint256 totalAmount
    );

    /// @notice Emitted when the contract receives ETH directly (fallback/receive)
    /// @param sender The address that sent the ETH
    /// @param amount The amount of ETH received
    event GasReceived(address indexed sender, uint256 amount);

    /// @dev Custom errors for better gas efficiency and clarity
    error InvalidReceiver();
    error InsufficientAmount();
    error TransferFailed();
    error InvalidArrayLength();
    error InsufficientContractBalance();
    error NoPendingSettlement();

    /// @notice Constructor to initialize the contract
    /// @param _owner The initial owner of the contract
    constructor(address _owner) Ownable(_owner) {}

    /// @notice Relay gas to a specified receiver
    /// @dev Forwards the sent ETH to the receiver, records the transaction, and updates distributions
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

        // Record transaction (tx.hash will be set by external caller after transaction mining)
        _recordTransaction(msg.sender, receiver, msg.value);

        // Update distribution tracking
        _updateDistribution(receiver, msg.value);

        // Emit event with transaction details
        emit GasRelayed(
            msg.sender,
            receiver,
            msg.value,
            block.number,
            block.timestamp
        );
    }

    /// @notice Relay gas to a specified receiver and immediately settle (direct payment)
    /// @dev Forwards the sent ETH to the receiver and marks transaction as settled
    /// @param receiver The address to receive the gas (must not be zero address)
    function relayGasAndSettle(address receiver) external payable nonReentrant whenNotPaused {
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

        // Record transaction as settled (tx.hash will be set by external caller)
        _recordTransactionSettled(msg.sender, receiver, msg.value);

        // Update distribution and mark as paid
        _updateDistributionAndSettle(receiver, msg.value);

        // Emit event with transaction details
        emit GasRelayed(
            msg.sender,
            receiver,
            msg.value,
            block.number,
            block.timestamp
        );
    }

    /// @notice Record transaction hash for a previously executed transaction
    /// @dev This function should be called after transaction mining to associate tx hash
    /// @param index The index of the transaction in the history array
    /// @param txHash The transaction hash from the blockchain
    function recordTransactionHash(uint256 index, bytes32 txHash) external onlyOwner {
        require(index < transactionHistory.length, "Invalid transaction index");

        TransactionRecord storage record = transactionHistory[index];
        require(record.txHash == bytes32(0), "Transaction hash already recorded");

        record.txHash = txHash;
        transactionIndex[txHash] = index;

        emit TransactionRecorded(
            txHash,
            record.sender,
            record.receiver,
            record.amount
        );
    }

    /// @notice Execute batch settlement for multiple wallets
    /// @dev Pays out pending amounts to multiple wallets in a single transaction
    /// @param wallets Array of wallet addresses to settle
    /// @param amounts Array of amounts to pay each wallet
    function executeBatchSettlement(
        address[] calldata wallets,
        uint256[] calldata amounts
    ) external onlyOwner nonReentrant whenNotPaused {
        if (wallets.length != amounts.length) {
            revert InvalidArrayLength();
        }
        if (wallets.length == 0) {
            revert InvalidArrayLength();
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }

        if (totalAmount > address(this).balance) {
            revert InsufficientContractBalance();
        }

        // Execute payments
        for (uint256 i = 0; i < wallets.length; i++) {
            address wallet = wallets[i];
            uint256 amount = amounts[i];

            if (amount > 0) {
                // Update distribution records
                Distribution storage dist = distributions[wallet];
                dist.totalPaid += amount;
                dist.pendingAmount -= amount;
                dist.lastPaymentBlock = block.number;

                // Transfer funds
                (bool success, ) = payable(wallet).call{value: amount}("");
                if (!success) {
                    revert TransferFailed();
                }

                // Mark transactions as settled
                _markTransactionsAsSettled(wallet, amount);

                emit DistributionUpdated(wallet, dist.totalReceived, dist.pendingAmount);
            }
        }

        // Update total pending settlements
        totalPendingSettlements -= totalAmount;

        emit BatchSettlementExecuted(wallets, amounts, totalAmount);
    }

    /// @notice Add amount to pending settlements for batch processing
    /// @dev Increases the pending settlement amount for a wallet
    /// @param wallet The wallet address to add pending settlement for
    /// @param amount The amount to add to pending settlements
    function addPendingSettlement(address wallet, uint256 amount) external onlyOwner {
        if (wallet == address(0)) {
            revert InvalidReceiver();
        }

        pendingSettlements[wallet] += amount;
        totalPendingSettlements += amount;

        Distribution storage dist = distributions[wallet];
        dist.pendingAmount += amount;

        emit DistributionUpdated(wallet, dist.totalReceived, dist.pendingAmount);
    }

    /// @notice Get pending settlement amount for a wallet
    /// @param wallet The wallet address to query
    /// @return The pending settlement amount
    function getPendingSettlement(address wallet) external view returns (uint256) {
        return pendingSettlements[wallet];
    }

    /// @notice Get transaction details by index
    /// @param index The index in the transaction history array
    /// @return The transaction record
    function getTransaction(uint256 index) external view returns (TransactionRecord memory) {
        require(index < transactionHistory.length, "Invalid transaction index");
        return transactionHistory[index];
    }

    /// @notice Get total number of transactions recorded
    /// @return The total number of transactions
    function getTransactionCount() external view returns (uint256) {
        return transactionHistory.length;
    }

    /// @notice Get distribution details for a wallet
    /// @param wallet The wallet address to query
    /// @return The distribution record
    function getDistribution(address wallet) external view returns (Distribution memory) {
        return distributions[wallet];
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

    // ============================================================================
    // INTERNAL HELPER FUNCTIONS
    // ============================================================================

    /// @dev Record a transaction in the history (without marking as settled)
    /// @param sender The sender address
    /// @param receiver The receiver address
    /// @param amount The amount transferred
    function _recordTransaction(address sender, address receiver, uint256 amount) internal {
        transactionHistory.push(TransactionRecord({
            txHash: bytes32(0), // Will be set later via recordTransactionHash
            sender: sender,
            receiver: receiver,
            amount: amount,
            blockNumber: block.number,
            timestamp: block.timestamp,
            settled: false
        }));
    }

    /// @dev Record a transaction in the history and mark as settled
    /// @param sender The sender address
    /// @param receiver The receiver address
    /// @param amount The amount transferred
    function _recordTransactionSettled(address sender, address receiver, uint256 amount) internal {
        transactionHistory.push(TransactionRecord({
            txHash: bytes32(0), // Will be set later via recordTransactionHash
            sender: sender,
            receiver: receiver,
            amount: amount,
            blockNumber: block.number,
            timestamp: block.timestamp,
            settled: true
        }));
    }

    /// @dev Update distribution tracking for a wallet
    /// @param wallet The wallet address
    /// @param amount The amount to add to received total
    function _updateDistribution(address wallet, uint256 amount) internal {
        Distribution storage dist = distributions[wallet];
        dist.totalReceived += amount;
        dist.pendingAmount += amount;
        dist.transactionCount += 1;
        dist.lastPaymentBlock = block.number;

        totalPendingSettlements += amount;

        emit DistributionUpdated(wallet, dist.totalReceived, dist.pendingAmount);
    }

    /// @dev Update distribution tracking and mark amount as settled
    /// @param wallet The wallet address
    /// @param amount The amount to add to received total and mark as paid
    function _updateDistributionAndSettle(address wallet, uint256 amount) internal {
        Distribution storage dist = distributions[wallet];
        dist.totalReceived += amount;
        dist.totalPaid += amount;
        dist.transactionCount += 1;
        dist.lastPaymentBlock = block.number;
        // pendingAmount doesn't increase since it's settled immediately

        emit DistributionUpdated(wallet, dist.totalReceived, dist.pendingAmount);
    }

    /// @dev Mark transactions as settled for a wallet up to the specified amount
    /// @param wallet The wallet address
    /// @param amount The total amount to mark as settled
    function _markTransactionsAsSettled(address wallet, uint256 amount) internal {
        uint256 remainingToSettle = amount;

        // Iterate through transaction history and mark unsettled transactions as settled
        for (uint256 i = transactionHistory.length; i > 0 && remainingToSettle > 0; i--) {
            TransactionRecord storage record = transactionHistory[i - 1];

            if (record.receiver == wallet && !record.settled && record.amount <= remainingToSettle) {
                record.settled = true;
                remainingToSettle -= record.amount;
            }
        }
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
