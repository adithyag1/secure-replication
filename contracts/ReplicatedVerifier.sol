// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ReplicatedVerifier {
    struct Ciphertext {
        bytes C1;
        bytes C2;
        bytes C3;
        bytes pubKeyId;
        address submitter;
        bool exists;
    }

    struct Task {
        address client;
        uint256 stakeAmount;
        bytes32 taskHash;
        address serverA;
        address serverB;
        bool isCompleted;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => mapping(address => Ciphertext)) public submissions;
    uint256 public nextTaskId = 1;

    event TaskCreated(uint256 indexed taskId, address client, bytes32 taskHash, address serverA, address serverB, uint256 stakeAmount);
    event ResultSubmitted(uint256 indexed taskId, address server, bytes32 testHash);
    event CiphertextSelected(uint256 indexed taskId, bytes C1, bytes C2, bytes C3, bytes pubKeyId);
    event CiphertextMismatch(uint256 indexed taskId);
    event TaskResolved(uint256 indexed taskId, bool resultsMatch);

    error InvalidServerDeposit();
    error TaskNotActive();
    error NotAuthorized();
    error TaskAlreadyCompleted();
    error ResultsNotSubmitted();

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
            serverA: _serverA,
            serverB: _serverB,
            isCompleted: false
        });

        emit TaskCreated(taskId, msg.sender, _taskHash, _serverA, _serverB, _stakeAmount);
        return taskId;
    }

    function computeTestHash(bytes memory C1, bytes memory C2, bytes memory C3, bytes memory pubKeyId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(C1, C2, C3, pubKeyId));
    }

    function submitResult(
        uint256 _taskId,
        bytes calldata C1,
        bytes calldata C2,
        bytes calldata C3,
        bytes calldata pubKeyId
    ) external payable {
        Task storage t = tasks[_taskId];
        if (t.client == address(0) || t.isCompleted) revert TaskNotActive();
        if (msg.value != t.stakeAmount) revert InvalidServerDeposit();

        address sender = msg.sender;
        require(sender == t.serverA || sender == t.serverB, "Not authorized server");

        Ciphertext storage ct = submissions[_taskId][sender];
        require(!ct.exists, "Result already submitted");

        submissions[_taskId][sender] = Ciphertext({
            C1: C1,
            C2: C2,
            C3: C3,
            pubKeyId: pubKeyId,
            submitter: sender,
            exists: true
        });

        bytes32 testHash = computeTestHash(C1, C2, C3, pubKeyId);
        emit ResultSubmitted(_taskId, sender, testHash);
    }

    function resolveTask(uint256 _taskId) external {
        Task storage t = tasks[_taskId];
        if (msg.sender != t.client) revert NotAuthorized();
        if (t.isCompleted) revert TaskAlreadyCompleted();

        Ciphertext storage a = submissions[_taskId][t.serverA];
        Ciphertext storage b = submissions[_taskId][t.serverB];
        if (!a.exists || !b.exists) revert ResultsNotSubmitted();

        bytes32 ha = computeTestHash(a.C1, a.C2, a.C3, a.pubKeyId);
        bytes32 hb = computeTestHash(b.C1, b.C2, b.C3, b.pubKeyId);

        t.isCompleted = true;

        if (ha == hb) {
            // Results match: both servers rewarded + return ciphertext
            emit CiphertextSelected(_taskId, a.C1, a.C2, a.C3, a.pubKeyId);
            // compute client payment available in contract
            uint256 clientPayment = address(this).balance - (t.stakeAmount * 2);
            uint256 serverReward = clientPayment / 2;
            // Pay serverA
            (bool successA, ) = t.serverA.call{ value: t.stakeAmount + serverReward }("");
            require(successA, "Transfer to Server A failed");
            // Pay serverB
            (bool successB, ) = t.serverB.call{ value: t.stakeAmount + serverReward }("");
            require(successB, "Transfer to Server B failed");
            // Remaining (if any) returns to client
            uint256 remaining = address(this).balance;
            (bool successC, ) = t.client.call{ value: remaining }("");
            require(successC, "Transfer remaining to client failed");
            emit TaskResolved(_taskId, true);
        } else {
            // Results mismatch: refund client, forfeit server stakes
            emit CiphertextMismatch(_taskId);
            uint256 clientRefund = address(this).balance - (t.stakeAmount * 2);
            (bool successC, ) = t.client.call{ value: clientRefund }("");
            require(successC, "Client refund failed");
            // Server stakes stay in contract (forfeit)
            emit TaskResolved(_taskId, false);
        }
    }
}
