// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ReplicatedVerifier {
    struct Task {
        address client;
        uint256 stakeAmount;
        uint256 clientPayment;
        bytes32 taskHash;
        address[] servers;
        bool isCompleted;
    }

    struct ServerSubmission {
        bytes32 commitment;
        bool committed;
        bytes result;      
        bytes nonce;  
        bool revealed;
    }

    mapping(uint256 => Task) public tasks;
    mapping(uint256 => mapping(address => ServerSubmission)) public submissions;
    mapping(uint256 => mapping(bytes32 => uint256)) public taskVoteCounts;
    uint256 public nextTaskId = 1;

    event TaskCreated(uint256 indexed taskId, address client, bytes32 taskHash, uint256 numServers, uint256 stakeAmount);
    event ResultCommitted(uint256 indexed taskId, address server, bytes32 commitment);
    event ResultRevealed(uint256 indexed taskId, address server);
    event TaskResolved(uint256 indexed taskId, bool majorityReached, bytes32 majorityResultAddress, uint256 majorityCount);
    event ServerReward(uint256 indexed taskId, address server, uint256 amount);
    event ServerForfeit(uint256 indexed taskId, address server, uint256 stakeAmount);

    error InvalidServerDeposit();
    error TaskNotActive();
    error NotAuthorized();
    error TaskAlreadyCompleted();
    error AlreadyCommitted();
    error NotCommitted();
    error AlreadyRevealed();
    error CommitmentMismatch();
    error NotAllRevealed();
    error TransferFailed(address recipient);
    error InsufficientServers();

    function computeCommitment(bytes memory _result, bytes memory _nonce, address _server) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_result, _nonce, _server));
    }


    function createTask(
        bytes32 _taskHash,
        address[] calldata _servers,
        uint256 _stakeAmount
    ) external payable returns (uint256) {
        require(msg.value > 0, "Client must send payment for the task.");
        require(_servers.length >= 3, "RBOC requires at least 3 servers for majority vote.");

        uint256 taskId = nextTaskId++;
        tasks[taskId] = Task({
            client: msg.sender,
            stakeAmount: _stakeAmount,
            clientPayment: msg.value,
            taskHash: _taskHash,
            servers: _servers,
            isCompleted: false
        });

        emit TaskCreated(taskId, msg.sender, _taskHash, _servers.length, _stakeAmount);
        return taskId;
    }

    function commitResult(
        uint256 _taskId,
        bytes32 _commitment 
    ) external payable {
        Task storage t = tasks[_taskId];
        address sender = msg.sender;

        if (t.client == address(0) || t.isCompleted) revert TaskNotActive();
        if (msg.value != t.stakeAmount) revert InvalidServerDeposit();
        
        bool isAuthorized = false;
        for (uint i = 0; i < t.servers.length; i++) {
            if (t.servers[i] == sender) {
                isAuthorized = true;
                break;
            }
        }
        require(isAuthorized, "Not authorized server");

        ServerSubmission storage sub = submissions[_taskId][sender];
        if (sub.committed) revert AlreadyCommitted();

        sub.commitment = _commitment;
        sub.committed = true;

        emit ResultCommitted(_taskId, sender, _commitment);
    }

    function revealResult(
        uint256 _taskId,
        bytes calldata _result,
        bytes calldata _nonce
    ) external {
        Task storage t = tasks[_taskId];
        address sender = msg.sender;

        if (t.isCompleted) revert TaskAlreadyCompleted();
        
        bool isAuthorized = false;
        for (uint i = 0; i < t.servers.length; i++) {
            if (t.servers[i] == sender) {
                isAuthorized = true;
                break;
            }
        }
        require(isAuthorized, "Not authorized server");


        ServerSubmission storage sub = submissions[_taskId][sender];
        if (!sub.committed) revert NotCommitted();
        if (sub.revealed) revert AlreadyRevealed();

        bytes32 calculatedCommitment = computeCommitment(_result, _nonce, sender);
        if (calculatedCommitment != sub.commitment) revert CommitmentMismatch();

        sub.result = _result;
        sub.nonce = _nonce;
        sub.revealed = true;

        emit ResultRevealed(_taskId, sender);
    }

    function resolveTask(uint256 _taskId) external {
        Task storage t = tasks[_taskId];
        if (msg.sender != t.client) revert NotAuthorized();
        if (t.isCompleted) revert TaskAlreadyCompleted();
        
        uint256 totalServers = t.servers.length;
        require(totalServers >= 3, "Insufficient servers for majority voting.");

        uint256 committedServers = 0;
        bytes32 maxVoteHash = 0x0;
        uint256 maxVoteCount = 0;

        for (uint i = 0; i < totalServers; i++) {
            address server = t.servers[i];
            ServerSubmission storage sub = submissions[_taskId][server];
            
            if (sub.revealed) { 
                committedServers++;
                bytes32 resultHash = keccak256(sub.result);
                taskVoteCounts[_taskId][resultHash]++;
                
                if (taskVoteCounts[_taskId][resultHash] > maxVoteCount) {
                    maxVoteCount = taskVoteCounts[_taskId][resultHash];
                    maxVoteHash = resultHash;
                }
            }
        }
        
        t.isCompleted = true;
        
        bool majorityReached = (maxVoteCount > totalServers / 2);     
        uint256 clientPayment = t.clientPayment;

        if (majorityReached) {
            uint256 majorityServers = maxVoteCount;
            uint256 serverReward = clientPayment / majorityServers; 
            
            for (uint i = 0; i < totalServers; i++) {
                address server = t.servers[i];
                ServerSubmission storage sub = submissions[_taskId][server];
                
                if (sub.revealed && keccak256(sub.result) == maxVoteHash) {
                    uint256 payAmount = t.stakeAmount + serverReward;
                    (bool success, ) = server.call{ value: payAmount }("");
                    if (!success) revert TransferFailed(server);
                    emit ServerReward(_taskId, server, payAmount);
                } else {
                    emit ServerForfeit(_taskId, server, t.stakeAmount);
                }
            }
            
            uint256 remaining = address(this).balance;
            (bool successC, ) = t.client.call{ value: remaining }("");
            if (!successC) revert TransferFailed(t.client);
            
            emit TaskResolved(_taskId, true, maxVoteHash, maxVoteCount);

        } else {
            
            uint256 clientRefund = clientPayment; 
            (bool successC, ) = t.client.call{ value: clientRefund }("");
            if (!successC) revert TransferFailed(t.client);
            
            for (uint i = 0; i < totalServers; i++) {
                emit ServerForfeit(_taskId, t.servers[i], t.stakeAmount);
            }
            
            emit TaskResolved(_taskId, false, 0x0, maxVoteCount);
        }
    }
}