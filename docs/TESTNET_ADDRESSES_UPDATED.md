# BSC Testnet Deployment (Chain 97)

This page is the source of truth for **verified contracts**, **deployment tx hashes**, and **on-chain smoke test evidence**.

---

## Contracts (BscScan Verified)

- **EPKernel**: `0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82`
  - BscScan (Verified): https://testnet.bscscan.com/address/0x0beeb0083c576b54db99b4abef0dcbc5bc70bf82#code

- **CompositeValidator**: `0x7c6389Bdc31CEE333A98c3e840B012B480de1c11`
  - BscScan (Verified): https://testnet.bscscan.com/address/0x7c6389bdc31cee333a98c3e840b012b480de1c11#code

- **TargetSelectorGuard**: `0x05410A7c9a0835F641D5f85D83b6Ea9771F1114E`
  - BscScan (Verified): https://testnet.bscscan.com/address/0x05410a7c9a0835f641d5f85d83b6ea9771f1114e#code

- **SpendLimitValidator**: `0x7Ec6A4F68D2071C21c473987C25586F85ddE1130`
  - BscScan (Verified): https://testnet.bscscan.com/address/0x7ec6a4f68d2071c21c473987c25586f85dde1130#code

- **ThreatFeedBlocklistValidator (no-op)**: `0xbfF42c0635987084F7923a1F9E71064683b09048`
  - BscScan (Verified): https://testnet.bscscan.com/address/0xbff42c0635987084f7923a1f9e71064683b09048#code

---

## Deployment transactions (core)

- Kernel deploy: https://testnet.bscscan.com/tx/0x561d1b9e73dd40b0ac9f9e5a0e07f22d1d9028a4da64732a4630cfe097051046
- Guard deploy: https://testnet.bscscan.com/tx/0xe061f92e8fbba9bf4290854c86e03c93dc2d79aaf25e7757115bbc087177c1fc
- SpendLimit deploy: https://testnet.bscscan.com/tx/0xc815b31a2f68e754f634c64241f3c21b089c5ca54bc9d0e95121e0dfc315b485
- ThreatFeedBlocklist deploy: https://testnet.bscscan.com/tx/0x604efd088d585e66419d1774e39f06e50eb18c4f7bf38eef590d820d5f20448b
- Composite deploy: https://testnet.bscscan.com/tx/0x5fc7e161ba67131566a6a31a9d8015aefb543e4a4229755e8ab08183cc34e884

---

## Smoke test (policy → execute → revoke) — evidence

**Script:** `scripts/SmokeTest.s.sol`  
**Network:** BSC Testnet (chainId 97)  
**Block:** `90335969`  
**Result:** ✅ broadcast success; ✅ post-revoke call reverts with `PolicyInactive()`

### Inputs / actors

- **Kernel**: `0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82`
- **Owner/Agent (EOA):** `0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8`
- **policyId:** `0`

### Target used for smoke

- **MockTarget (created by the smoke script):** `0x7D98759DD0eD3282C9712670cdC7AFe60d9ee706`
  - BscScan (contract page): https://testnet.bscscan.com/address/0x7d98759dd0ed3282c9712670cdc7afe60d9ee706

> Note: MockTarget is **not verified** (no source published). This is expected for a smoke-only helper contract.

### Broadcast tx hashes (Sequence #1, all in block 90335969)

- https://testnet.bscscan.com/tx/0xe59a29735fda9e45c6e76e0fbf4d0334253862dcbe7e933d3eac9a48edc160b7
- https://testnet.bscscan.com/tx/0xc8fe32cc2697980e2c16fb3909b37bd69eda19ffb8875eab8316f234731798b4
- https://testnet.bscscan.com/tx/0x795bc46df64e66ec64db0f298813444902fdeb57330186a1e2716d2be52b6b90
- https://testnet.bscscan.com/tx/0x9daf885cc6221ac2778aeaa45955749b5bc18598cc4c185ef45f262764c69e5b
- https://testnet.bscscan.com/tx/0x3b1eb3abcbc9eabc65f2f4274ddee926b2d27251507ac074b017cd82da958009
- https://testnet.bscscan.com/tx/0x76d00d4a1efcf55af4b79f51ae71af1dd917932cdd6b13f396851c035286848f

### Post-revoke expected failure (no broadcast tx)

After `setPolicyActive(false)`, `execute(...)` is expected to revert with `PolicyInactive()` ✅  
This check is performed as a **call/prank** inside the script (not as a chain transaction), so there is no tx hash.

### Foundry artifacts

- `broadcast/SmokeTest.s.sol/97/run-latest.json`
- `cache/SmokeTest.s.sol/97/run-latest.json`
