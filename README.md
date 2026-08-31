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

Hockeystick is an on-chain options exchange. Buy a call or a put on any token, index,
or commodity, and your downside is capped at the premium you paid — from the moment
you click.

Perpetuals ask you to be right about size and timing at once, then liquidate you for
getting either wrong. Options separate the two. You take a view on the *shape* of a
move, pay a known price for it, and the worst case is fixed before you enter. There is
no margin call, no liquidation price, and no funding rate bleeding the position out at
4am.

## Why options

| | Perpetuals | Hockeystick |
|---|---|---|
| Worst case | Liquidation, full margin | The premium, known upfront |
| Ongoing cost | Funding, paid continuously | None after entry |
| Position management | Monitor a liquidation price | None required |
| Expresses | Direction and size | Direction, magnitude, and time |

## How it works

**1 — Choose a strike.** Pick the asset, the direction, the strike, and the expiry.
The pricer shows the payoff curve and the break-even before you commit.

**2 — Pay the premium.** One transaction. That premium is the entire cost of the
position and the entire amount at risk.

**3 — Settle on-chain.** At expiry the option settles against an oracle print. Anything
in the money pays out automatically; there is nothing to close manually.

## Strategies

Four shapes cover most of what traders need:

- **Long call** — uncapped upside, loss capped at the premium
- **Long put** — downside exposure or a hedge on spot you already hold
- **Covered call** — sell upside against inventory to earn premium
- **Straddle** — a position on volatility itself, indifferent to direction

The interactive pricer plots profit and loss at expiry against the underlying price for
each of them.

## Markets

Any asset with a qualifying oracle feed and enough depth to hedge against. Majors and
commodities are listed by default. Long-tail tokens can be listed permissionlessly once
their feed clears the liquidity threshold — the condition that keeps unhedgeable meme
markets off the book.

Every market trades against one book, so liquidity is not fragmented across venues.

## Architecture

**Off-chain match, on-chain settle.** Quoting and matching run off-chain, so pricing is
responsive. Settlement and custody stay on-chain, so solvency is verifiable.

**Delta-hedged liquidity pool.** The pool writing the other side of your trade hedges
its directional exposure continuously rather than warehousing naked risk.

**Per-strike exposure caps.** Each strike carries its own cap, which bounds the damage
any single crowded strike can do to the pool.

**Oracle-settled, dispute-windowed.** Expiry settles against an oracle print, with a
dispute window before payouts finalize.

## Running it

Hockeystick routes options orders through [Alpaca](https://alpaca.markets), which
provides an official options trading API. Paper accounts are free, get options Level 3
by default — the approval multi-leg strategies require — and carry no real money.

**1. Get API keys.** Create an account at [alpaca.markets](https://alpaca.markets) and
generate a key pair from the dashboard. Paper and live are separate accounts with
separate keys.

**2. Configure the server.**

```bash
cd server
cp .env.example .env      # then add ALPACA_KEY_ID and ALPACA_SECRET_KEY
npm install
```

`.env` is gitignored. Keys are read only by the server process — the browser never
receives them, and every upstream call is signed server-side.

**3. Verify the connection.**

```bash
npm run check
```

Confirms the keys work, reports which environment you are pointed at, and checks the
account's options level and market-data access before you place anything.

**4. Start.**

```bash
npm start
```

| | |
|---|---|
| Trading client | <http://127.0.0.1:8787/app> |
| Marketing site | <http://127.0.0.1:8787/> |
| API health | <http://127.0.0.1:8787/api/health> |

### Paper and live

`ALPACA_ENV` defaults to `paper`. Setting it to `live` routes real orders against real
money, and the server then refuses any order that does not carry an explicit
`confirmLive` flag, so a misconfigured environment cannot quietly spend capital. The
client banner turns red in live mode, and the order button requires a second click that
names the amount before anything is sent.

## How orders are routed

```
Browser (app.html)  ──►  Node server (server/)  ──►  Alpaca REST API
   no credentials          holds the keys,             options chain,
   ever                    validates every order       greeks, order routing
```

**Order safety is enforced server-side**, not in the UI:

- **Limit orders only.** Market orders are rejected outright. Option books are wide and
  thin, and a market order on a two-cent quote can fill far from the mid.
- **Covered calls are verified covered.** Before routing, the server checks live
  positions for the 100 shares per contract. Short of that it refuses, so the strategy
  can never degrade into a naked short with unbounded loss.
- **Multi-leg fills are atomic.** A straddle routes as `order_class: mleg`, filling both
  legs together or neither. One filled leg would be a directional bet, not the
  volatility position you asked for.
- **Quantities and symbols are validated** before anything reaches the broker —
  fractional contracts, malformed OCC symbols, and wrong leg counts all fail closed.

Run the test suite covering the order builder and payoff math:

```bash
cd server && node --test test/
```

### API

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/health` | Environment, live flag, credential presence |
| `GET` | `/api/account` | Equity, buying power, options level |
| `GET` | `/api/positions` | Open positions with unrealized P/L |
| `GET` | `/api/underlying/:symbol` | Spot bid, ask, last, mid |
| `GET` | `/api/expirations/:symbol` | Available expiries |
| `GET` | `/api/chain/:symbol?expiry=` | Chain by strike with quotes and greeks |
| `POST` | `/api/payoff` | Payoff curve, max loss, max gain, break-even |
| `GET` | `/api/orders` | Order blotter |
| `POST` | `/api/orders` | Route a strategy as a validated order |
| `DELETE` | `/api/orders/:id` | Cancel a working order |

## Layout

```
index.html              Marketing site
app.html                Trading client — chain, pricer, ticket, blotter
vercel.json             Static hosting config for the marketing site
server/
  src/config.js         Environment and endpoint resolution
  src/alpaca.js         Alpaca REST client — the only holder of credentials
  src/strategies.js     The four shapes, order construction, payoff math
  src/routes.js         API surface and order validation
  src/server.js         Express app
  src/preflight.js      Connectivity and entitlement check
  test/                 Order builder and payoff tests
brand/                  Logos, social assets, and the artboards they render from
```

## Brand

The mark is a long-call payoff curve: a flat leg, where loss is capped at the premium,
hinging into an uncapped rising leg. The cyan offset behind the volt stroke is
deliberate riso misregistration, and the dotted rule marks the zero line.

Rendered PNGs are committed, so everyday use needs no build. To regenerate them:

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

- Keep `index.html` self-contained. The client is deliberately dependency-free — prefer
  inlining over adding a bundler or a package manifest.
- Define colors as tokens on `:root` and override them for dark mode. Never give a color
  its only definition inside a media query.
- Never commit secrets. `.env*` and `.vercel` are ignored, and `.env.local` holds a
  Vercel OIDC token that must stay out of version control.

---

<div align="center">
  <sub>© Hockeystick</sub>
</div>
