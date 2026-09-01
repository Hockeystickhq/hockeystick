# Hockeystick — brand assets

Built on the site's own design system (`index.html`): riso-print trading floor —
paper ground, hard ink rules, volt accent, cyan/magenta misregistration.

## The mark

A long-call payoff curve: a **flat leg** (loss capped at the premium) hinging into an
**uncapped rising leg**. The cyan offset behind the volt stroke is deliberate riso
misregistration. The dotted rule is the zero line.

## Upload to X

| File | Where | X spec |
|---|---|---|
| `x-avatar-400.png` | Profile picture | 400×400, cropped to a circle |
| `x-avatar-800.png` | Profile picture (retina) | 800×800 — upload this one; X downsamples |
| `x-banner-1500x500.png` | Header | 1500×500 (3:1) |
| `x-banner-3000x1000.png` | Header (retina) | upload this one; 535 KB, well under X's 2 MB cap |
| `x-live-1600x900.png` | Launch post image | 1600×900 (16:9) |
| `x-live-3200x1800.png` | Launch post image (retina) | upload this one |
| `x-shapes-1600x900.png` | The four strategies, post image | 1600×900 (16:9) |
| `x-shapes-3200x1800.png` | The four strategies (retina) | upload this one |
| `x-locked-1600x900.png` | Locked-supply card, post image | 1600×900 (16:9) |
| `x-locked-3200x1800.png` | Locked-supply card (retina) | upload this one |
| `x-mainnet-1600x900.png` | Mainnet-soon card, post image | 1600×900 (16:9) |
| `x-mainnet-3200x1800.png` | Mainnet-soon card (retina) | upload this one |

**Banner safe zones** (verified against a 600px X profile mock):
- Profile photo overlaps roughly `x 40–385, y 332–500`. Nothing lives there — the ticker
  starts at `x=414`, the tagline clears the circle's top arc.
- All type sits inside `x 88–1419`, so mobile side-cropping never clips it.

## Logo files

| File | Use |
|---|---|
| `logo-lockup.svg` | Primary horizontal logo, light backgrounds |
| `logo-lockup-dark.svg` | Primary horizontal logo, dark backgrounds |
| `logo-badge.svg` | Square icon — favicon, app icon, avatar source |
| `logo-mark.svg` | Mark only, transparent, light backgrounds |
| `logo-mark-dark.svg` | Mark only, transparent, dark backgrounds |

Wordmark text is converted to outlines, so the SVGs need no fonts installed.
The mark sits in a `0 0 100 100` box with built-in padding — don't add more.
Minimum size: 24px for the badge, 32px for the lockup.

## Palette (from `index.html`)

| Token | Hex | Role |
|---|---|---|
| `--paper` | `#EDEEE4` | Banner ground |
| `--ink` | `#14150F` | Type, rules, badge ground |
| `--volt` | `#D8EE2E` | Accent — the rising leg |
| `--up` | `#0093B8` | Profit wash, ghost offset on light |
| `--pin-up` | `#5FE3FF` | Ghost offset on ink |
| `--down` | `#E0246F` | Capped-loss wash |

## Type

Bricolage Grotesque 800 (wordmark) · Instrument Sans 500 (tagline) · DM Mono 500 (all
mono labels). Same three faces the site loads. TTFs are vendored in `src/fonts/`
(SIL Open Font License).

## Regenerating

```sh
cd src
./render.sh banner.html 1500 500 ../x-banner-3000x1000.png 2
./render.sh avatar.html  400 400 ../x-avatar-800.png 2
./render.sh live.html   1600 900 ../x-live-3200x1800.png 2
./render.sh shapes.html 1600 900 ../x-shapes-3200x1800.png 2
./render.sh locked.html 1600 900 ../x-locked-3200x1800.png 2
./render.sh mainnet.html 1600 900 ../x-mainnet-3200x1800.png 2
python3 build_assets.py          # rebuilds the SVGs (needs fonttools)
```

`render.sh` drives headless Chrome. Edit `banner.html` / `avatar.html` / `live.html` / `shapes.html` / `locked.html` / `mainnet.html` to change copy —
the payoff chart geometry is the `kx, ky, zero, ex, ey, sx` constants in `banner.html`.

## Note on copy

The banner claims only what the site claims — no invented metrics, handles, or URLs.
Add a domain to the bottom band once one is live.

`mainnet.html`'s twelve tickers and its step copy come from `contracts/deploy/` —
`feeds.mainnet.json` for the listings, `testnet.json` for what is already deployed.
Re-read those files before changing the card, so it never claims more than the chain does.

`locked.html` ships with its four stat tiles unfilled (`—`, `0x…`) on purpose. Every
value on that card is a claim someone will check on an explorer, so fill them from the
deployed lock contract before rendering — never from an estimate.
