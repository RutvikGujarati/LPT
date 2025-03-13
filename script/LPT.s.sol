// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/LPT.sol";

contract DeployDeepState is Script {
    function run() external {
        address treasuryWallet = 0x3Bdbb84B90aBAf52814aAB54B9622408F2dCA483;
        // address treasuryWallet = 0xBAaB2913ec979d9d21785063a0e4141e5B787D28;
        vm.startBroadcast();

       LiquidityPoolTokens oneD = new LiquidityPoolTokens(treasuryWallet);

        console.log("LiquidityPoolTokens deployed at:", address(oneD));

        vm.stopBroadcast();
    }
}