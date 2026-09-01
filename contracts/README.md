# Hockeystick contracts

On-chain options for [Robinhood Chain](https://docs.robinhood.com/chain/), an
Arbitrum L2. Fully collateralised, cash settled, Chainlink oracle settlement.

| | Chain ID | RPC | Explorer |
|---|---|---|---|
| Mainnet | 4663 | `https://rpc.mainnet.chain.robinhood.com` | robinhoodchain.blockscout.com |
| Testnet | 46630 | `https://rpc.testnet.chain.robinhood.com` | explorer.testnet.chain.robinhood.com |

## The solvency invariant

Every option is backed, at the moment of sale, by collateral already held equal to
its maximum possible payout. The pool never writes exposure it has not funded, so it
cannot become insolvent, and `totalAssets() >= lockedCollateral()` holds after every
state transition. That property is fuzz-tested across randomised buy/settle/exercise
flows.

**Calls are capped.** A cash-settled call has unbounded payoff and therefore cannot be
fully collateralised as written. Each market carries a payout ceiling expressed as a
multiple of strike, so a call pays `min(spot, cap) - strike`. Economically every call
is a call spread, and it is priced as one — the premium is the vanilla call minus the
call struck at the cap, so buyers are not charged for upside the pool never sells.

Puts need no cap. Their payoff is bounded by a zero underlying, so `strike` per
contract is an exact reserve.

## Layout

```
src/HockeystickVault.sol     Pool, pricing, collateral, settlement, exercise
src/ChainlinkOracle.sol      AggregatorV3 adapter with staleness rejection
src/lib/BlackScholes.sol     On-chain pricing and delta, 18-decimal fixed point
src/interfaces/IOracle.sol   Oracle interface
script/Deploy.s.sol          Deploys the vault and lists initial markets
deploy/feeds.mainnet.json    Live Chainlink feed addresses on Robinhood Chain
```

## Test

```bash
forge test -vv
```

The Black-Scholes suite checks against published reference values (ATM S=K=100, T=1,
sigma=20%, r=5% gives 10.4506 call / 5.5735 put), verifies put-call parity, and fuzzes
the no-arbitrage bounds. The vault suite covers payoff correctness, the exposure cap,
the dispute window, and the solvency invariant.

## Deploy

```bash
cp .env.example .env        # PRIVATE_KEY and COLLATERAL
source .env
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast
```

The script deploys an oracle adapter per market and reverts if a feed returns no
price, so a market that could never settle is never listed.

## Oracle notes

Feeds are Chainlink `AggregatorV3Interface`, 8 decimals, 24h heartbeat. Read addresses
from [Chainlink's registry](https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood)
rather than hardcoding them — that page is the documented source of truth.

Equity feeds update 24/5. A market on a tokenized equity needs a staleness window that
survives a weekend, or Monday settlement reverts on a stale price. The deploy script
uses 26 hours for crypto and 80 hours for equities.

## Deployed — Robinhood Chain testnet (46630)

| Contract | Address |
|---|---|
| HockeystickVault | [`0x2a4d14f5...df79e`](https://explorer.testnet.chain.robinhood.com/address/0x2a4d14f5f7ad1cde33d9687caf732087bb2df79e) |
| TestUSDC (faucet) | [`0x5f9ea3a1...11358`](https://explorer.testnet.chain.robinhood.com/address/0x5f9ea3a11da65fbdf559c9f2218dd231d2a11358) |

Four markets live: ETH, BTC, NVDA, SLV. Full addresses in
[`deploy/testnet.json`](deploy/testnet.json).

Call `claim()` on TestUSDC for 100,000 tUSDC a day, then `buy()` on the vault.

First live trade: 5x 7-day $2,442 ETH puts for $505.84 premium, against $12,210
locked — exactly five contracts times the strike.

## Deployed — Robinhood Chain mainnet (4663)

| Contract | Address |
|---|---|
| HockeystickBook | [`0x5F9eA3a1...d2a11358`](https://robinhoodchain.blockscout.com/address/0x5F9eA3a11dA65fbdf559C9f2218DD231d2a11358) |
| USDG (collateral) | [`0x5fc5360D...16F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) |

Settles in USDG, the Paxos Global Dollar, 6 decimals. Four markets live: BTC,
ETH, LINK and tokenized AAPL, each against its own real Chainlink feed. Eight
more feeds are mapped in `deploy/feeds.mainnet.json` and can be listed at any
time with `script/ListMarketsMainnet.s.sol`.

**This is real money and the contracts have not been audited.** The dispute
window is one hour, as it should be when payouts are real. Full record in
[`deploy/mainnet.json`](deploy/mainnet.json).

## Two models, one settlement layer

`HockeystickVault` and `HockeystickBook` write the same options against the same
oracles and settle them identically. They differ only in who takes the other side.

| | `HockeystickVault` | `HockeystickBook` |
|---|---|---|
| Counterparty | the pool, funded by LPs | another user |
| Who posts collateral | the pool, on every sale | the writer, per contract |
| Who sets the price | on-chain Black-Scholes | the writer's ask |
| Liquidity | always quotes, every strike | only where someone has written |
| Protocol risk | LPs carry the book | none — the protocol never takes a side |

The book exists because the vault's LPs carry unhedged short-option risk. In the
book that risk belongs to whoever chose to write the option, and the protocol
holds nothing but the fee. The cost is a cold start: a strike nobody has written
has no offers, where the vault would have quoted it.

Both keep the invariant that matters — every option is backed at the moment it is
written by collateral equal to its maximum possible payout, so nothing can be
liquidated.

### Deployed — order book, Robinhood Chain testnet (46630)

| Contract | Address |
|---|---|
| HockeystickBook | [`0x71F46421...f4e508df`](https://explorer.testnet.chain.robinhood.com/address/0x71F46421AB4e15af12E63B23eB88c8d2f4e508df) |

**100 markets listed** - 30 tokenized equities, 25 memecoins, 20 crypto majors,
12 index ETFs, 8 commodities and 5 FX pairs. Same TestUSDC collateral. The
catalogue is data, in [`deploy/markets.testnet.json`](deploy/markets.testnet.json),
listed in batches by [`script/ListMarkets.s.sol`](script/ListMarkets.s.sol):

```
BOOK=0x… FROM=0 TO=25 forge script script/ListMarkets.s.sol \
  --rpc-url robinhood_testnet --broadcast
```

Each entry gets its own writable `TestnetAggregator` behind the production
`ChainlinkOracle` adapter, so the adapter and its staleness checks run unchanged
and only the feed is synthetic. Chainlink publishes feeds for a dozen of these
assets on Robinhood Chain mainnet and none for the rest - on mainnet the
catalogue is bounded by what real feeds exist, which is why the stand-in is
testnet-only. Payout caps scale with how far an asset can plausibly run: 10x for
memecoins, 3x for crypto, 2x for equities, 1.2x for FX.

Full record in [`deploy/testnet-book.json`](deploy/testnet-book.json).

First live peer-to-peer trade: 2x 7-day $2,400 ETH puts written for $4,800 locked,
one filled at $60 premium — the writer received $60.00, the protocol kept $0.60 in
fees, and neither pool nor treasury took a position.

The book is two-sided. A writer rests an ask with `writeAndOffer()` and a buyer
takes it with `fill()`; a buyer rests a bid with `placeBid()`, escrowing the
premium, and any writer takes it with `hitBid()`. Both sides are collateralised
before they rest, so nothing on the book can fail to pay. `cancelOffer()` and
`cancelBid()` return what is unfilled.

After expiry: `settle()` once per series (permissionless), then `exercise()` for
holders and `reclaim()` for writers.

Markets can be listed by anyone with `listMarketPermissionless()`. The contract
checks that the feed prices today and carries a staleness bound, and refuses a
duplicate oracle - but it cannot check that a feed is honest, so those markets
carry `verified = false` and the client says so. A rigged market can only take
from people who chose to trade it: every series is collateralised on its own, so
nothing leaks to other markets or to the protocol.

### Settlement keeper

`settle()` is permissionless but needs the oracle round that straddles expiry,
which is an off-chain search. `keeper/keeper.mjs` walks every known series, finds
the boundary round, simulates, and settles. Without it nobody can exercise.

```
BOOK=0x… PRIVATE_KEY=0x… node keeper/keeper.mjs        # loop
BOOK=0x… PRIVATE_KEY=0x… node keeper/keeper.mjs --once # single sweep
```

Verified end to end twice. A 90-second ETH put was bid, hit by a writer, expired,
and settled by the keeper at $2,442 - the price at expiry, not the $2,200 pushed
to the feed afterwards. On the 100-market book, an AAPL $320 put was written and
offered, one contract filled from the ask and one written into a bid, the
unfilled leg cancelled and refunded, then settled by the keeper at $316.46: the
holder took $7.08, the writer reclaimed $632.92, and the $640 lock was
distributed to the cent with the contract left exactly solvent.

The testnet dispute window is 60 seconds rather than an hour, so a tester is not
left waiting to see a payout. On mainnet it should stay at an hour - it exists so
a bad oracle print can be challenged before it is paid out.

## Status

Not audited. Testnet only until it is. The solvency invariant is fuzz-tested,
not formally proven. In `HockeystickVault`, LPs carry unhedged short-option
risk: there is no delta hedging, so a large directional move against the book is
a real loss for the pool. `HockeystickBook` moves that risk onto individual
writers, who choose their own strikes and prices, but a writer is equally
unhedged — the maximum loss is the collateral they posted.
