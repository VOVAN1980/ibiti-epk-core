import type { Address, Hex } from "viem";
export type ExecuteRequest = {
  policyId: bigint;
  target: Address;
  value: bigint;
  data: Hex;
  deadline: bigint;
};
export type SignedExecute = ExecuteRequest & {
  nonce: bigint;
  dataHash: Hex;
  typedDataHash: Hex;
  sig: Hex;
};
