// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HockeystickVault} from "../src/HockeystickVault.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";

/// @notice Deploys the vault and lists an initial set of markets.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
///
/// Required environment:
///   PRIVATE_KEY   deployer key
///   COLLATERAL    ERC20 used as collateral (USDC/USDG on Robinhood Chain)
///
/// Feed addresses come from deploy/feeds.mainnet.json, generated from Chainlink's
/// reference directory. Read them from there rather than hardcoding — Chainlink
/// documents that page as the source of truth and addresses do change.
contract Deploy is Script {
    struct MarketConfig {
        string name;
        address feed;
        uint256 maxAge; // oracle staleness bound
        uint64 volatility; // annualised sigma, WAD
        uint64 payoutCapBps; // call ceiling as bps of strike
        uint128 maxNotional; // per-series exposure cap, collateral units
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address collateral = vm.envAddress("COLLATERAL");
        address owner = vm.addr(pk);

        // Crypto feeds carry a 24h heartbeat. Equity feeds only update 24/5, so
        // they need a window that survives a weekend or Monday settlement reverts.
        uint256 CRYPTO_MAX_AGE = 26 hours;
        uint256 EQUITY_MAX_AGE = 80 hours;

        MarketConfig[] memory configs = new MarketConfig[](4);
        configs[0] = MarketConfig({
            name: "ETH / USD",
            feed: 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9,
            maxAge: CRYPTO_MAX_AGE,
            volatility: 0.75e18,
            payoutCapBps: 30_000,
            maxNotional: 500_000e6
        });
        configs[1] = MarketConfig({
            name: "BTC / USD",
            feed: 0xa2c5184bF03d373Dc9dE4876eb4Bce595B460251,
            maxAge: CRYPTO_MAX_AGE,
            volatility: 0.55e18,
            payoutCapBps: 25_000,
            maxNotional: 500_000e6
        });
        configs[2] = MarketConfig({
            name: "NVDA / USD",
            feed: 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15,
            maxAge: EQUITY_MAX_AGE,
            volatility: 0.50e18,
            payoutCapBps: 20_000,
            maxNotional: 250_000e6
        });
        configs[3] = MarketConfig({
            name: "SLV / USD",
            feed: 0x209b73908e92Ae021826eD79609845451Ecba2ce,
            maxAge: EQUITY_MAX_AGE,
            volatility: 0.30e18,
            payoutCapBps: 15_000,
            maxNotional: 250_000e6
        });

        vm.startBroadcast(pk);

        HockeystickVault vault = new HockeystickVault(collateral, owner);
        console.log("HockeystickVault", address(vault));
        console.log("collateral      ", collateral);
        console.log("owner           ", owner);

        for (uint256 i; i < configs.length; ++i) {
            MarketConfig memory c = configs[i];
            ChainlinkOracle oracle = new ChainlinkOracle(c.feed, c.maxAge);

            // Fail fast if the feed is dead or stale rather than listing a market
            // that can never settle.
            (uint256 p,) = oracle.price();
            require(p > 0, "feed returned no price");

            uint32 id = vault.listMarket(address(oracle), c.volatility, c.payoutCapBps, c.maxNotional);
            console.log("market", id, c.name);
            console.log("  oracle", address(oracle));
            console.log("  spot  ", p / 1e18);
        }

        vm.stopBroadcast();
    }
}
