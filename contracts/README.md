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
| HockeystickBook | [`0xA756f9f9...94D2aAB`](https://explorer.testnet.chain.robinhood.com/address/0xA756f9f9CC82e23468B9b62867fEE922094D2aAB) |

Same four markets, same TestUSDC collateral. Full record in
[`deploy/testnet-book.json`](deploy/testnet-book.json).

First live peer-to-peer trade: 2x 7-day $2,400 ETH puts written for $4,800 locked,
one filled at $60 premium — the writer received $60.00, the protocol kept $0.60 in
fees, and neither pool nor treasury took a position.

Writer flow: `writeAndOffer()` to post collateral and an ask, `cancelOffer()` to
withdraw it. Buyer flow: `fill()`. After expiry: `settle()` once per series
(permissionless), then `exercise()` for holders and `reclaim()` for writers.

## Status

Not audited. Testnet only until it is. The solvency invariant is fuzz-tested,
not formally proven. In `HockeystickVault`, LPs carry unhedged short-option
risk: there is no delta hedging, so a large directional move against the book is
a real loss for the pool. `HockeystickBook` moves that risk onto individual
writers, who choose their own strikes and prices, but a writer is equally
unhedged — the maximum loss is the collateral they posted.
