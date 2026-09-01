// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HockeystickBook} from "../src/HockeystickBook.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {TestnetAggregator} from "../src/testnet/TestnetAggregator.sol";

/// @notice Lists a catalogue of testnet markets on an existing book.
///
/// Each entry gets a writable `TestnetAggregator` standing in for a Chainlink
/// feed, behind the production `ChainlinkOracle` adapter — so the adapter and
/// its staleness checks run unchanged, and only the feed is synthetic. Chainlink
/// has feeds for a handful of these assets and none for the rest, which is the
/// whole reason a stand-in exists on testnet.
///
///   BOOK=0x… FROM=0 TO=25 forge script script/ListMarkets.s.sol \
///     --rpc-url robinhood_testnet --broadcast
///
/// FROM/TO index into deploy/markets.testnet.json and default to the whole file.
/// They exist so a long catalogue can be listed in batches rather than one
/// transaction bundle large enough to time out.
///
/// Environment: PRIVATE_KEY, BOOK. Optional: FROM, TO, MARKETS (path).
contract ListMarkets is Script {
    // Equity and commodity feeds only update on weekdays, so their staleness
    // window has to survive a weekend or Monday settlement reverts. Crypto and
    // FX run continuously.
    uint256 constant CONTINUOUS_MAX_AGE = 26 hours;
    uint256 constant SESSION_MAX_AGE = 80 hours;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        HockeystickBook book = HockeystickBook(vm.envAddress("BOOK"));

        string memory path = vm.envOr("MARKETS", string("deploy/markets.testnet.json"));
        string memory json = vm.readFile(path);

        uint256 total = vm.parseJsonUint(json, ".count");
        uint256 from = vm.envOr("FROM", uint256(0));
        uint256 to = vm.envOr("TO", total);
        if (to > total) to = total;
        require(from < to, "empty range");

        console.log("book    ", address(book));
        console.log("deployer", deployer);
        console.log("balance ", deployer.balance);
        console.log("listing ", to - from);
        require(deployer.balance > 0, "deployer has no gas");

        vm.startBroadcast(pk);

        for (uint256 i = from; i < to; ++i) {
            _listOne(book, json, i, deployer);
        }

        vm.stopBroadcast();
    }

    /// @dev One market per call; kept out of `run` so the loop body's locals do
    ///      not pile up on the stack.
    function _listOne(HockeystickBook book, string memory json, uint256 i, address owner) internal {
        string memory base = string.concat(".markets[", vm.toString(i), "]");
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));

        uint256 maxAge = _continuous(vm.parseJsonString(json, string.concat(base, ".category")))
            ? CONTINUOUS_MAX_AGE
            : SESSION_MAX_AGE;

        TestnetAggregator agg = new TestnetAggregator(
            name,
            int256(vm.parseUint(vm.parseJsonString(json, string.concat(base, ".answer8")))),
            owner
        );
        ChainlinkOracle oracle = new ChainlinkOracle(address(agg), maxAge);

        // listMarket reverts if the feed cannot price, so a bad entry stops the
        // batch here rather than creating a market that can never settle.
        uint32 id = book.listMarket(
            address(oracle), uint64(vm.parseJsonUint(json, string.concat(base, ".payoutCapBps")))
        );
        console.log("listed", id, name);
    }

    function _continuous(string memory category) internal pure returns (bool) {
        bytes32 c = keccak256(bytes(category));
        return c == keccak256("crypto") || c == keccak256("memecoin") || c == keccak256("fx");
    }
}
