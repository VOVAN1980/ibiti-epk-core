import type { Address } from "viem";

/**
 * Public EPK deployments and well-known contracts per network.
 *
 * BSC Testnet and opBNB Testnet: an EPK factory anyone can use to create their own vault (you become its admin) — new vaults start
 * on EPKVault 2.4.0 and opt into later releases of the same registry — on the test-network rules (5-minute
 * release window and upgrade wait — the same code runs with production delays on mainnets). The registry has a
 * security council (`council`, a test key here) that may fast-track an urgent patch release; each vault still
 * opts in itself (docs/FAST_TRACK_v2.md). On BSC Testnet also the
 * PancakeSwap V2 testnet router, WBNB and Chainlink testnet feeds for DexGuard configs.
 * Testnet only — EPK is not audited and not deployed on any mainnet.
 */
export const networks = {
  bscTestnet: {
    chainId: 97,
    epk: {
      factory: "0x0d0D4F2590962816Fc9dA07CF55Fa9E645D4DD67" as Address,
      registry: "0x56B66a65300b2344c22191FD27a3C3Dccc958dfC" as Address,
      /** EPKVault 2.4.0, the implementation new vaults run (the registry's genesis release) */
      implementation: "0xB391b1a92AEb6891DbC2f987eb5d117FC62FCc9E" as Address,
      /** the registry's security council (a test key on test networks) */
      council: "0x714889FEae680E012302679130AE880B010b9560" as Address,
    },
    dex: {
      pancakeV2Router: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1" as Address,
      wbnb: "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd" as Address,
    },
    tokens: {
      BUSD: "0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7" as Address,
      CAKE: "0xFa60D973F7642B748046464e165A65B7323b0DEE" as Address,
    },
    chainlink: {
      "BNB/USD": "0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526" as Address,
      "BUSD/USD": "0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa" as Address,
      "USDT/USD": "0xEca2605f0BCF2BA5966372C99837b1F182d3D620" as Address,
      "CAKE/USD": "0x81faeDDfeBc2F8Ac524327d70Cf913001732224C" as Address,
    },
    /** the live guard demo on EPKVault 2.3.0 (docs/TESTNET_GUARDS.md) — read-only reference */
    demo: {
      guardVault: "0x3Bdd9c884B168bbFa41C181328548a5e42180FD3" as Address,
      dexGuard: "0x1FC77bbe5947687e4094b0cD8842b6C7d4485C31" as Address,
      threatFeed: "0xC30d44F5c87c91d8a5EF3942546Ee478abD40815" as Address,
      compositeGuard: "0xc46373543fA89c36D6Eca1455A28C3FDbCCc3C0B" as Address,
    },
  },
  opbnbTestnet: {
    chainId: 5611,
    epk: {
      factory: "0xF0e8814072101e942Ab0c399305B406c5DCDF418" as Address,
      registry: "0x4e7A2d483FBd1f831344ef8472DE0eD680E004E5" as Address,
      /** EPKVault 2.4.0, the implementation new vaults run (the registry's genesis release) */
      implementation: "0xc389da518ee4597417E29d1686cE84d057a85FFD" as Address,
      /** the registry's security council (a test key on test networks) */
      council: "0x714889FEae680E012302679130AE880B010b9560" as Address,
    },
  },
} as const;
