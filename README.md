<div align="center">
  <img src="brand/logo-lockup.svg#gh-light-mode-only" alt="Hockeystick" width="360">
  <img src="brand/logo-lockup-dark.svg#gh-dark-mode-only" alt="Hockeystick" width="360">
  <br><br>
  <strong>Bet the shape of the move. Not the size.</strong>
  <br><br>
  <a href="https://hockeystick.fun">hockeystick.fun</a>
</div>

---

## Overview

Hockeystick offers on-chain options on any token, index, or commodity. You buy a call
or a put, and your loss is capped at the premium you paid — from the moment you click.
No margin calls, no liquidation price, no funding rate draining the position overnight.

This repository holds the **marketing site and brand system**: a single self-contained
landing page plus the source and rendered artwork for the Hockeystick identity. The
protocol contracts are not part of this repository.

## The site

`index.html` is a standalone page — no build step, no bundler, no runtime dependencies.
Markup, styles, and roughly 400 lines of vanilla JavaScript live in the one file. The
only external request is a Google Fonts stylesheet.

| Section | Anchor | What it covers |
|---|---|---|
| Hero | `#top` | Positioning and primary call to action |
| Markets | `#markets` | Every market on one book — majors, commodities, long-tail tokens |
| Pricer | `#pricer` | Interactive payoff chart rendered to `<canvas>` |
| Strategies | `#strategies` | Long call, long put, covered call, straddle |
| How it works | `#how` | Choose a strike → pay the premium → settle on-chain |
| Architecture | `#earn` | Off-chain match with on-chain settlement, delta-hedged liquidity pool, per-strike exposure caps, oracle settlement with a dispute window |
| Close | `#cta` | Final call to action |

The page ships light and dark palettes. Both follow the viewer's OS preference by
default and can be overridden by an explicit `data-theme` toggle.

## Repository layout

```
index.html              Complete landing page — markup, styles, and scripts
vercel.json             Hosting config: clean URLs, cache and security headers
brand/
  README.md             Brand guide: logo usage, X/social specs, safe zones
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

## Running locally

No install step is required. Serve the directory over HTTP and open it:

```bash
python3 -m http.server 8080
```

Then visit <http://127.0.0.1:8080>.

Opening `index.html` directly via `file://` mostly works, but a real HTTP origin is
recommended so font loading and caching behave the way they do in production.

To match production routing — `cleanUrls`, `trailingSlash`, and the headers declared in
`vercel.json` — use the Vercel CLI instead:

```bash
vercel dev
```

## Deployment

The site is hosted on Vercel and deploys straight from the repository root; there is no
build command. `vercel.json` sets:

- `cleanUrls` and `trailingSlash: false` for canonical paths
- `Cache-Control: public, max-age=0, must-revalidate` on `index.html`, so a deploy is
  visible immediately rather than being held by a stale cache
- `X-Content-Type-Options`, `Referrer-Policy`, and `X-Frame-Options` on every route

## Brand assets

The mark is a long-call payoff curve: a flat leg, where loss is capped at the premium,
hinging into an uncapped rising leg. The cyan offset behind the volt stroke is
deliberate riso misregistration, and the dotted rule marks the zero line.

Rendered PNGs are committed, so day-to-day use needs no build. To regenerate them from
the artboards:

```bash
cd brand/src
./render.sh banner.html 1500 500 ../x-banner-1500x500.png
```

`render.sh` drives headless Chrome and takes `<html> <width> <height> <output> [scale]`.
Pass a scale of `2` for retina variants. See [`brand/README.md`](brand/README.md) for
logo selection guidance and the verified social-media safe zones.

### Typography

| Face | Role |
|---|---|
| Bricolage Grotesque | Display and headings |
| Instrument Sans | Body copy and interface text |
| DM Mono | Numerals, tickers, and code |

## Conventions

- Keep `index.html` self-contained. The page is deliberately dependency-free — prefer
  inlining over adding a bundler or a package manifest.
- Define colors as tokens on `:root` and override them for dark mode. Never give a
  color its only definition inside a media query.
- Never commit secrets. `.env*` and `.vercel` are ignored, and `.env.local` holds a
  Vercel OIDC token that must stay out of version control.

---

<div align="center">
  <sub>© Hockeystick</sub>
</div>
