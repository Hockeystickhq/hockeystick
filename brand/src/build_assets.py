import os
OUT = "/Users/shaan/Marketplay/brand"
os.makedirs(OUT, exist_ok=True)

INK="#14150F"; PAPER="#EDEEE4"; VOLT="#D8EE2E"; UP="#0093B8"; PINUP="#5FE3FF"
D = "M20 67 H49 L80 30"
SW = 9.5

def mark_g(stroke, ghost, rule, rule_op=".24", sw=SW):
    """Mark group in a 0 0 100 100 space."""
    return f'''  <path d="M11 67 H89" stroke="{rule}" stroke-opacity="{rule_op}" stroke-width="1.4" stroke-dasharray="2.5 3.5" fill="none"/>
  <g transform="translate(-2.4,-2.4)" opacity=".9"><path d="{D}" stroke="{ghost}" stroke-width="{sw}" stroke-linecap="butt" stroke-linejoin="miter" fill="none"/></g>
  <path d="{D}" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="butt" stroke-linejoin="miter" fill="none"/>'''

def svg(w,h,vb,body,title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{vb}" fill="none" '
            f'role="img" aria-label="{title}">\n<title>{title}</title>\n{body}\n</svg>\n')

# ---- 1. mark, transparent, for LIGHT backgrounds (ink stroke, volt ghost)
open(f"{OUT}/logo-mark.svg","w").write(
    svg(400,400,"0 0 100 100", mark_g(INK, VOLT, INK, ".22"), "Hockeystick mark"))

# ---- 2. mark, transparent, for DARK backgrounds (volt stroke, cyan ghost)
open(f"{OUT}/logo-mark-dark.svg","w").write(
    svg(400,400,"0 0 100 100", mark_g(VOLT, PINUP, PAPER, ".24"), "Hockeystick mark, dark backgrounds"))

# ---- 3. badge: ink square + volt mark (square app / social icon)
open(f"{OUT}/logo-badge.svg","w").write(
    svg(400,400,"0 0 100 100",
        f'  <rect width="100" height="100" fill="{INK}"/>\n'+mark_g(VOLT, PINUP, PAPER, ".24"),
        "Hockeystick badge"))

# ---- 4. horizontal lockup: badge + outlined wordmark
wm = open("wordmark_path.txt").read().strip()
BADGE=84.0; GAP=26.0; CAP=66.0
# wordmark ink bbox at size 100: x 6.9..580.9, y -75.4..18.4 (baseline 0)
wx = BADGE + GAP - 6.9          # shift so wordmark ink starts right after the gap
by = -75.0                       # badge top (aligned to ascender line)
W = BADGE + GAP + 574.0
def lockup(fg, ghost, rule, badge_bg, badge_stroke, badge_ghost, badge_rule, title, fname):
    body = (f'  <g transform="translate(0,{by}) scale({BADGE/100:.6f})">\n'
            f'    <rect width="100" height="100" fill="{badge_bg}"/>\n'
            + mark_g(badge_stroke, badge_ghost, badge_rule, ".24", sw=SW) + '\n  </g>\n'
            f'  <path transform="translate({wx:.2f},0)" d="{wm}" fill="{fg}"/>')
    vb = f"0 {by-6} {W+6} {(18.4-by)+12}"
    open(f"{OUT}/{fname}","w").write(svg(round(W+6), round((18.4-by)+12), vb, body, title))

lockup(INK, VOLT, INK, INK, VOLT, PINUP, PAPER, "Hockeystick logo", "logo-lockup.svg")
lockup(PAPER, VOLT, PAPER, VOLT, INK, UP, INK, "Hockeystick logo, dark backgrounds", "logo-lockup-dark.svg")

print("wrote:", sorted(os.listdir(OUT)))
