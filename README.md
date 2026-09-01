<div align="center">
  <img src="brand/logo-lockup.svg#gh-light-mode-only" alt="Hockeystick" width="360">
  <img src="brand/logo-lockup-dark.svg#gh-dark-mode-only" alt="Hockeystick" width="360">
  <br><br>
  <strong>Bet the shape of the move. Not the size.</strong>
  <br><br>
  <a href="https://hockeystick.fun"><strong>hockeystick.fun</strong></a>
</div>

---

## Hockeystick

An on-chain options exchange on Robinhood Chain. Buy a call or a put, and your
downside is capped at the premium you paid — from the moment you sign.

Perpetuals ask you to be right about size and timing at once, then liquidate you for
getting either wrong. Options separate the two. You take a view on the *shape* of a
move, pay a known price for it, and the worst case is fixed before you enter. There is
no margin call, no liquidation price, and no funding rate bleeding the position out at
4am.

**Nothing here can be liquidated, because nothing is ever under-collateralised.** Every
option is backed, at the moment it is written, by collateral equal to its maximum
possible payout. That is the single invariant the contracts exist to hold.

## Live on mainnet

> **Not audited.** This is real money on unaudited contracts. Options can expire
> worthless: a buyer can lose the whole premium, and a writer's collateral is locked
> until expiry. Trade only what you can afford to lose.

