import type { Address } from "viem";

/**
 * Public EPK deployments and well-known contracts per network.
 *
 * BSC Testnet: an EPK 2.1 factory anyone can use to create their own vault (you become its admin), on the
 * test-network rules (5-minute release window and upgrade wait — the same code runs with production delays on
 * mainnets). Plus the PancakeSwap V2 testnet router, WBNB and Chainlink testnet feeds for DexGuard configs.
 * Testnet only — EPK is not audited and not deployed on any mainnet.
 */
export const networks = {
  bscTestnet: {
    chainId: 97,
    epk: {
      factory: "0x6f1BAE153931a618878DFe4323e5bE5d9b69B1d6" as Address,
      registry: "0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db" as Address,
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
    /** the live guard demo (docs/TESTNET_V21.md) — read-only reference */
    demo: {
      guardVault: "0x83c6D86019BfF5ebBb7bd955aa63878DAa60f674" as Address,
      dexGuard: "0x5A00736dE12a925E7A9427dB7253C3074f434209" as Address,
      threatFeed: "0x327274073da2dCac166F20E68e2e7fD2fA15EDba" as Address,
      compositeGuard: "0x83e0a92F04EFE126D6Ce4aE6066FcEc5Ca849B09" as Address,
    },
  },
} as const;
