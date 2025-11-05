import { network } from "hardhat";
const { ethers } = await network.connect();

async function runScenario(
    scenarioName: string,
    client: any,
    serverA: any,
    serverB: any,
    verifier: any,
    taskId: number,
    resultAHash: string,
    resultBHash: string,
    STAKE_AMOUNT: bigint,
    CLIENT_PAYMENT: bigint,
    TASK_HASH: string
) {
    console.log(`\n\n--- SCENARIO ${taskId}: ${scenarioName} ---`);

    // 2. Create the Task
    console.log(`\n2. Client Creating Task ${taskId} (Sending 0.2 ETH)...`);
    await verifier.connect(client).createTask(
        TASK_HASH,
        serverA.address,
        serverB.address,
        STAKE_AMOUNT,
        { value: CLIENT_PAYMENT }
    );
    console.log(`Task ${taskId} created.`);

    // 3. Servers Submit Results
    console.log("\n3. Servers Submitting Results...");

    // Server A submits result and deposit (1.0 ETH)
    await verifier.connect(serverA).submitResult(
        taskId,
        resultAHash,
        { value: STAKE_AMOUNT }
    );
    console.log("Server A submitted result.");

    // Server B submits result and deposit (1.0 ETH)
    await verifier.connect(serverB).submitResult(
        taskId,
        resultBHash,
        { value: STAKE_AMOUNT }
    );
    console.log("Server B submitted result.");

    // 4. Resolve Task
    console.log("\n4. Client Resolving Task...");
    await verifier.connect(client).resolveTask(taskId);
    console.log(`Task ${taskId} resolved.`);
}


async function main() {
    console.log("--- Starting Hardhat Task Simulation (Honest & Dishonest Paths) ---");

    // --- SETUP ---
    // 1. Get the accounts from the local node
    const [client, serverA, serverB] = await ethers.getSigners();
    
    // 2. Define and Deploy the contract
    const ReplicatedVerifier = await ethers.getContractFactory("ReplicatedVerifier");
    const verifier = await ReplicatedVerifier.deploy();
    await verifier.waitForDeployment();
    const verifierAddress = await verifier.getAddress();

    console.log(`Contract deployed to: ${verifierAddress}`);

    // Helper variables
    const STAKE_AMOUNT = ethers.parseEther("1.0");
    const CLIENT_PAYMENT = ethers.parseEther("0.2");
    const TASK_HASH = "0x123456789012345678901234567890123456789012345678901234567890abcd";
    
    // Result hashes
    const HASH_OF_CORRECT_RESULT = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    const HASH_OF_WRONG_RESULT = "0xc0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00";

    
    // =========================================================================
    //                            SCENARIO 1: HONEST PATH
    // =========================================================================
    // Expected Outcome: Results match. Servers receive STAKE + half of CLIENT_PAYMENT.
    
    await runScenario(
        "Honest Path (Results Match)",
        client,
        serverA,
        serverB,
        verifier,
        1, // Task ID
        HASH_OF_CORRECT_RESULT, // Server A submits correct hash
        HASH_OF_CORRECT_RESULT, // Server B submits correct hash
        STAKE_AMOUNT,
        CLIENT_PAYMENT,
        TASK_HASH
    );
    console.log("Status: ✅ **SUCCESS** - Servers were rewarded.");

    // =========================================================================
    //                            SCENARIO 2: DISHONEST PATH
    // =========================================================================
    // Expected Outcome: Results mismatch. Client gets partial refund. Server stakes are forfeited.
    
    await runScenario(
        "Dishonest Path (Results Mismatch)",
        client,
        serverA,
        serverB,
        verifier,
        2, // New Task ID
        HASH_OF_CORRECT_RESULT, // Server A submits correct hash
        HASH_OF_WRONG_RESULT,   // Server B submits a WRONG hash (or copied result)
        STAKE_AMOUNT,
        CLIENT_PAYMENT,
        TASK_HASH
    );
    console.log("Status: ❌ **FAILURE** - Server stakes were forfeited due to disagreement.");
    
    console.log("\n--- Full Task Simulation Complete ---");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });