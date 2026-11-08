// Install the SDK the way an outside team would — `npm pack`, then `npm install <tarball>` into a clean, empty
// project — and check that it imports, type-checks and talks to BSC Testnet.
//   npm run check:package                              (LIVE=0 to skip the network part)
//   FROM_NPM=@ibiti/epk-sdk@preview npm run check:package   (install the published package from npm instead)
import { execSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const sdkDir = process.cwd();
const work = fs.mkdtempSync(path.join(os.tmpdir(), "epk-sdk-check-"));
const sh = (cmd, cwd) => execSync(cmd, { cwd, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
const step = (s) => console.log(`\n== ${s}`);

const fromNpm = process.env.FROM_NPM;
let packed;
let tarball;
if (fromNpm) {
  step(`fetch ${fromNpm} from the npm registry`);
  packed = JSON.parse(sh(`npm pack "${fromNpm}" --json --pack-destination "${work}"`, work))[0];
  tarball = fromNpm;
} else {
  step("build, then npm pack");
  sh("npm run build", sdkDir);
  packed = JSON.parse(sh(`npm pack --json --ignore-scripts --pack-destination "${work}"`, sdkDir))[0];
  tarball = path.join(work, packed.filename);
}
console.log(`${packed.filename}: ${packed.entryCount} files, ${(packed.size / 1024).toFixed(0)} kB`);
const files = packed.files.map((f) => f.path);
for (const must of ["dist/v2/index.js", "dist/v2/index.d.ts", "dist/index.js", "dist/index.d.ts", "README.md"]) {
  if (!files.includes(must)) throw new Error(`package is missing ${must}`);
}
const leaked = files.filter((f) => /(^|\/)(\.env|test\/|examples\/|scripts\/|src\/)/.test(f));
if (leaked.length) throw new Error(`package contains files it should not: ${leaked.join(", ")}`);

step(`clean outside project: npm install ${fromNpm ?? "<tarball>"}`);
const app = path.join(work, "outside-app");
fs.mkdirSync(app);
fs.writeFileSync(path.join(app, "package.json"), JSON.stringify({ name: "outside-app", private: true, type: "module" }, null, 2));
sh(`npm install "${tarball}" typescript@5 --no-audit --no-fund --loglevel=error`, app);
console.log(`installed @ibiti/epk-sdk and its dependencies (viem) from ${fromNpm ? "the npm registry" : "the tarball"}`);

fs.writeFileSync(
  path.join(app, "check.mjs"),
  `import * as root from "@ibiti/epk-sdk";
import * as v2 from "@ibiti/epk-sdk/v2";
import { createPublicClient, http } from "viem";
import { bscTestnet } from "viem/chains";
const need = ["EPKVaultClient","EPKFactoryClient","VaultAdmin","vaultActions","EPKUpgrader","watchVault","planGuardedSwap",
  "DexGuardClient","deployDexGuard","deployThreatFeed","deployCompositeGuard","networks","explainEpkError","executeDigest","hashOperation"];
const missing = need.filter((n) => !(n in v2));
if (missing.length) throw new Error("missing exports: " + missing);
const missingRoot = need.filter((n) => !(n in root));
if (missingRoot.length) throw new Error("root entry point is missing: " + missingRoot);
// offline: the digest the live vault computes (same vector as the SDK tests)
const d = v2.executeDigest(97, "0x83c6D86019BfF5ebBb7bd955aa63878DAa60f674", { policyId: 0n, agent: "0x80ddc9C233ff9fef6e14EB1518AF0d42010798ef",
  calls: [{ target: "0xc58699856ED5c978F7bf47e46650Bdb23d9bB119", value: 0n, data: "0xa9059cbb000000000000000000000000c93ec67f65530e5997e0a54826d1de1243e204dd0000000000000000000000000000000000000000000000000de0b6b3a7640000" },
          { target: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", value: 100000000000000n, data: "0x1234" }], nonce: 7n, deadline: 1800000000n });
if (d !== "0x07550881657f463f93c1876ba53cb9c1cf829730e99f33995e2ae9e5bea8d7c4") throw new Error("digest mismatch " + d);
console.log("imports OK (" + Object.keys(root).length + " exports, same from @ibiti/epk-sdk and /v2), offline digest OK");
if (process.env.LIVE !== "0") {
  const pc = createPublicClient({ chain: bscTestnet, transport: http(process.env.BSC_TESTNET_RPC ?? "https://bsc-testnet-rpc.publicnode.com") });
  const vault = new v2.EPKVaultClient({ address: v2.networks.bscTestnet.demo.guardVault, publicClient: pc });
  const factory = new v2.EPKFactoryClient(v2.networks.bscTestnet.epk.factory, pc);
  const predicted = await factory.predictVault({ admin: "0x000000000000000000000000000000000000dEaD", guardians: ["0x0000000000000000000000000000000000000001","0x0000000000000000000000000000000000000002"], delay: 3600n, recovery: "0x0000000000000000000000000000000000000003", salt: "0x" + "11".repeat(32) });
  const guard = new v2.DexGuardClient(v2.networks.bscTestnet.demo.dexGuard, pc);
  console.log("live BSC Testnet: demo vault version " + (await vault.version()) + ", factory predicts " + predicted + ", BNB $" + Number(await guard.price(v2.networks.bscTestnet.dex.wbnb)) / 1e18);
}
`,
);

fs.writeFileSync(
  path.join(app, "check.ts"),
  `import { EPKVaultClient, vaultActions, planGuardedSwap, explainEpkError, networks, NATIVE, type Call, type VaultAction } from "@ibiti/epk-sdk/v2";
import type { PublicClient } from "viem";
declare const publicClient: PublicClient;
const actions: VaultAction[] = [vaultActions.setAsset(NATIVE, 1n, 86_400), vaultActions.addDestination("0x0000000000000000000000000000000000000001")];
const calls: Call[] = [{ target: networks.bscTestnet.dex.wbnb, value: 0n, data: "0x" }];
const vault = new EPKVaultClient({ address: networks.bscTestnet.demo.guardVault, publicClient });
export async function typed(): Promise<string> {
  const left: bigint = await vault.availableToSpend(NATIVE);
  const plan = await planGuardedSwap({ publicClient, guard: networks.bscTestnet.demo.dexGuard, router: networks.bscTestnet.dex.pancakeV2Router,
    vault: vault.address, path: [networks.bscTestnet.dex.wbnb, networks.bscTestnet.tokens.BUSD], amountIn: 1n, native: true });
  return explainEpkError("0x") + left + plan.minOut + actions.length + calls.length;
}
`,
);
fs.writeFileSync(
  path.join(app, "tsconfig.json"),
  JSON.stringify({ compilerOptions: { target: "ES2022", module: "NodeNext", moduleResolution: "NodeNext", strict: true, noEmit: true, skipLibCheck: true }, files: ["check.ts"] }, null, 2),
);

step("type-check an outside TypeScript file against the installed package");
sh("npx tsc -p tsconfig.json", app);
console.log("tsc: no errors");

step("run it");
console.log(sh("node check.mjs", app).trim());
console.log(`\nPACKAGE OK — ${packed.filename} installs, imports, type-checks${process.env.LIVE === "0" ? "" : " and reads BSC Testnet"} in a clean project (${app})`);
