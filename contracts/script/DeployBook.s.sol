// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HockeystickBook} from "../src/HockeystickBook.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";

/// @notice Deploys the peer-to-peer order book alongside the existing vault.
///
/// The book reuses whatever collateral and oracles are already deployed, so on
/// testnet it points at the same TestUSDC faucet and the same aggregators the
/// vault uses. Nothing about the existing deployment changes.
///
///   forge script script/DeployBook.s.sol --rpc-url robinhood_testnet --broadcast
///
/// Environment:
///   PRIVATE_KEY  deployer key
///   COLLATERAL   ERC20 collateral. On testnet, the existing TestUSDC.
///   ORACLES      comma-separated oracle addresses to list as markets.
///   CAPS         comma-separated payout caps in bps, one per oracle.
contract DeployBook is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address collateral = vm.envAddress("COLLATERAL");

        // Markets are optional here: a catalogue is usually listed afterwards
        // with script/ListMarkets.s.sol, which deploys a feed per entry.
        address[] memory oracles = vm.envOr("ORACLES", ",", new address[](0));
        uint256[] memory caps = vm.envOr("CAPS", ",", new uint256[](0));
        require(oracles.length == caps.length, "ORACLES and CAPS length mismatch");

        console.log("deployer  ", deployer);
        console.log("balance   ", deployer.balance);
        console.log("collateral", collateral);
        require(deployer.balance > 0, "deployer has no gas - fund it first");

        vm.startBroadcast(pk);

        HockeystickBook book = new HockeystickBook(collateral, deployer);
        console.log("HockeystickBook", address(book));

        for (uint256 i; i < oracles.length; ++i) {
            // listMarket reverts on a feed that cannot price, so a dead oracle
            // stops the deploy here rather than producing an unsettleable market.
            uint32 id = book.listMarket(oracles[i], uint64(caps[i]));
            console.log("market", id, oracles[i]);
            console.log("  cap bps", caps[i]);
        }

        vm.stopBroadcast();
    }
}
