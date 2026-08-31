// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HockeystickVault} from "../src/HockeystickVault.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {TestnetAggregator} from "../src/testnet/TestnetAggregator.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";

/// @notice Full testnet bring-up: collateral, feeds, vault, markets, seed liquidity.
///
/// Chainlink has not deployed feeds to Robinhood Chain testnet, so this deploys
/// writable aggregators behind the production `ChainlinkOracle` adapter. The
/// adapter — and its staleness and incomplete-round checks — runs unchanged;
/// only the feed behind it is synthetic.
///
///   forge script script/DeployTestnet.s.sol --rpc-url robinhood_testnet --broadcast
///
/// Environment: PRIVATE_KEY (a throwaway key holding only testnet ETH).
contract DeployTestnet is Script {
    // Seeded from Robinhood Chain mainnet Chainlink feeds, 8 decimals.
    int256 constant ETH_USD = 2442_00000000;
    int256 constant BTC_USD = 78182_00000000;
    int256 constant NVDA_USD = 218_68000000;
    int256 constant SLV_USD = 60_41000000;

    uint256 constant MAX_AGE = 30 days; // generous: testnet feeds are pushed by hand
    uint256 constant SEED_LIQUIDITY = 2_000_000e6;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("deployer", deployer);
        console.log("balance ", deployer.balance);
        require(deployer.balance > 0, "deployer has no testnet ETH - use a faucet first");

        vm.startBroadcast(pk);

        TestUSDC usdc = new TestUSDC();
        HockeystickVault vault = new HockeystickVault(address(usdc), deployer);

        _list(vault, deployer, "ETH / USD", ETH_USD, 0.75e18, 30_000, 500_000e6);
        _list(vault, deployer, "BTC / USD", BTC_USD, 0.55e18, 25_000, 500_000e6);
        _list(vault, deployer, "NVDA / USD", NVDA_USD, 0.50e18, 20_000, 250_000e6);
        _list(vault, deployer, "SLV / USD", SLV_USD, 0.30e18, 15_000, 250_000e6);

        // Seed the pool so the book can actually write options.
        usdc.mint(deployer, SEED_LIQUIDITY);
        usdc.approve(address(vault), SEED_LIQUIDITY);
        vault.deposit(SEED_LIQUIDITY, deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("TestUSDC        ", address(usdc));
        console.log("HockeystickVault", address(vault));
        console.log("markets         ", vault.marketCount());
        console.log("pool assets     ", vault.totalAssets());
        console.log("free collateral ", vault.freeCollateral());
    }

    function _list(
        HockeystickVault vault,
        address owner,
        string memory name,
        int256 price,
        uint64 vol,
        uint64 capBps,
        uint128 maxNotional
    ) internal {
        TestnetAggregator agg = new TestnetAggregator(name, price, owner);
        ChainlinkOracle oracle = new ChainlinkOracle(address(agg), MAX_AGE);

        (uint256 p,) = oracle.price();
        require(p > 0, "feed returned no price");

        uint32 id = vault.listMarket(address(oracle), vol, capBps, maxNotional);
        console.log("market", id, name);
        console.log("  aggregator", address(agg));
        console.log("  oracle    ", address(oracle));
    }
}
