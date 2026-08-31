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

## Interface

This repository contains the Hockeystick web client and brand system.

The client is a single self-contained page — no build step, no bundler, no runtime
dependencies. Markup, styles, and the pricer's roughly 400 lines of vanilla JavaScript
live in one file, and the only external request is a font stylesheet. The payoff chart
renders to `<canvas>`. Light and dark palettes both follow the viewer's OS preference
and can be overridden with an explicit `data-theme` toggle.

```
index.html              Web client — markup, styles, pricer
vercel.json             Hosting config: clean URLs, cache and security headers
brand/
  README.md             Brand guide: logo usage, social specs, safe zones
  logo-lockup.svg       Primary horizontal logo (light and dark variants)
  logo-mark.svg         Standalone mark (light and dark variants)
  logo-badge.svg        Badge treatment
  x-avatar-*.png        Social avatars at 400px and 800px
  x-banner-*.png        Social headers at 1500×500 and 3000×1000
  src/
    avatar.html         Artboard the avatar renders from
    banner.html         Artboard the banner renders from
    shared.css          Design tokens shared by the artboards
    render.sh           Headless Chrome screenshot renderer
    build_assets.py     Asset build driver
    wordmark_path.txt   Wordmark as raw SVG path data
    fonts/              Fonts embedded during rendering
```

### Running locally

No install step. Serve the directory over HTTP:

```bash
python3 -m http.server 8080
```

Then open <http://127.0.0.1:8080>.

To match production routing — `cleanUrls`, `trailingSlash`, and the headers declared in
`vercel.json` — use the Vercel CLI instead:

```bash
vercel dev
```

### Deployment

Deploys from the repository root on Vercel with no build command. `vercel.json` sets:

- `cleanUrls` and `trailingSlash: false` for canonical paths
- `Cache-Control: public, max-age=0, must-revalidate` on `index.html`, so a deploy is
  live immediately instead of being held behind a stale cache
- `X-Content-Type-Options`, `Referrer-Policy`, and `X-Frame-Options` on every route

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
