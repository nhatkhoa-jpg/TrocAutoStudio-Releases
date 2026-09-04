# Agent instructions for TrocAutoStudio-Releases

Before changing anything in this repository, read `GEMINI_KEY_ROUTING.md`.

This repository stores release artifacts and also contains Oracle A1 / GCP infrastructure, recovery, and private-server deployment workflows. APK/release artifacts must never contain Gemini/API credentials. Server-side infrastructure that requires Gemini is the **CLOUD** workload and must follow `GEMINI_KEY_ROUTING.md`.

When touching a legacy workflow that still reads generic `GEMINI_API_KEY`, migrate it to `GEMINI_API_KEY_CLOUD` when safe. Until migration is complete, treat generic `GEMINI_API_KEY` only as a compatibility alias for the same CLOUD Free-Tier credential; it is not a separate quota pool.

Never expose credentials in APKs, ZIPs, metadata, logs, screenshots, downloadable assets, or client-side code. Never commit credentials or secrets.
