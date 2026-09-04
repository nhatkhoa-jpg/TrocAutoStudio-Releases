# Gemini Free-Tier Key Routing — durable owner policy

Status: active from 2026-09-05. This repository is release-artifact storage and must not use Gemini at runtime.

## Google AI Studio project pool

| Role | Google project | GitHub Actions secret |
|---|---|---|
| DEV / TEST | `gen-lang-client-0291732397` | `GEMINI_API_KEY_DEV` |
| YOUTUBE | `troc-gm-youtube-c9df76d5` | `GEMINI_API_KEY_YOUTUBE` |
| FACEBOOK | `troc-gm-facebook-c9df76d5` | `GEMINI_API_KEY_FACEBOOK` |
| NIKAYA | `troc-gm-nikaya-c9df76d5` | `GEMINI_API_KEY_NIKAYA` |
| CLOUD | `troc-gm-cloud-c9df76d5` | `GEMINI_API_KEY_CLOUD` |
| RESERVE 01 | `troc-gm-reserve1-c9df76d5` | `GEMINI_API_KEY_RESERVE_01` |
| RESERVE 02 | `troc-gm-reserve2-c9df76d5` | `GEMINI_API_KEY_RESERVE_02` |

All seven projects are intended to remain Free Tier unless the owner explicitly changes that policy.

## This repository

`nhatkhoa-jpg/TrocAutoStudio-Releases` is for release artifacts only. Do not add Gemini runtime calls here and do not embed any Gemini credential into APKs, release ZIPs, metadata, logs, or downloadable assets.

## Shared rules

- Never commit actual secret values.
- Never round-robin project keys to bypass provider quotas.
- `RESERVE_01` and `RESERVE_02` are manual reserve capacity only.
- Never auto-failover Free Tier traffic to Paid Tier.
- GitHub Actions secrets do not automatically become Vercel/Oracle/Cloudflare runtime variables.
- Any future agent should read the code repository's `GEMINI_KEY_ROUTING.md` and `AGENTS.md` before changing Gemini integrations.
