import { network } from "hardhat";
const { ethers } = await network.connect();

async function runScenario(
  scenarioName: string,
  client: any,
  serverA: any,
  serverB: any,
  verifier: any,
  taskId: number,
  cipherSeedA: string,
  cipherSeedB: string,
  STAKE_AMOUNT: bigint,
  CLIENT_PAYMENT: bigint,
  TASK_HASH: string
) {
  console.log(`\n\n--- SCENARIO ${taskId}: ${scenarioName} ---`);

  // 2. Client Creating Task
  console.log(`\n2. Client Creating Task ${taskId} (sending payment ${CLIENT_PAYMENT} ETH)`);
  await verifier.connect(client).createTask(
    TASK_HASH,
    serverA.address,
    serverB.address,
    STAKE_AMOUNT,
    { value: CLIENT_PAYMENT }
  );
  console.log(`Task ${taskId} created.`);

  // 3. Servers submit results
  console.log("\n3. Servers submitting results...");
  const fakeCiphertext = (seed: string) => {
    const C1 = ethers.keccak256(ethers.toUtf8Bytes("C1|" + seed));
    const C2 = ethers.keccak256(ethers.toUtf8Bytes("C2|" + seed));
    const C3 = ethers.keccak256(ethers.toUtf8Bytes("C3|" + seed));
    const pk = ethers.keccak256(ethers.toUtf8Bytes("pk|" + seed));
    return { C1, C2, C3, pk };
  };

  const ctA = fakeCiphertext(cipherSeedA);
  const ctB = fakeCiphertext(cipherSeedB);

  await verifier.connect(serverA).submitResult(
    taskId,
    ctA.C1,
    ctA.C2,
    ctA.C3,
    ctA.pk,
    { value: STAKE_AMOUNT }
  );
  console.log("Server A submitted result.");

  await verifier.connect(serverB).submitResult(
    taskId,
    ctB.C1,
    ctB.C2,
    ctB.C3,
    ctB.pk,
    { value: STAKE_AMOUNT }
  );
  console.log("Server B submitted result.");

  // 4. Client resolves task
  console.log("\n4. Client Resolving Task...");
  await verifier.connect(client).resolveTask(taskId);
  console.log(`Task ${taskId} resolved.`);
}

async function main() {
  console.log("--- Starting Hardhat Task Simulation (Honest & Dishonest Paths) ---");

  const [client, serverA, serverB] = await ethers.getSigners();

  const ReplicatedVerifier = await ethers.getContractFactory("ReplicatedVerifier");
  const verifier = await ReplicatedVerifier.deploy();
  await verifier.waitForDeployment();
  console.log(`Contract deployed to: ${verifier.address}`);

  const STAKE_AMOUNT = ethers.parseEther("1.0");
  const CLIENT_PAYMENT = ethers.parseEther("0.2");
  const TASK_HASH = "0x123456789012345678901234567890123456789012345678901234567890abcd";

  // Honest scenario
  await runScenario(
    "Honest Path (Results Match)",
    client,
    serverA,
    serverB,
    verifier,
    1,
    "correct-result",
    "correct-result",
    STAKE_AMOUNT,
    CLIENT_PAYMENT,
    TASK_HASH
  );
  console.log("Status: ✅ SUCCESS - Servers were rewarded.");

  // Dishonest scenario
  await runScenario(
    "Dishonest Path (Results Mismatch)",
    client,
    serverA,
    serverB,
    verifier,
    2,
    "correct-result",
    "wrong-result",
    STAKE_AMOUNT,
    CLIENT_PAYMENT,
    TASK_HASH
  );
  console.log("Status: ❌ FAIL - Stakes were forfeited due to disagreement.");

  console.log("\n--- Full Task Simulation Complete ---");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
