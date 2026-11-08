// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";

/// @title EPKVault 2.2.0 on BSC Testnet: deploy, list, opt the demo vaults in
/// @notice Release 2.2.0 (the fifth review's vault fixes) goes out the way any release would on mainnet,
///         only with the test-network clocks where the deployed code has them:
///         - the 5-minute stack (docs/TESTNET_V21_FAST_UPGRADE.md): the release window and the vault's
///           upgrade wait run in parallel; the vault's admin opts in with SDK v2 (sdk/examples/v2-upgrade.ts);
///           a new factory then creates vaults directly on 2.2.0 (the SDK's public factory);
///         - the 2.1 guard demo (docs/TESTNET_V21.md): its registry was deployed before the test-network
///           clocks existed, so 2.2.0 waits the production 7-day public window there; the vault opts in after.
///         The 2.0.x demo vault is not touched. Testnet only; all keys are the demo's own test keys.
///   forge script scripts/v2/Release220Testnet.s.sol:Release220Testnet --sig "start()"  --rpc-url $BSC_RPC_URL --broadcast --slow
///   cd sdk && npx tsx examples/v2-upgrade.ts          (schedules, waits 5 minutes, executes)
///   forge script scripts/v2/Release220Testnet.s.sol:Release220Testnet --sig "finish()" --rpc-url $BSC_RPC_URL --broadcast --slow
///   (7 days after start, for the guard demo vault; then executeGuardDemo() after the vault's upgrade wait)
///   forge script scripts/v2/Release220Testnet.s.sol:Release220Testnet --sig "upgradeGuardDemo()" --rpc-url $BSC_RPC_URL --broadcast --slow
contract Release220Testnet is Script {
    string internal constant OUT = "deployments/bsc-testnet/epk-v2.2.json";
    string internal constant FAST = "deployments/bsc-testnet/epk-v2.1-fast-upgrade.json";
    string internal constant GUARD_DEMO = "deployments/bsc-testnet/epk-v2.1.json";
    bytes32 internal constant GUARD_DEMO_SALT = keccak256("EPK guard demo upgrade to 2.2.0");

    function _testnetOnly() internal view {
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        require(block.chainid == 97, "BSC Testnet only");
    }

    /// @notice Deploys the 2.2.0 implementation and proposes it in both 2.1 registries.
    function start() external {
        _testnetOnly();
        string memory fast = vm.readFile(FAST);
        EPKRegistry fastRegistry = EPKRegistry(vm.parseJsonAddress(fast, ".registry"));
        address fastVault = vm.parseJsonAddress(fast, ".vault");
        uint256 fastVaultTokens = IERC20(vm.parseJsonAddress(fast, ".token")).balanceOf(fastVault);
        EPKRegistry guardRegistry = EPKRegistry(vm.parseJsonAddress(vm.readFile(GUARD_DEMO), ".registry"));

        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        EPKVault release = new EPKVault();
        require(release.vaultVersion() == 20_200, "not 2.2.0");
        fastRegistry.proposeRelease(address(release));
        guardRegistry.proposeRelease(address(release));
        vm.stopBroadcast();

        string memory o = "v22";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "implementation_2_2_0", address(release));
        vm.serializeBytes32(o, "codehash_2_2_0", address(release).codehash);
        vm.serializeAddress(o, "fastRegistry", address(fastRegistry));
        vm.serializeAddress(o, "fastVault", fastVault);
        vm.serializeUint(o, "fastVaultTokensBefore", fastVaultTokens);
        vm.serializeAddress(o, "guardDemoRegistry", address(guardRegistry));
        vm.serializeAddress(o, "guardDemoVault", vm.parseJsonAddress(vm.readFile(GUARD_DEMO), ".vault"));
        string memory out = vm.serializeUint(o, "startedAtBlock", block.number);
        vm.writeJson(out, OUT);
        console2.log("EPKVault 2.2.0 implementation:", address(release));
        console2.log("5-minute registry window (s):", fastRegistry.approvalDelay());
    }

    /// @notice After the SDK upgrade: checks the vault runs 2.2.0 at the same address with the same funds,
    ///         and deploys a factory that creates vaults directly on 2.2.0 (same registry, so those vaults
    ///         can opt into every later release).
    function finish() external {
        _testnetOnly();
        string memory j = vm.readFile(OUT);
        address release = vm.parseJsonAddress(j, ".implementation_2_2_0");
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(j, ".fastVault")));
        IERC20 tusd = IERC20(vm.parseJsonAddress(vm.readFile(FAST), ".token"));
        require(vault.vaultVersion() == 20_200, "the vault does not run 2.2.0 yet");
        require(tusd.balanceOf(address(vault)) == vm.parseJsonUint(j, ".fastVaultTokensBefore"), "funds changed");

        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        EPKVaultFactory factory = new EPKVaultFactory(release, vm.parseJsonAddress(j, ".fastRegistry"));
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(factory)), OUT, ".factory_2_2_0");
        console2.log("vault", address(vault), "runs version", vault.vaultVersion());
        console2.log("factory for new 2.2.0 vaults:", address(factory));
    }

    /// @notice The guard demo vault opts in once its registry's 7-day window has passed. Schedules here;
    ///         `executeGuardDemo()` runs it after the vault's own upgrade wait.
    function upgradeGuardDemo() external {
        _testnetOnly();
        string memory j = vm.readFile(OUT);
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(j, ".guardDemoVault")));
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        bytes32 id = vault.scheduleUpgrade(vm.parseJsonAddress(j, ".implementation_2_2_0"), GUARD_DEMO_SALT);
        vm.stopBroadcast();
        console2.log("guard demo vault upgrade scheduled, operation", vm.toString(id));
    }

    function executeGuardDemo() external {
        _testnetOnly();
        string memory j = vm.readFile(OUT);
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(j, ".guardDemoVault")));
        address release = vm.parseJsonAddress(j, ".implementation_2_2_0");
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        vault.executeScheduled(vault.upgradeOperationData(release), GUARD_DEMO_SALT);
        vm.stopBroadcast();
        require(vault.vaultVersion() == 20_200, "not upgraded");
        console2.log("guard demo vault", address(vault), "now runs version", vault.vaultVersion());
    }
}
