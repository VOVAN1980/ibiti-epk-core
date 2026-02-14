import type { Address, PublicClient, WalletClient } from "viem";
import { getContract } from "viem";
import EPKernelAbi from "./abi/EPKernel.abi.json" with { type: "json" };
import CompositeValidatorAbi from "./abi/CompositeValidator.abi.json" with { type: "json" };
import TargetSelectorGuardAbi from "./abi/TargetSelectorGuard.abi.json" with { type: "json" };
import SpendLimitValidatorAbi from "./abi/SpendLimitValidator.abi.json" with { type: "json" };
import ThreatFeedBlocklistValidatorAbi from "./abi/ThreatFeedBlocklistValidator.abi.json" with { type: "json" };
export const abi = {
  EPKernel: EPKernelAbi,
  CompositeValidator: CompositeValidatorAbi,
  TargetSelectorGuard: TargetSelectorGuardAbi,
  SpendLimitValidator: SpendLimitValidatorAbi,
  ThreatFeedBlocklistValidator: ThreatFeedBlocklistValidatorAbi,
} as const;
export type ContractInstance = ReturnType<typeof getContract>;
export type Contracts = {
  EPKernel: ContractInstance;
  CompositeValidator: ContractInstance;
  TargetSelectorGuard: ContractInstance;
  SpendLimitValidator: ContractInstance;
  ThreatFeedBlocklistValidator: ContractInstance;
};
export type Addresses = Partial<Record<keyof Contracts, Address>>;
export function createEPKContracts(args: {
  publicClient: PublicClient;
  walletClient?: WalletClient;
  addresses: Addresses;
}): Partial<Contracts> {
  const { publicClient, walletClient, addresses } = args;
  const mk = (name: keyof typeof abi, address?: Address) => {
    if (!address) return undefined;
    return getContract({
      address,
      abi: abi[name] as any,
      client: { public: publicClient, wallet: walletClient },
    }) as ContractInstance;
  };
  return {
    EPKernel: mk("EPKernel", addresses.EPKernel),
    CompositeValidator: mk("CompositeValidator", addresses.CompositeValidator),
    TargetSelectorGuard: mk("TargetSelectorGuard", addresses.TargetSelectorGuard),
    SpendLimitValidator: mk("SpendLimitValidator", addresses.SpendLimitValidator),
    ThreatFeedBlocklistValidator: mk("ThreatFeedBlocklistValidator", addresses.ThreatFeedBlocklistValidator),
  };
}

