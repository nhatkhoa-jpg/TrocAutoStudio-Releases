# ORACLE A1 — CANONICAL HANDOFF

This file is the durable handoff for any future ChatGPT/Codex/Gemini session working on the user's Oracle A1 stack. Treat it as the canonical baseline unless a later committed change explicitly updates it.

## Owner intent

- Keep Oracle A1 running 24/7 as a private infrastructure/AI worker/VPN server.
- Use it together with the existing Google Cloud worker, not as a replacement.
- Minimize user manual steps; inspect, execute, test and fix directly through GitHub/OCI workflows whenever possible.
- Never switch automatically to a paid non-A1 shape.

## Oracle tenancy / compute baseline

- Home/target region: `ap-singapore-2` (Singapore).
- Instance display name: `troc-cloud-codex`.
- Allowed shape: `VM.Standard.A1.Flex` only.
- Target size: `2 OCPU / 12 GB RAM`.
- Boot volume target: `50 GB`.
- Do not exceed the Always Free A1 envelope without explicit user approval.
- No automatic fallback to paid x86/other shapes.
- Public IPv4 may change when an instance is recreated; NEVER hard-code it as a permanent identifier. Always discover the current VNIC/public IP first.

## Network / security baseline

- VCN name: `troc-codex-vcn`.
- Public subnet name: `troc-codex-public-subnet`.
- Security list name: `troc-codex-public-sl`.
- Long-term public ingress must be restricted to WireGuard only: `UDP/51820`.
- Do not expose Trọc AI port `8787` publicly.
- Do not leave SSH port 22 open to the Internet.
- If bootstrap/recovery requires SSH, open TCP/22 only to the current GitHub Actions runner public IP `/32`, use an ephemeral SSH key, then close TCP/22 at the end.
- WireGuard server network: `10.77.0.1/24`.
- WireGuard MTU baseline: `1380`; tune only after real path testing.
- Reserved owner phone peer: `10.77.0.10/32`.
- Trọc AI private URL through VPN: `http://10.77.0.1:8787`.

## Software baseline on A1

Expected packages/services:

- Ubuntu 24.04 ARM64
- Docker
- Node.js 22
- Gemini CLI
- Codex CLI
- GitHub CLI (`gh`)
- Python 3
- Java 17
- WireGuard
- 4 GB swap
- `troc-ai.service` with restart-always behavior
- Trọc AI updater/timer for app updates from repository `main`

## Trọc AI

- Source repository: `nhatkhoa-jpg/TrocAutoStudio-Releases`.
- Main implementation PR started as PR #2: `Add private Trọc AI mobile gateway for Oracle A1`.
- UI goal: ChatGPT-like mobile-first PWA for direct interaction with the A1 AI gateway.
- Gemini key must stay server-side; never expose it to browser/mobile JavaScript.
- Default model baseline: `gemini-3.5-flash-lite`.
- Private API/UI binds to `10.77.0.1:8787`.
- Health endpoint: `/api/health`.
- Job queue directories live under `/srv/troc-work/`.
- Desired future features: repo/project selector, chat, work/job queue, worker status, logs, diff/build/deploy controls, voice input, installable PWA.

## Gemini / Google API rule

- Gemini Developer API is separate from Google Cloud billing.
- Existing GitHub Secret name: `GEMINI_API_KEY`.
- Do NOT use Gemini API billing from the current Google Cloud billing account unless explicitly requested.
- Extra Google projects/keys may be assigned to separate legitimate workloads, but do not implement quota-evasion key rotation.

## Google Cloud role

- Keep the existing GCP VM as controller/fallback/light worker.
- Existing GCP VM: `troc-cloud-codex-vm`, zone `us-west1-b`.
- Google Cloud is complementary to A1.
- A1 can host additional workers so jobs can run in parallel; avoid two simultaneous heavy Gradle/Next.js builds on a 2-OCPU A1.

## GitHub worker target architecture

- GCP: 1 controller/worker.
- Oracle A1: up to 2 logical workers for light/moderate coding jobs.
- Heavy compile/build tasks should be scheduled carefully because A1 has only 2 OCPU.
- GitHub-hosted Actions may remain faster for clean Android builds because hosted runners have more CPU.
- Do not copy sensitive GitHub credentials from GCP to A1 ad hoc. Register runners using proper short-lived registration credentials or another approved mechanism.

## Recovery / deployment lessons already learned

- OCI Run Command was previously observed stuck at `ACCEPTED`/unreliable during bootstrap; do not assume success from plugin status alone.
- Cloud-init recovery was also observed unreliable on an earlier instance; validate real guest-side effects.
- Ephemeral SSH bootstrap proved to establish a working SSH channel and is the preferred recovery path when needed.
- Always validate the actual guest state, not only GitHub Actions job conclusion.
- Success criteria must include real service tests, especially WireGuard handshake + `Trọc AI /api/health` + a live Gemini chat smoke test (or a clearly identified Gemini Free quota `429`).

## Current operational safety rules

1. Before any destructive recovery, inspect current OCI instance state and confirm shape/RAM/OCPU.
2. Never terminate a healthy A1 merely because a workflow failed; first identify whether the failure is only validation/tooling.
3. Never launch a second unintended A1 in the same compartment.
4. Preserve A1-only safety envelope: `VM.Standard.A1.Flex`, max `2 OCPU / 12 GB`, boot `50 GB` unless the user explicitly changes it.
5. Keep long-term public ingress at `UDP/51820` only.
6. Treat public IP as ephemeral and rediscover it after any recreate.
7. Never print private WireGuard keys, Gemini API keys, OCI private keys, GitHub runner tokens or PATs into logs/comments.
8. Before saying "xong", verify live guest-side evidence.

## How a new session should resume

When the user says something like `tiếp quản Oracle A1`, `làm tiếp A1`, `kiểm tra A1`, or `Trọc AI`, do this first:

1. Read this file from `main`.
2. Inspect latest GitHub Actions runs in `nhatkhoa-jpg/TrocAutoStudio-Releases` related to Oracle A1 / WireGuard / Trọc AI.
3. Inspect PR #2 (or its successor/merged state) and latest commits.
4. Verify current A1 instance state, current public IP and security list through OCI-backed workflows before changing anything.
5. Continue from the latest factual state; do not rely on stale public IPs or old failed workflow messages.

## End-state goal

A stable 24/7 Singapore A1 with:

`Phone/PC -> WireGuard -> Oracle A1 -> Trọc AI -> Gemini API / GitHub jobs`

plus optional GitHub self-hosted workers on A1, while Google Cloud remains available as a separate controller/fallback worker.
