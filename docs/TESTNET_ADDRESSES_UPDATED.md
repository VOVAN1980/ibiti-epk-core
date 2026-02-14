BSC Testnet Deployment (Chain 97)

Source of truth: BscScan verified contract code, deployment tx hashes, and on-chain smoke-test evidence.

Contracts (BscScan Verified Source Code)

EPKernel: 0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82
https://testnet.bscscan.com/address/0x0beeb0083c576b54db99b4abef0dcbc5bc70bf82#code

CompositeValidator: 0x7c6389Bdc31CEE333A98c3e840B012B480de1c11
https://testnet.bscscan.com/address/0x7c6389bdc31cee333a98c3e840b012b480de1c11#code

TargetSelectorGuard: 0x05410A7c9a0835F641D5f85D83b6Ea9771F1114E
https://testnet.bscscan.com/address/0x05410a7c9a0835f641d5f85d83b6ea9771f1114e#code

SpendLimitValidator: 0x7Ec6A4F68D2071C21c473987C25586F85ddE1130
https://testnet.bscscan.com/address/0x7ec6a4f68d2071c21c473987c25586f85dde1130#code

ThreatFeedBlocklistValidator (no-op): 0xbfF42c0635987084F7923a1F9E71064683b09048
https://testnet.bscscan.com/address/0xbff42c0635987084f7923a1f9e71064683b09048#code

Deployment transactions (core)

EPKernel deploy: https://testnet.bscscan.com/tx/0x561d1b9e73dd40b0ac9f9e5a0e07f22d1d9028a4da64732a4630cfe097051046

TargetSelectorGuard deploy: https://testnet.bscscan.com/tx/0xe061f92e8fbba9bf4290854c86e03c93dc2d79aaf25e7757115bbc087177c1fc

SpendLimitValidator deploy: https://testnet.bscscan.com/tx/0xc815b31a2f68e754f634c64241f3c21b089c5ca54bc9d0e95121e0dfc315b485

ThreatFeedBlocklistValidator deploy: https://testnet.bscscan.com/tx/0x604efd088d585e66419d1774e39f06e50eb18c4f7bf38eef590d820d5f20448b

CompositeValidator deploy: https://testnet.bscscan.com/tx/0x5fc7e161ba67131566a6a31a9d8015aefb543e4a4229755e8ab08183cc34e884

Smoke test #2 (PRIMARY) — owner signs, agent executes, owner revokes

This is the main proof: Owner (signer) ≠ Agent (executor).
It demonstrates real delegated execution with EIP-712 signature verification and instant revoke.

Network: BSC Testnet (chainId 97)
Script: scripts/SmokeTest.s.sol
Kernel used: 0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82
Owner (signer): 0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8
Agent (executor): 0xC0213D4bd24CEC95C3804879653D9c66E92F39d6
policyId: 1
Blocks: 90338227 → 90338271

Target (helper)

MockTarget (deployed by smoke script): 0x01dc1612edB74D42e6dbd9cd0D4cF08a40757d12
https://testnet.bscscan.com/address/0x01dc1612edb74d42e6dbd9cd0d4cf08a40757d12

Note: helper contract used only for smoke-testing; it may be unverified (expected / not required for core proof).

On-chain transactions (Sequence)

Fund agent for gas (owner → agent, 0.001 BNB)
https://testnet.bscscan.com/tx/0xd3c48eb3621eed4d9372fa7422024a8bc530c78f45bf7546d87c634de480cc71

Deploy MockTarget (CREATE)
https://testnet.bscscan.com/tx/0xda887ae658687921e7b415650eece6de839bb8110e4fe7daec71c5bec378df60

Create policy — createPolicy(uint48,uint96,address)
https://testnet.bscscan.com/tx/0xdf1ea569b4323be0aef7543348e7d9b9cabb07bd57f2d0d223c5e145088ed3f7

Authorize agent — setAgent(uint256,address,bool,uint40)
https://testnet.bscscan.com/tx/0x01866173b56033f7b8142a1441335535abdfb6089b5d482e916066cd6f9bbae3

Allow target + selector — setCall(uint256,address,bytes4,bool)
https://testnet.bscscan.com/tx/0x0ace3d399a651342b8ec725883eac922e981c602b2ef4ad29574cd02b846a8a4

Agent executes (owner-signed EIP-712) — execute(uint256,address,uint256,bytes,uint256,bytes)
https://testnet.bscscan.com/tx/0x1375282de3fc243b75411b0b44a77149394cbbf1e0fe72613df3857bb1abbec4

Proof point: in tx logs, EPKernel.Executed(...) emits owner=0xA2BD... and agent=0xC021....

Owner revokes policy — setPolicyActive(uint256,bool) (active=false)
https://testnet.bscscan.com/tx/0x500bf67100efa9badbd30e84007e6c9c624667d32a87b0ee7166c4e4a9e38bbd

Expected failure after revoke: calling execute(...) reverts with PolicyInactive() ✅
Checked inside the script via a non-broadcast call (simulation/prank) — no tx hash by design.

Smoke test #1 (SECONDARY) — owner = agent — policy → execute → revoke

This is a simple sanity-check run (same EOA signs and executes).

Network: BSC Testnet (chainId 97)
Script: scripts/SmokeTest.s.sol
Kernel used: 0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82
Owner/Agent (EOA): 0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8
policyId: 0
Block: 90335969

Target (helper)

MockTarget (deployed by smoke script): 0x7D98759DD0eD3282C9712670cdC7AFe60d9ee706
https://testnet.bscscan.com/address/0x7d98759dd0ed3282c9712670cdc7afe60d9ee706

Note: helper contract used only for smoke-testing; it may be unverified (expected / not required for core proof).

On-chain transactions (Sequence)

Deploy MockTarget (CREATE)
https://testnet.bscscan.com/tx/0x795bc46df64e66ec64db0f298813444902fdeb57330186a1e2716d2be52b6b90

Create policy — createPolicy(uint48,uint96,address)
https://testnet.bscscan.com/tx/0x76d00d4a1efcf55af4b79f51ae71af1dd917932cdd6b13f396851c035286848f

Authorize agent — setAgent(uint256,address,bool,uint40)
https://testnet.bscscan.com/tx/0xe59a29735fda9e45c6e76e0fbf4d0334253862dcbe7e933d3eac9a48edc160b7

Allow target + selector — setCall(uint256,address,bytes4,bool)
https://testnet.bscscan.com/tx/0x3b1eb3abcbc9eabc65f2f4274ddee926b2d27251507ac074b017cd82da958009

Execute allowed call — execute(uint256,address,uint256,bytes,uint256,bytes)
https://testnet.bscscan.com/tx/0xc8fe32cc2697980e2c16fb3909b37bd69eda19ffb8875eab8316f234731798b4

Effect: MockTarget.setX(123) executed; EPKernel.Executed(...) emitted.

Revoke policy — setPolicyActive(uint256,bool) (active=false)
https://testnet.bscscan.com/tx/0x9daf885cc6221ac2778aeaa45955749b5bc18598cc4c185ef45f262764c69e5b

Expected failure after revoke: calling execute(...) reverts with PolicyInactive() ✅
Checked inside the script via a non-broadcast call (simulation/prank) — no tx hash by design.

Foundry artifacts (smoke runs)

broadcast/SmokeTest.s.sol/97/run-latest.json

cache/SmokeTest.s.sol/97/run-latest.json

Network

Chain: BSC Testnet

ChainId: 97

RPC: .env -> BSC_RPC_URL
