# Gemini Free-Tier Key Routing — durable owner policy

Status: active from 2026-09-05. This repository stores release artifacts **and** contains Oracle A1 / GCP infrastructure and recovery workflows. Never place actual key values in Git, logs, issues, APKs, ZIPs, metadata, screenshots, or downloadable assets.

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

## This repository's runtime routing

- APK/release publication itself must not use or embed a Gemini credential.
- Oracle A1, GCP Cloud Codex, private AI gateway, recovery/bootstrap and other server-side infrastructure workflows in this repository that require Gemini belong to the **CLOUD** workload.
- New or edited infrastructure workflows must read `GEMINI_API_KEY_CLOUD` and map it to `GEMINI_API_KEY` only inside the authorized server-side job/process when required by existing software.
- Some older infrastructure workflows may still reference the generic GitHub secret `GEMINI_API_KEY`. During migration, that generic secret is a **compatibility alias only** and must contain the same CLOUD Free-Tier credential as `GEMINI_API_KEY_CLOUD`; it is not an eighth quota pool.
- Do not migrate Google Cloud Text-to-Speech, OCI credentials, WIF credentials, signing material or other unrelated credentials into Gemini secrets.

## Shared rules

1. Never commit actual secret values.
2. Never round-robin project keys to bypass provider quotas.
3. `RESERVE_01` and `RESERVE_02` are manual reserve capacity only.
4. Never auto-failover Free Tier traffic to Paid Tier.
5. GitHub Actions secrets do not automatically become Oracle/Vercel/Cloudflare runtime variables. A deployment workflow must explicitly inject the assigned secret into the trusted server.
6. Never inject a central Gemini key into an Android APK, browser bundle, downloadable artifact, or client-visible configuration.
7. Any future agent must read this file and `AGENTS.md` before changing Gemini/infrastructure integrations.
