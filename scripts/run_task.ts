import { network } from "hardhat";
const { ethers } = await network.connect();

const generateSubmission = (result: string, serverAddress: string) => {
  const resultBytes = ethers.toUtf8Bytes("RESULT|" + result);
  const nonceBytes = ethers.toUtf8Bytes("NONCE|" + serverAddress);
  
  const commitment = ethers.keccak256(
    ethers.concat([
      resultBytes,
      nonceBytes,
      serverAddress
    ])
  );

  return { result: resultBytes, nonce: nonceBytes, commitment: commitment };
};

async function runScenario(
  scenarioName: string,
  client: any,
  servers: any[],
  verifier: any,
  taskId: number,
  resultSeeds: string[],
  STAKE_AMOUNT: bigint,
  CLIENT_PAYMENT: bigint,
  TASK_HASH: string
): Promise<boolean> { 
  console.log(`\n\n--- SCENARIO ${taskId}: ${scenarioName} (N=${servers.length}) ---`);
  
  const serverAddresses = servers.map(s => s.address);

  const submissionsData = servers.map((server, i) => 
    generateSubmission(resultSeeds[i], server.address)
  );

  console.log(`\n2. Client Creating Task ${taskId} (sending payment ${CLIENT_PAYMENT} ETH)`);
  
  await verifier.connect(client).createTask(
    TASK_HASH,
    serverAddresses,
    STAKE_AMOUNT,
    { value: CLIENT_PAYMENT }
  );
  console.log(`Task ${taskId} created for ${servers.length} servers.`);

  console.log("\n3. Servers committing results (staking)...");
  
  for (let i = 0; i < servers.length; i++) {
    await verifier.connect(servers[i]).commitResult(
      taskId,
      submissionsData[i].commitment,
      { value: STAKE_AMOUNT }
    );
  }
  console.log("All servers committed.");

  console.log("\n4. Servers revealing results (showing plaintext)...");
  
  for (let i = 0; i < servers.length; i++) {
    await verifier.connect(servers[i]).revealResult(
      taskId,
      submissionsData[i].result,
      submissionsData[i].nonce
    );
  }
  console.log("All servers revealed.");


  console.log("\n5. Client Resolving Task and checking result...");
  
  const tx = await verifier.connect(client).resolveTask(taskId);
  const receipt = await tx.wait();

  let majorityReached = false;
  let foundEvent = false;
  let majorityCount = 0;

  if (receipt && receipt.logs) {
    for (const log of receipt.logs) {
      try {
        const parsedLog = verifier.interface.parseLog(log);
        if (parsedLog && parsedLog.name === "TaskResolved") {
          majorityReached = parsedLog.args[1]; 
          majorityCount = parsedLog.args[3]; 
          foundEvent = true;
          break;
        }
      } catch (e) {
        // Ignore logs
      }
    }
  }

  if (!foundEvent) {
    throw new Error(`TaskResolved event not found for Task ${taskId}`);
  }

  console.log(`Task ${taskId} resolved. Final Vote Count: ${majorityCount}/${servers.length}.`);
  
  return majorityReached; 
}

async function main() {
  console.log("--- Starting Hardhat N-Server Commit-Reveal Simulation ---");
  
  const signers = await ethers.getSigners();
  const client = signers[0];
  const servers = signers.slice(1, 6)
  const N = servers.length;

  const ReplicatedVerifier = await ethers.getContractFactory("ReplicatedVerifier");
  const verifier = await ReplicatedVerifier.deploy();
  await verifier.waitForDeployment();
  const deployedAddress = await verifier.getAddress();
  console.log(`Contract deployed to: ${deployedAddress}`);

  const STAKE_AMOUNT = ethers.parseEther("1.0");
  const CLIENT_PAYMENT = ethers.parseEther("0.2");
  const TASK_HASH = "0x123456789012345678901234567890123456789012345678901234567890abcd";

  // --- Scenario 1: Full Match (5/5) ---
  const results1 = ["correct", "correct", "correct", "correct", "correct"];
  const match1 = await runScenario(
    "1. Full Match (5/5)",
    client, servers, verifier, 1, results1,
    STAKE_AMOUNT, CLIENT_PAYMENT, TASK_HASH
  );
  if (match1) {
    console.log("Result: ✅ SUCCESS - All servers were rewarded.");
  } else {
    console.log("Result: 🚨 ERROR - Expected match, but contract reported failure.");
  }


  // --- Scenario 2: Majority Match (3/5) ---
  const results2 = ["correct", "correct", "correct", "wrong_A", "wrong_B"];
  const match2 = await runScenario(
    "2. Majority Match (3/5)",
    client, servers, verifier, 2, results2,
    STAKE_AMOUNT, CLIENT_PAYMENT, TASK_HASH
  );
  if (match2) {
    console.log("Result: ✅ SUCCESS - Majority (3) rewarded; Minority (2) forfeited stakes.");
  } else {
    console.log("Result: ❌ FAIL - Expected majority, but contract reported no majority.");
  }


  // --- Scenario 3: No Majority (2/2/1 Split) ---
  const results3 = ["correct_A", "correct_A", "correct_B", "correct_B", "wrong_C"];
  const match3 = await runScenario(
    "3. No Majority (2/2/1)",
    client, servers, verifier, 3, results3,
    STAKE_AMOUNT, CLIENT_PAYMENT, TASK_HASH
  );
  if (match3) {
    console.log("Result: 🚨 ERROR - Expected no majority, but contract reported success.");
  } else {
    console.log("Result: ❌ FAIL - No majority reached. All stakes were forfeited.");
  }

  console.log("\n--- Full N-Server Simulation Complete ---");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });