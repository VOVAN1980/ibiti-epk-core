// Offline tests for the SDK v2 upgrade and watch helpers, against values from the live 5-minute upgrade on
// BSC Testnet (vault 0x9248fb523dE74420b56c733fB9FA14917A054FEb, release 2.1.1 0xf4771af7…).
import { test } from "node:test";
import assert from "node:assert/strict";
import { encodeFunctionData, keccak256, toBytes } from "viem";

import {
  upgradeOperationData,
  hashOperation,
  describeScheduledCall,
  scheduledCallLabels,
  epkVaultAbi,
} from "../../src/v2/index.js";

const RELEASE_211 = "0xf4771af722E0380CE241d38E49cD0f8d2EEa90ED";

test("upgradeOperationData equals the vault's own upgradeOperationData", () => {
  assert.equal(
    upgradeOperationData(RELEASE_211),
    "0x4f1ef286000000000000000000000000f4771af722e0380ce241d38e49cd0f8d2eea90ed000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000048fd3ab8000000000000000000000000000000000000000000000000000000000",
  );
});

test("the operation id equals the one the testnet vault scheduled", () => {
  const salt = keccak256(toBytes("EPK fast test-network upgrade to 2.1.1"));
  assert.equal(
    hashOperation(upgradeOperationData(RELEASE_211), salt),
    "0x5cab323713aa0fe68e54c8da6b55b2e10470f39052cff1e6d9f027efd0a675c2",
  );
});

test("scheduled calls are decoded and labelled for alerts", () => {
  const up = describeScheduledCall(upgradeOperationData(RELEASE_211));
  assert.equal(up?.functionName, "upgradeToAndCall");
  assert.equal(scheduledCallLabels[up!.functionName], "UPGRADE the vault's code");

  const add = describeScheduledCall(
    encodeFunctionData({ abi: epkVaultAbi, functionName: "addDestination", args: ["0x000000000000000000000000000000000000bad1"] }),
  );
  assert.equal(add?.functionName, "addDestination");
  assert.equal(scheduledCallLabels.addDestination, "allow payments to a new address");

  const guard = describeScheduledCall(
    encodeFunctionData({ abi: epkVaultAbi, functionName: "setEnvelopeGuard", args: [1n, "0x0000000000000000000000000000000000000000"] }),
  );
  assert.equal(guard?.functionName, "setEnvelopeGuard");
  assert.deepEqual(guard?.args, [1n, "0x0000000000000000000000000000000000000000"]);

  assert.equal(describeScheduledCall("0xdeadbeef"), undefined);
});
