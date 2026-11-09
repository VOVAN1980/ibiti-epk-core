// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";

/// @title A vault release on BSC Testnet: deploy, list, opt the 5-minute vault in, public factory
/// @notice The current EPKVault release goes out the way any release would on mainnet, only with the clocks of
///         public test networks: the release window and the vault's upgrade wait (5 minutes each) run in
///         parallel; the 5-minute vault's admin opts in with SDK v2 (sdk/examples/v2-upgrade.ts); a new factory
///         then creates vaults directly on the release (the SDK's public factory). Each implementation deploys
///         its own emergency module (EPKVaultEmergency) in its constructor. Testnet only.
///   forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "start()"  --rpc-url $BSC_RPC_URL --broadcast --slow
///   cd sdk && npx tsx examples/v2-upgrade.ts          (schedules, waits 5 minutes, executes)
///   forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "finish()" --rpc-url $BSC_RPC_URL --broadcast --slow
contract ReleaseTestnet is Script {
    string internal constant OUT = "deployments/bsc-testnet/epk-release.json";
    string internal constant FAST = "deployments/bsc-testnet/epk-v2.1-fast-upgrade.json"; // the 5-minute stack

    function _testnetOnly() internal view {
        require(block.chainid == 97, "BSC Testnet only");
    }

    /// @notice Deploys the release (and, through its constructor, its emergency module) and lists it.
    function start() external {
        _testnetOnly();
        string memory fast = vm.readFile(FAST);
        EPKRegistry registry = EPKRegistry(vm.parseJsonAddress(fast, ".registry"));
        address fastVault = vm.parseJsonAddress(fast, ".vault");
        uint256 fastVaultTokens = IERC20(vm.parseJsonAddress(fast, ".token")).balanceOf(fastVault);

        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        EPKVault release = new EPKVault();
        registry.proposeRelease(address(release));
        vm.stopBroadcast();

        string memory o = "release";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "version", release.vaultVersion());
        vm.serializeAddress(o, "implementation", address(release));
        vm.serializeBytes32(o, "codehash", address(release).codehash);
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "fastVault", fastVault);
        vm.serializeUint(o, "fastVaultTokensBefore", fastVaultTokens);
        string memory out = vm.serializeUint(o, "startedAtBlock", block.number);
        vm.writeJson(out, OUT);
        console2.log("EPKVault implementation:", address(release));
        console2.log("vaultVersion:", release.vaultVersion());
        console2.log("release window (s):", registry.approvalDelay());
    }

    /// @notice After the SDK upgrade: the 5-minute vault runs the release at the same address with the same
    ///         funds; a factory for the release (same registry, so its vaults can opt into later releases).
    function finish() external {
        _testnetOnly();
        string memory j = vm.readFile(OUT);
        address release = vm.parseJsonAddress(j, ".implementation");
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(j, ".fastVault")));
        IERC20 tusd = IERC20(vm.parseJsonAddress(vm.readFile(FAST), ".token"));
        uint64 version = EPKVault(payable(release)).vaultVersion();
        require(vault.vaultVersion() == version, "the vault does not run the release yet");
        require(tusd.balanceOf(address(vault)) == vm.parseJsonUint(j, ".fastVaultTokensBefore"), "funds changed");

        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        EPKVaultFactory factory = new EPKVaultFactory(release, vm.parseJsonAddress(j, ".registry"));
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(factory)), OUT, ".factory");
        // the release's emergency module: the first contract its constructor created
        vm.writeJson(vm.toString(vm.computeCreateAddress(release, 1)), OUT, ".emergencyModule");
        console2.log("vault", address(vault), "runs version", vault.vaultVersion());
        console2.log("factory for new vaults:", address(factory));
    }
}
