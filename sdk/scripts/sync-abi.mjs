import fs from "node:fs";
import path from "node:path";

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

const ROOT = path.resolve(process.cwd(), ".."); // repo root
const OUT = path.join(ROOT, "out");

// Foundry artifact paths (стабильно для Foundry):
const artifacts = [
  { name: "EPKernel", in: path.join(OUT, "EPKernel.sol", "EPKernel.json") },
  { name: "CompositeValidator", in: path.join(OUT, "CompositeValidator.sol", "CompositeValidator.json") },
  { name: "TargetSelectorGuard", in: path.join(OUT, "TargetSelectorGuard.sol", "TargetSelectorGuard.json") },
  { name: "SpendLimitValidator", in: path.join(OUT, "SpendLimitValidator.sol", "SpendLimitValidator.json") },
  { name: "ThreatFeedBlocklistValidator", in: path.join(OUT, "ThreatFeedBlocklistValidator.sol", "ThreatFeedBlocklistValidator.json") }
];

const outDir = path.join(process.cwd(), "src", "abi");
ensureDir(outDir);

for (const a of artifacts) {
  if (!fs.existsSync(a.in)) {
    console.error(`Missing artifact: ${a.in}`);
    process.exitCode = 1;
    continue;
  }
  const j = readJson(a.in);
  if (!j.abi) {
    console.error(`No ABI in: ${a.in}`);
    process.exitCode = 1;
    continue;
  }

  const target = path.join(outDir, `${a.name}.abi.json`);
  fs.writeFileSync(target, JSON.stringify(j.abi, null, 2));
  console.log(`OK: ${a.name} -> ${path.relative(process.cwd(), target)}`);
}

if (!process.exitCode) {
  console.log("ABI sync complete.");
}
