// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {BeliefMarket} from "../src/BeliefMarket.sol";

contract DeployBeliefMarket is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        BeliefMarket market = new BeliefMarket(usdc);

        vm.stopBroadcast();

        console.log("RollyPolly deployed at:", address(market));
        console.log("Explorer: https://testnet.bscscan.com/address/", address(market));
    }
}