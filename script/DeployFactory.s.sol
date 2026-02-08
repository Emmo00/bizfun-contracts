// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {PredictionMarketFactory} from "../src/PredictionMarketFactory.sol";

contract DeployFactory is Script {
    function run() external {
        // --- Configuration (override via env vars or CLI flags) ---
        address usdc = vm.envAddress("USDC_ADDRESS");
        uint256 creationFee = vm.envOr("CREATION_FEE", uint256(10e6));         // default $10 (USDC 6-dec)
        uint256 initialLiquidity = vm.envOr("INITIAL_LIQUIDITY", uint256(5e6)); // default $5  (USDC 6-dec)

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the PredictionMarket implementation (clone template)
        PredictionMarket implementation = new PredictionMarket();

        // 2. Deploy the factory, pointing it at the implementation
        //    (decimals are auto-fetched from the collateral token)
        PredictionMarketFactory factory =
            new PredictionMarketFactory(usdc, address(implementation), creationFee, initialLiquidity);

        console.log("=== BizFun Deployment ===");
        console.log("Implementation deployed at:", address(implementation));
        console.log("Factory deployed at:", address(factory));
        console.log("  Collateral token:", usdc);
        console.log("  Collateral decimals:", factory.COLLATERAL_DECIMALS());
        console.log("  Creation fee:", creationFee);
        console.log("  Initial liquidity:", initialLiquidity);

        vm.stopBroadcast();
    }
}
