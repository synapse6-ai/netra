# Netra brand assets · Identity v2

Vector logos and icons for Netra. Full guidelines: [Netra Identity v2 — Design System & Brand Guidelines](https://claude.ai/public/artifacts/d5235d04-d586-4b07-bd7a-5d2707a61883).

## Mark

The symbol is a bold **N** with a **Signal Blue** live node (`#0057FF`) at the top-right of the stroke — the focal point for health and attention.

## Files

| File | Use |
| --- | --- |
| [`netra-logo-horizontal.svg`](netra-logo-horizontal.svg) / [`.png`](netra-logo-horizontal.png) | README header — **use PNG in Markdown** (GitHub blocks SVG in README) |
| [`netra-logo-stacked.svg`](netra-logo-stacked.svg) / [`.png`](netra-logo-stacked.png) | README brand section |
| [`netra-symbol.svg`](netra-symbol.svg) / [`.png`](netra-symbol.png) | README footer |
| [`netra-symbol-white.svg`](netra-symbol-white.svg) | Grafana login icon (vector only) |
| [`netra-icon.svg`](netra-icon.svg) / [`.png`](netra-icon.png) | App icon — squircle on Signal Ink |
| [`favicon.svg`](favicon.svg) / [`.png`](favicon.png) | Browser tab / small UI chrome |
| [`social-preview.svg`](social-preview.svg) / [`.png`](social-preview.png) | GitHub social preview (1280×640) |

## Color tokens

| Token | Hex | Use |
| --- | --- | --- |
| Signal Blue | `#0057FF` | Live node · links · brand accent |
| Signal Ink | `#0B0D12` | Dark backgrounds · icon fills |
| Signal Paper | `#F7F8FC` | Light surfaces |
| Signal Green | `#2DBA4E` | Healthy · reconciled |
| Signal Amber | `#F5A623` | Attention · warning |
| Signal Critical | `#D94040` | Critical · page sparingly |
| Signal Mono | `#111111` | Symbol and wordmark on light backgrounds |

## Clear space

Keep at least **0.5× symbol height** of padding around the mark. Do not recolor the live node except for monochrome print (`Signal Mono`).

## In this repo

- **README** — horizontal, stacked, and symbol PNGs via Markdown image syntax
- **Grafana** — `install.sh` mounts `netra-symbol-white.svg` as the login icon via `netra-grafana-branding` ConfigMap
- **GitHub social card** — upload `brand/social-preview.png` (Settings → General → Social preview)

## Voice

Direct, engineering-first, ownership over gloss. Tagline: **Observability you own.**
