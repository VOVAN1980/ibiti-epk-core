// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {EPKDemoNetwork} from "./demo/EPKDemoNetwork.sol";

/// @title A vault release on a public test network: deploy, list, a vault opts in, a registry with a council
/// @notice The current EPKVault release goes out the way any release would on mainnet, only with the clocks of
///         public test networks (5-minute release window and upgrade wait, running in parallel):
///         1. `start()` deploys the release (its constructor deploys its emergency module) and proposes it in
///            the registry the network's existing vaults use;
///         2. the upgrade-demo vault's admin opts in with SDK v2 (`sdk/examples/v2-upgrade.ts <network>`);
///         3. `finish()` checks the vault runs the release with the same funds, then deploys a registry whose
///            genesis release is this one, with a security council (`EPK_COUNCIL`) that may fast-track
///            patch releases, and the public factory for new vaults on it.
///         Existing vaults keep the registry they were created with (no council there: normal upgrade path).
///         BSC Testnet: the registry owner and vault admin is V21_ADMIN_PRIVATE_KEY, the upgrade-demo vault is
///         the 5-minute vault (epk-v2.1-fast-upgrade.json). opBNB Testnet: PRIVATE_KEY, and `prepare()` first
///         creates a small vault on the current release for the demo (the main and guard demo vaults stay as
///         their evidence records them). Test networks only.
///   forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "prepare()" --rpc-url $RPC --broadcast --slow   (opBNB only)
///   forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "start()"   --rpc-url $RPC --broadcast --slow
///   cd sdk && npx tsx examples/v2-upgrade.ts <bsc|opbnb>       (schedules, waits 5 minutes, executes)
///   forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "finish()"  --rpc-url $RPC --broadcast --slow
contract ReleaseTestnet is Script {
    function _isBsc() internal view returns (bool) {
        require(block.chainid == 97 || block.chainid == 5611, "BSC Testnet or opBNB Testnet only");
        return block.chainid == 97;
    }

    /// @dev The key that owns the network's existing registry and administers the upgrade-demo vault.
    function _ownerKeyName() internal view returns (string memory) {
        return _isBsc() ? "V21_ADMIN_PRIVATE_KEY" : "PRIVATE_KEY";
    }

    /// @dev Where the network's existing registry (and, on BSC, the upgrade-demo vault) is recorded.
    function _stack() internal view returns (string memory) {
        return vm.readFile(EPKDemoNetwork.file(_isBsc() ? "epk-v2.1-fast-upgrade.json" : "epk-v2.json"));
    }

    /// @dev The upgrade-demo vault and its test token.
    function _demoVault() internal view returns (address vault, address token) {
        string memory j = _isBsc() ? _stack() : vm.readFile(EPKDemoNetwork.file("epk-upgrade-vault.json"));
        return (vm.parseJsonAddress(j, ".vault"), vm.parseJsonAddress(j, ".token"));
    }

    /// @notice opBNB Testnet: a small vault on the current release, through the public factory, for the upgrade.
    function prepare() external {
        require(!_isBsc(), "BSC Testnet already has its 5-minute vault");
        string memory out = EPKDemoNetwork.file("epk-upgrade-vault.json");
        require(!vm.exists(out), "the upgrade-demo vault exists already");
        string memory s = _stack();
        EPKVaultFactory factory = EPKVaultFactory(vm.parseJsonAddress(s, ".factory"));
        IERC20 token = IERC20(vm.parseJsonAddress(s, ".token"));
        address[] memory guardians = new address[](2);
        guardians[0] = vm.addr(vm.envUint("V2_GUARDIAN1_PRIVATE_KEY"));
        guardians[1] = vm.addr(vm.envUint("V2_GUARDIAN2_PRIVATE_KEY"));
        address recovery = vm.addr(vm.envUint("V2_RECOVERY_PRIVATE_KEY"));

        vm.startBroadcast(vm.envUint(_ownerKeyName()));
        EPKVault vault =
            EPKVault(payable(factory.createVault(guardians, 5 minutes, recovery, keccak256("EPK upgrade demo"))));
        vault.finalizeSetup();
        require(token.transfer(address(vault), 10 ether), "deposit failed");
        vm.stopBroadcast();

        string memory o = "upgradeVault";
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeUint(o, "version", vault.vaultVersion());
        string memory json = vm.serializeAddress(o, "token", address(token));
        vm.writeJson(json, out);
        console2.log("upgrade-demo vault", address(vault), "runs", vault.vaultVersion());
    }

    /// @notice Deploys the release (and, through its constructor, its emergency module) and lists it in the
    ///         registry the network's existing vaults use.
    function start() external {
        EPKRegistry registry = EPKRegistry(vm.parseJsonAddress(_stack(), ".registry"));
        (address vault, address token) = _demoVault();

        vm.startBroadcast(vm.envUint(_ownerKeyName()));
        EPKVault release = new EPKVault();
        registry.proposeRelease(address(release));
        vm.stopBroadcast();

        string memory o = "release";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "version", release.vaultVersion());
        vm.serializeAddress(o, "implementation", address(release));
        vm.serializeBytes32(o, "codehash", address(release).codehash);
        // the release's emergency module: the first contract its constructor created
        vm.serializeAddress(o, "emergencyModule", vm.computeCreateAddress(address(release), 1));
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeString(o, "adminKey", _ownerKeyName());
        vm.serializeAddress(o, "upgradeVault", vault);
        vm.serializeAddress(o, "token", token);
        vm.serializeUint(o, "upgradeVaultTokensBefore", IERC20(token).balanceOf(vault));
        string memory out = vm.serializeUint(o, "startedAtBlock", block.number);
        vm.writeJson(out, EPKDemoNetwork.file("epk-release.json"));
        console2.log("EPKVault implementation:", address(release));
        console2.log("vaultVersion:", release.vaultVersion());
        console2.log("release window (s):", registry.approvalDelay());
    }

    /// @notice After the SDK upgrade: the demo vault runs the release at the same address with the same funds.
    ///         Then a registry with a security council (genesis: this release) and the public factory on it.
    function finish() external {
        string memory file = EPKDemoNetwork.file("epk-release.json");
        string memory j = vm.readFile(file);
        address release = vm.parseJsonAddress(j, ".implementation");
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(j, ".upgradeVault")));
        uint64 version = EPKVault(payable(release)).vaultVersion();
        require(vault.vaultVersion() == version, "the vault does not run the release yet");
        require(
            IERC20(vm.parseJsonAddress(j, ".token")).balanceOf(address(vault))
                == vm.parseJsonUint(j, ".upgradeVaultTokensBefore"),
            "funds changed"
        );
        address council = vm.envAddress("EPK_COUNCIL");
        require(council != address(0), "EPK_COUNCIL missing");
        uint256 pk = vm.envUint(_ownerKeyName());

        vm.startBroadcast(pk);
        EPKRegistry councilRegistry = new EPKRegistry(vm.addr(pk), release, council);
        EPKVaultFactory factory = new EPKVaultFactory(release, address(councilRegistry));
        vm.stopBroadcast();

        require(councilRegistry.isApproved(release) && councilRegistry.council() == council, "registry setup");
        require(!councilRegistry.isUrgent(release), "nothing is urgent yet");
        vm.writeJson(vm.toString(address(councilRegistry)), file, ".councilRegistry");
        vm.writeJson(vm.toString(council), file, ".council");
        vm.writeJson(vm.toString(address(factory)), file, ".factory");
        console2.log("vault", address(vault), "runs version", vault.vaultVersion());
        console2.log("registry with a security council:", address(councilRegistry));
        console2.log("factory for new vaults:", address(factory));
    }
}
