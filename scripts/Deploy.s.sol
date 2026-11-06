// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKernel} from "../contracts/epk/EPKernel.sol";
import {CompositeValidator} from "../contracts/validators/CompositeValidator.sol";
import {TargetSelectorGuard} from "../contracts/validators/TargetSelectorGuard.sol";
import {SpendLimitValidator} from "../contracts/validators/SpendLimitValidator.sol";
import {ThreatFeedBlocklistValidator} from "../contracts/validators/ThreatFeedBlocklistValidator.sol";

contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        bool deployThreatFeed = vm.envOr("DEPLOY_THREATFEED", false);
        bytes32 threatRoot = vm.envOr("THREAT_ROOT", bytes32(0));
        uint256 threatEpoch = vm.envOr("THREAT_EPOCH", uint256(0));

        vm.startBroadcast(pk);

        // Деплоим ядро
        EPKernel kernel = new EPKernel();

        // Пустой массив для CompositeValidator (если валидаторов пока нет)
        address[] memory empty = new address[](0);

        // Деплоим CompositeValidator (он будет родителем для остальных валидаторов)
        CompositeValidator composite = new CompositeValidator(address(kernel), owner, empty);

        // Деплоим валидаторы
        TargetSelectorGuard guard = new TargetSelectorGuard(address(composite), owner);
        SpendLimitValidator spend = new SpendLimitValidator(address(composite), owner);
        ThreatFeedBlocklistValidator blocklist = new ThreatFeedBlocklistValidator(
            address(composite),
            owner,
            bytes32(0), // no-op root
            0
        );

        ThreatFeedBlocklistValidator threatFeed;

        // Готовим массив валидаторов для composite.setValidators()
        uint256 validatorCount = deployThreatFeed ? 4 : 3;
        address[] memory validators = new address[](validatorCount);

        validators[0] = address(guard);
        validators[1] = address(spend);
        validators[2] = address(blocklist);

        if (deployThreatFeed) {
            threatFeed = new ThreatFeedBlocklistValidator(
                address(composite),
                owner,
                threatRoot,
                threatEpoch
            );
            validators[3] = address(threatFeed);
        }

        // Привязываем валидаторы к Composite
        composite.setValidators(validators);

        vm.stopBroadcast();

        // Логируем адреса
        console2.log("EPKernel                  :", address(kernel));
        console2.log("CompositeValidator        :", address(composite));
        console2.log("TargetSelectorGuard       :", address(guard));
        console2.log("SpendLimitValidator       :", address(spend));
        console2.log("ThreatFeedBlocklist (no-op):", address(blocklist));
        if (deployThreatFeed) {
            console2.log("ThreatFeed (active)      :", address(threatFeed));
        }
    }
}