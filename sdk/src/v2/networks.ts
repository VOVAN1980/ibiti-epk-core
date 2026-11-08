import type { Address } from "viem";

/**
 * Public EPK deployments and well-known contracts per network.
 *
 * BSC Testnet: an EPK factory anyone can use to create their own vault (you become its admin) — new vaults start
 * on EPKVault 2.2.0 and opt into later releases of the same registry — on the test-network rules (5-minute
 * release window and upgrade wait — the same code runs with production delays on mainnets). Plus the
 * PancakeSwap V2 testnet router, WBNB and Chainlink testnet feeds for DexGuard configs.
 * Testnet only — EPK is not audited and not deployed on any mainnet.
 */
export const networks = {
  bscTestnet: {
    chainId: 97,
    epk: {
      factory: "0xA128110b6C89E3A55E1F7815b75D48fcb124EB48" as Address,
      registry: "0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db" as Address,
      /** EPKVault 2.2.0, the implementation new vaults run (listed in `registry`) */
      implementation: "0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd" as Address,
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
    /** the live guard demo on EPKVault 2.2.0 (docs/TESTNET_V22_GUARDS.md) — read-only reference */
    demo: {
      guardVault: "0x5c2585f1f0725E54F8742798A20972Caa192eCba" as Address,
      dexGuard: "0xE40E81fc52d54F20ff883C3177878A3ECc03e152" as Address,
      threatFeed: "0xAc4128402295c8e8e68b77b518B1ae823BFcB271" as Address,
      compositeGuard: "0xCc6a261A6FD502F9122Bf0CEAd4a03157988577D" as Address,
    },
  },
} as const;
