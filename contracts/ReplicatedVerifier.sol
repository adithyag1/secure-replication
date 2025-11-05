// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ReplicatedVerifier
 * @notice A smart contract to manage a replicated outsourced computation
 * task between a client and two servers (Server A and Server B).
 * It uses deposits and result matching to ensure a secure outcome.
 */
contract ReplicatedVerifier {
    struct Task {
        address client;
        uint256 stakeAmount; // Required deposit from each server
        bytes32 taskHash;    // Hash of the function f() and input x
        bytes32 resultA;     // Commitment (hash) of Server A's result
        bytes32 resultB;     // Commitment (hash) of Server B's result
        address serverA;
        address serverB;
        bool isCompleted;
    }

    // Mapping to store tasks, indexed by a unique taskId
    mapping(uint256 => Task) public tasks;
    uint256 public nextTaskId = 1;

    // Events for transparency
    event TaskCreated(uint256 taskId, address client, bytes32 taskHash);
    event ResultSubmitted(uint256 taskId, address server, bytes32 resultHash);
    event TaskResolved(uint256 taskId, bool resultsMatch, address winner);

    // Error definitions (Solidity 0.8.4+)
    error InvalidServerDeposit();
    error TaskNotActive();
    error NotAuthorized();
    error TaskAlreadyCompleted();
    error ResultAlreadySubmitted();

    /**
     * @notice Client initiates a new computation task.
     * @param _taskHash A hash representing the function f() and input x.
     * @param _serverA The address of the first server.
     * @param _serverB The address of the second server.
     * @param _stakeAmount The ETH amount required as a deposit from each server.
     */
    function createTask(
        bytes32 _taskHash,
        address _serverA,
        address _serverB,
        uint256 _stakeAmount
    ) external payable returns (uint256) {
        require(msg.value > 0, "Client must send payment for the task.");

        uint256 taskId = nextTaskId++;
        tasks[taskId] = Task({
            client: msg.sender,
            stakeAmount: _stakeAmount,
            taskHash: _taskHash,
            resultA: 0,
            resultB: 0,
            serverA: _serverA,
            serverB: _serverB,
            isCompleted: false
        });

        emit TaskCreated(taskId, msg.sender, _taskHash);
        return taskId;
    }

    /**
     * @notice Servers submit their result commitment (a hash of the result).
     * The Server's deposit is sent as msg.value.
     * @param _taskId The ID of the task.
     * @param _resultHash The hash of the computation result.
     */
    function submitResult(uint256 _taskId, bytes32 _resultHash) external payable {
        Task storage task = tasks[_taskId];

        if (task.client == address(0) || task.isCompleted) revert TaskNotActive();

        if (msg.value != task.stakeAmount) revert InvalidServerDeposit();

        // Server A logic
        if (msg.sender == task.serverA) {
            if (task.resultA != 0) revert ResultAlreadySubmitted();
            task.resultA = _resultHash;
        // Server B logic
        } else if (msg.sender == task.serverB) {
            if (task.resultB != 0) revert ResultAlreadySubmitted();
            task.resultB = _resultHash;
        } else {
            revert NotAuthorized();
        }

        emit ResultSubmitted(_taskId, msg.sender, _resultHash);
    }

    /**
     * @notice The client calls this function once both servers have submitted results.
     * This is where the actual result comparison (the verification) happens.
     * @dev In a real system, the client would submit the *actual* result, not just a hash,
     * to prove the computation. For this implementation, we simply check the submitted hashes.
     * @param _taskId The ID of the task.
     */
    function resolveTask(uint256 _taskId) external {
        Task storage task = tasks[_taskId];
        if (msg.sender != task.client) revert NotAuthorized();
        if (task.resultA == 0 || task.resultB == 0) revert("Results not fully submitted.");
        if (task.isCompleted) revert TaskAlreadyCompleted();

        task.isCompleted = true;

        // **The Replication Verification Logic:**
        if (task.resultA == task.resultB) {
            // Case 1: Results Match (Honest path or successful collusion)
            // Both servers get their stake back + payment from client (msg.value)
            uint256 clientPayment = address(this).balance - (task.stakeAmount * 2);
            uint256 serverReward = clientPayment / 2;

            // Pay Server A: Deposit + Half of Client's Payment
            (bool successA, ) = task.serverA.call{value: task.stakeAmount + serverReward}("");
            require(successA, "Transfer to Server A failed.");

            // Pay Server B: Deposit + Half of Client's Payment
            (bool successB, ) = task.serverB.call{value: task.stakeAmount + serverReward}("");
            require(successB, "Transfer to Server B failed.");
            
            // The remaining small amount (if clientPayment is odd) goes to the client.
            uint256 remaining = address(this).balance;
            (bool successClient, ) = task.client.call{value: remaining}("");
            require(successClient, "Transfer remaining to Client failed.");

            emit TaskResolved(_taskId, true, address(0)); // Winner is N/A
        } else {
            // Case 2: Results Mismatch (Copy attack or honest error/dispute)
            // The contract cannot determine the correct result without a complex
            // challenge-response protocol (like a Merkle tree proof).
            // In the spirit of the "Prisoner's Contract" (economic incentive):
            // The client must initiate a separate process to prove which is correct,
            // or the payment is forfeited as a penalty.
            // **For simplicity, we return the client's original payment and forfeit server stakes.**
            
            // Refund the client's payment (original msg.value)
            uint256 clientRefund = address(this).balance - (task.stakeAmount * 2);
            (bool successClient, ) = task.client.call{value: clientRefund}("");
            require(successClient, "Client refund failed.");

            // Server Stakes are locked/lost, acting as a penalty for the servers.
            // In a real system, the honest server would receive the dishonest one's stake.
            // Here, for simplicity, they are forfeit to the contract/network (not implemented).

            emit TaskResolved(_taskId, false, address(0));
        }
    }
}