| | Address |
|---|---|
| **HockeystickBook** | [`0x5F9eA3a11dA65fbdf559C9f2218DD231d2a11358`](https://robinhoodchain.blockscout.com/address/0x5F9eA3a11dA65fbdf559C9f2218DD231d2a11358) |
| **USDG** (collateral) | [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) |

Robinhood Chain, chain id `4663`. Settles in USDG, the Paxos Global Dollar, 6 decimals.
Four markets live — BTC, ETH, LINK and tokenized AAPL — each against its own Chainlink
feed. Eight more feeds are mapped in [`contracts/deploy/feeds.mainnet.json`](contracts/deploy/feeds.mainnet.json)
and can be listed at any time.

A testnet deployment with 100 markets runs in parallel on chain `46630`; see
[`contracts/deploy/testnet-book.json`](contracts/deploy/testnet-book.json).

## There is no house

The protocol never takes the other side of a trade. It holds no position, quotes no
price, and cannot lose money when you win.

```
buyer  ──fills──►  offer  ◄──written by──  another user
                     │
                     └── that user's collateral, locked until expiry
```

When you buy an option here you are buying it from **another user** who wrote it and
posted their own collateral. If you win, their collateral pays you. Hockeystick matched
you and kept 1% of the premium.

Every outbound transfer in the contract returns money its own counterparty put in. The
only function that pays the protocol is `collectFees`, and it can only draw accrued
fees.

## The order book

Two-sided, and both sides are collateralised before they rest.

| | Posted by | Backed by |
|---|---|---|
| **Ask** — `writeAndOffer()` | a writer | the writer's locked maximum payout |
| **Bid** — `placeBid()` | a buyer | the buyer's escrowed premium |

A writer takes a resting bid with `hitBid()`; a buyer takes a resting ask with `fill()`.
`cancelOffer()` and `cancelBid()` return whatever is unfilled. Nothing quoted on this
book can fail to pay, because the money is already in the contract.

**Permissionless listing.** Anyone can list a market with `listMarketPermissionless()`.
The contract checks the feed prices today, carries a staleness bound, and is not a
duplicate — but it cannot check that a feed is *honest*, so those markets are flagged
`verified = false` and the client says so. The exposure is contained by design: every
series is collateralised on its own, so a rigged market can only take from people who
chose to trade it, never from the protocol or from other markets.

## Settlement

At expiry a series settles against the Chainlink round that **straddled** expiry — the
last round at or before it, with the next round after. Settling against the latest price
instead would let a holder wait for spot to drift in their favour, turning a European
option into a free American one at the writer's expense.

Then a dispute window (one hour on mainnet) before payouts open, so a bad oracle print
can be challenged rather than silently paid out. After that, holders call `exercise()`
and writers call `reclaim()` — the holder takes the payout, the writer takes back what
was not owed.

`settle()` is permissionless, but finding the boundary round is an off-chain search no
wallet can do. [`contracts/keeper/`](contracts/keeper) runs that sweep on a schedule.
The client also offers a Settle button on any expired series, so a holder is never
blocked waiting on the keeper.

## Calls are capped, on purpose

A cash-settled call has unbounded payoff and therefore cannot be fully collateralised.
Every market carries a payout ceiling as a multiple of strike, so a call pays
`min(spot, cap) - strike`. Economically each call is a **call spread**, not uncapped
upside — 3x strike on crypto, 2x on equities.

This is a deliberate, disclosed limitation. The alternative is partial collateral, which
reintroduces the liquidation risk the protocol exists to remove. Puts need no cap: a
zero underlying bounds them at the strike exactly.

## Repository

```
index.html              Marketing site
dapp.html               The exchange client — wallet, book, ticket, positions
contracts/
  src/HockeystickBook.sol    The exchange. Peer-to-peer, no house.
  src/HockeystickVault.sol   Earlier pooled design — NOT IN USE, see below
  src/ChainlinkOracle.sol    Feed adapter with staleness and round checks
  src/lib/BlackScholes.sol   Pricing, in Solidity
  src/testnet/               Writable feed and faucet collateral. Testnet only.
  script/                    Deploy and listing scripts, mainnet path separate
  deploy/                    Deployment records and feed catalogues
  keeper/                    Settlement keeper
  test/                      79 tests, including fuzzed invariants
brand/                  Logos, social cards, and the artboards they render from
```

`HockeystickVault` is an earlier design in which a shared pool underwrites every trade.
It works and is kept for reference, but a pool means the pool carries every loss — so it
is **not part of the exchange** and nothing should be deposited into it.

`server/`, `api/index.js` and `app.html` are a legacy broker-API client from before the
protocol existed. They are unrelated to the exchange and slated for removal.

## Building

Contracts need [Foundry](https://book.getfoundry.sh).

```bash
cd contracts
forge build
forge test            # 79 tests
```

Deploying, in order:

```bash
cp .env.example .env  # PRIVATE_KEY, COLLATERAL, RPC endpoints

# 1. the exchange
COLLATERAL=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 \
  forge script script/DeployBook.s.sol --rpc-url robinhood_mainnet --broadcast

# 2. markets, against real Chainlink feeds
BOOK=0x… FROM=0 TO=4 \
  forge script script/ListMarketsMainnet.s.sol --rpc-url robinhood_mainnet --broadcast
```

`ListMarkets.s.sol` is the **testnet** path: it deploys a writable `TestnetAggregator`
per market, because Chainlink has published no feeds there. Whoever holds that
contract's owner key can set the settlement price of every market reading it, so it must
never reach mainnet — the mainnet script does not import it and cannot deploy one.

The keeper needs a key holding gas and nothing else. `settle()` is permissionless, so
do not give it the deployer key:

```bash
cd contracts/keeper
cp .env.example .env  # PRIVATE_KEY (gas only), BOOK, RPC
npm install
npm run once          # single sweep
npm start             # loop
```

The client is a single dependency-free HTML file. Serve the repository root over any
static server and open `/dapp.html`.

## Risks

- **The contracts are not audited.** A defect could cost you everything in them.
- **Settlement depends on Chainlink** continuing to publish. A feed that dies past its
  staleness bound blocks settlement of that market's series.
- **Writers lock collateral until expiry.** It cannot be withdrawn early, and it is paid
  to the holder if the option finishes in the money.
- **Calls are capped** at a multiple of strike, so upside is not unlimited.
- **Permissionlessly listed markets are not vouched for.** Check `verified` before
  trading one.
- Derivatives trading is restricted or prohibited in many jurisdictions. Knowing whether
  you may use this is your responsibility.

## Brand

The mark is a long-call payoff curve: a flat leg, where loss is capped at the premium,
hinging into an uncapped rising leg. The cyan offset behind the volt stroke is
deliberate riso misregistration, and the dotted rule marks the zero line.

Rendered PNGs are committed, so everyday use needs no build. To regenerate:

```bash
cd brand/src
./render.sh banner.html 1500 500 ../x-banner-1500x500.png
```

`render.sh` drives headless Chrome and takes `<html> <width> <height> <output> [scale]`.
Pass a scale of `2` for retina variants. See [`brand/README.md`](brand/README.md) for
logo selection and the verified social safe zones.

| Face | Role |
|---|---|
| Bricolage Grotesque | Display and headings |
| Instrument Sans | Body copy and interface text |
| DM Mono | Numerals, tickers, and code |

## Contributing

- Keep `index.html` and `dapp.html` self-contained. The client is deliberately
  dependency-free — prefer inlining over adding a bundler.
- Define colors as tokens on `:root` and override them for dark mode. Never give a color
  its only definition inside a media query.
- Every claim on the site must be checkable against the chain. No illustrative numbers.
- Never commit secrets. `.env*` and `.vercel` are ignored.

---

<div align="center">
  <sub>© Hockeystick · MIT</sub>
</div>
