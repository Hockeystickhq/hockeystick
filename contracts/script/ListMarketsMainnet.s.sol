// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HockeystickBook} from "../src/HockeystickBook.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";

/// @notice Lists mainnet markets against real Chainlink feeds.
///
/// @dev Deliberately separate from `ListMarkets.s.sol`, which deploys a writable
///      `TestnetAggregator` per entry. That stand-in exists because Chainlink has
///      not published feeds to the testnet, and whoever holds its owner key can
///      set the settlement price of every market reading it. It must never reach
///      mainnet, so the mainnet path does not import it and cannot deploy one.
///
///      Feed addresses come from deploy/feeds.mainnet.json, generated from
///      Chainlink's reference directory. The catalogue is therefore bounded by
///      the feeds that actually exist: twelve today, not the hundred listed on
///      testnet.
///
///   BOOK=0x… forge script script/ListMarketsMainnet.s.sol \
///     --rpc-url robinhood_mainnet --broadcast
///
/// Environment: PRIVATE_KEY, BOOK. Optional: FROM, TO, FEEDS (path).
contract ListMarketsMainnet is Script {
    // Crypto feeds carry a 24h heartbeat. Equity feeds only update 24/5, so they
    // need a window that survives a weekend or Monday settlement reverts.
    uint256 constant CRYPTO_MAX_AGE = 26 hours;
    uint256 constant EQUITY_MAX_AGE = 80 hours;

    // Caps are the collateral a call writer must post, so they are set by how far
    // an asset can plausibly run rather than by ambition.
    uint64 constant CRYPTO_CAP = 30_000; // 3x strike
    uint64 constant EQUITY_CAP = 20_000; // 2x strike

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        HockeystickBook book = HockeystickBook(vm.envAddress("BOOK"));

        string memory path = vm.envOr("FEEDS", string("deploy/feeds.mainnet.json"));
        string memory json = vm.readFile(path);

        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "feed file is for another chain");

        uint256 total = vm.parseJsonUint(json, ".count");
        uint256 from = vm.envOr("FROM", uint256(0));
        uint256 to = vm.envOr("TO", total);
        if (to > total) to = total;
        require(from < to, "empty range");

        console.log("book    ", address(book));
        console.log("deployer", deployer);
        console.log("balance ", deployer.balance);
        console.log("listing ", to - from);
        require(deployer.balance > 0, "deployer has no gas - fund it first");

        vm.startBroadcast(pk);
        for (uint256 i = from; i < to; ++i) {
            _listOne(book, json, i);
        }
        vm.stopBroadcast();
    }

    function _listOne(HockeystickBook book, string memory json, uint256 i) internal {
        string memory base = string.concat(".feeds[", vm.toString(i), "]");
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
        bool equity = vm.parseJsonBool(json, string.concat(base, ".equity"));

        ChainlinkOracle oracle = new ChainlinkOracle(
            vm.parseJsonAddress(json, string.concat(base, ".feed")),
            equity ? EQUITY_MAX_AGE : CRYPTO_MAX_AGE
        );

        // A feed that cannot price today would make a market that can never
        // settle, so read it before listing and let a dead feed stop the batch.
        (uint256 p,) = oracle.price();
        require(p > 0, "feed returned no price");

        uint32 id = book.listMarket(address(oracle), equity ? EQUITY_CAP : CRYPTO_CAP);
        console.log("listed", id, name);
        console.log("  spot", p / 1e18);
    }
}
