# Midnight.js Integration Options

**Purpose:** How to adopt [midnightntwrk/midnight-js](https://github.com/midnightntwrk/midnight-js) in the NightPay bridge and reduce boilerplate across gateway, UI, and bridge. This doc explains the ideas in plain language and gives concrete options.

Last updated: 2026-06-25 (bridge now targets midnight-js 4.1.1 / ledger-v8 8.0.3 / compact-js 2.5.1; `IndexerFormattedError.cause` → `.errors`; indexer `/api/v4/graphql`)

---

## Where Do I Start?

- **If you maintain the bridge (the TypeScript server that talks to Midnight):** Read “What is Midnight.js?” and “Option A” below. That’s where you get the most benefit.
- **If you only work in this repo (gateway, UI, skill):** Read “What is Midnight.js?” for context, then “Option B” (shared types) and “Option C” (less JSON in gateway) if you want to tidy things up.
- **If you’re new to the stack:** Start with [architecture.md](architecture.md) for components and the bridge API, then come back here.

---

## What is Midnight.js?

**Short version:** Midnight.js is the official JavaScript/TypeScript library for building apps that talk to the Midnight blockchain—similar to how Web3.js is used for Ethereum. It’s maintained by the Midnight team ([GitHub](https://github.com/midnightntwrk/midnight-js)).

**What it gives you:**

1. **One place for “how we talk to Midnight”** — Instead of every app hand-writing HTTP calls to the proof server, the node, and the indexer, Midnight.js provides standard clients (called “providers”) for each. You plug them in and use a common API.
2. **Type safety from your contract** — When you compile `receipt.compact`, you get a `.d.ts` file that describes your circuits (names, argument types, return types). Midnight.js is built to use that file. So in TypeScript you get autocomplete and compile-time checks instead of guessing the shape of `postBounty` or `completeAndReceipt`.
3. **Modular packages** — You don’t have to install one giant bundle. You can add only the proof-server client, or only the types, or the contract helpers, depending on what the bridge actually needs.
4. **Sensible defaults** — The library avoids common pitfalls (e.g. hanging forever on indexer streams) so you spend less time on setup bugs.

**Why we care for NightPay:** Our bridge is the only part that runs the Compact contract and talks to the proof server. Right now that’s done with custom code following “example-bboard.” Using Midnight.js in the bridge means less custom glue, clearer types, and easier upgrades when the SDK or the network changes.

---

## Key Ideas Explained (Less Jargon)

### “Provider pattern”

**Idea:** The bridge needs to talk to several backends: the proof server (to create proofs), something that serves ZK config/artifacts, maybe an indexer, maybe private state storage. Instead of hard-coding “we always call localhost:6300 for proofs,” you pass in a *provider* object that implements a small interface (e.g. “given these inputs, return a proof”). The rest of the code only knows that interface.

**Why it helps:** You can switch the proof server URL, or use a different implementation (e.g. file-based for tests) without rewriting the whole bridge. It also matches how Midnight.js is designed, so using its providers keeps the bridge aligned with the ecosystem.

**Examples of providers in Midnight.js:** ProofProvider (proof server client), ZKConfigProvider (fetch ZK artifacts from a URL or disk), PrivateStateProvider (encrypted storage for private state). We might not need private state on the server for NightPay; witnesses can be built from the request payload.

### “Type-safe contract consumption” / “Compact-generated .d.ts”

**Idea:** When you compile `receipt.compact`, the compiler emits JavaScript (the code that runs the circuits) and a TypeScript declaration file (`.d.ts`) that describes the contract: circuit names, argument types, return types, and the `Witnesses` type. Midnight.js APIs are generic over that: they take your `Contract` and `Witnesses` types and then infer that e.g. `postBounty` expects certain arguments and returns a certain shape.

**Why it helps:** You avoid hand-written types that drift from the real contract. If someone changes a circuit in `receipt.compact`, the generated types change and TypeScript will flag mismatches in the bridge code.

### “Stub mode”

**Idea:** When the proof server or the chain is unavailable, the bridge still responds to HTTP calls with the *same response shape* but marks the answer as non-real (e.g. `stub: true`, no `txId`). Midnight.js doesn’t define this; it’s our design so the gateway and UI can degrade gracefully (e.g. “simulated” or “offline”) instead of hard errors.

---

## What Midnight.js Provides (Technical Summary)

From the [Midnight.js README](https://github.com/midnightntwrk/midnight-js):

- **Provider pattern** — Swap implementations for proof server, ZK config, indexer, private state (e.g. `@midnight-ntwrk/midnight-js-http-client-proof-provider`, `@midnight-ntwrk/midnight-js-fetch-zk-config-provider`).
- **Type-safe contract consumption** — Uses the Compact-generated `.d.ts` (Contract, Witnesses, Ledger) so circuit args/return types are inferred; branded types for domain concepts.
- **Modular packages** — types, contracts, indexer, proof-provider, level-private-state-provider; use only what you need.
- **Reusability** — High-level transaction construction built from low-level utilities; both exported.
- **Default settings** — Reduces setup errors (e.g. indexer stream timeouts).

Our bridge currently follows “example-bboard” patterns (witnesses, server-side). Aligning with Midnight.js can reduce custom wiring and ease upgrades when the SDK evolves.

---

## Option A: Use Midnight.js in the Bridge (Recommended for bridge repo)

**In plain English:** Implement the bridge server using Midnight.js’s providers and contract helpers instead of hand-written code that talks to the proof server and the chain. The HTTP API (paths and request/response shapes) stays the same; only the *internals* of the bridge change.

**Where:** In the **bridge** codebase (private repo or any TypeScript server that implements the [bridge API](architecture.md#bridge-http-api-contract)).

**Why this helps:** You get one standard way to talk to the proof server and ZK config, types that come from the Compact contract so they can’t drift, and less custom code to maintain. When Midnight upgrades their node or SDK, you follow their migration guide instead of rewriting your own glue.

**When to do it:** When you’re ready to refactor the bridge or when you add a new circuit and want type safety end-to-end.

**Steps (summary):**

1. **Dependencies** (align with AGENTS.md and [midnight-js](https://github.com/midnightntwrk/midnight-js)):
   - Use the ledger-8 compatibility matrix versions: e.g. `midnight-js-*@4.1.1`, `wallet-sdk-facade@3.0.0` (+ shielded/unshielded `2.1.0`, dust `3.0.0`, address-format `3.1.0`, hd `3.0.1`), `ledger-v8@8.0.3`, `compact-js@2.5.1`, `compact-runtime@0.16.0`, `onchain-runtime-v3@3.0.0`, `platform-js@2.2.4`. Check [release notes](https://docs.midnight.network/relnotes/overview) when upgrading. Note the breaking change: `IndexerFormattedError.cause` was renamed to `.errors` in midnight-js 4.x; indexer GraphQL endpoint moved to `/api/v4/graphql`.
2. **Provider wiring:**
   - In the bridge, create a ProofProvider that points at your proof server (e.g. `localhost:6300`) and a ZKConfigProvider that fetches or reads ZK artifacts. Pass these into the Midnight.js contract utilities.
   - You only need a PrivateStateProvider if the bridge stores private state between requests. For NightPay, witnesses can be built from each request (jobHash, amount, nonce, etc.), so you may not need persistent private state on the server.
3. **Contract types:**
   - Import the generated `Contract` and `Witnesses` from the compiled output of `receipt.compact`. Use them with Midnight.js so that circuit arguments and return types are inferred—no duplicate hand-written types.
4. **Stub mode:**
   - When the proof server or chain is down, catch the error and still return a valid HTTP response with the same JSON shape, but set `stub: true` and omit `txId`. This is our convention so gateway and UI can show “simulated” or “offline”; Midnight.js doesn’t define it.

**Result:** Less custom proof/indexer/contract code, easier to swap or reconfigure the proof server, and type safety from the contract all the way into the bridge.

---

## Option B: Shared Bridge API Types (This Repo)

**In plain English:** Right now the UI defines its own TypeScript types for bridge responses (e.g. `StatsResponse`, `VerifyResponse`) in `ui/src/api.ts`, and the gateway builds JSON by hand in shell. If the bridge ever changes a field name or adds one, the UI and gateway can get out of sync. Option B is: define the bridge request/response shapes in *one* place so everyone (UI, gateway docs, and the bridge if it’s ever open-sourced) uses the same contract.

**Where:** In the **nightpay** (this) repo, so gateway, UI, and any bridge implementation can share the same “contract” for the API.

**Why this helps:** Fewer bugs from typos or mismatched field names; one place to update when we add or change an endpoint; the UI (and optionally the bridge) can import types instead of redefining them.

**When to do it:** When you’re tired of updating both the UI and the docs when the bridge API changes, or when you want a single checklist of “what the bridge must return.”

**Options:**

1. **Docs-only (what we have now):** The [Bridge HTTP API](architecture.md#bridge-http-api-contract) table in `architecture.md` is the spec. The UI keeps its own types in `ui/src/api.ts`; the gateway uses inline JSON in shell. No code change; just keep the doc up to date.
2. **Shared TypeScript types (optional):**
   - Add a small file in this repo, e.g. `types/bridge-api.ts` (or a single `.d.ts`), that exports:
     - Request/response types: e.g. `PostBountyRequest`, `PostBountyResponse`, `CompleteAndReceiptRequest`, `CompleteAndReceiptResponse`, `VerifyReceiptRequest`, `VerifyReceiptResponse`, `StatsResponse`, `HealthResponse`.
     - Optional: constants for paths, e.g. `BRIDGE_PATHS.postBounty = '/postBounty'`, so nobody hard-codes a typo.
   - The UI imports these types (or uses a path alias to this file). If we ever open-source or share the bridge, it can implement the same types.
   - The gateway stays as shell + JSON; it doesn’t need to run TypeScript. The “single source of truth” is the TypeScript file; humans and scripts can still read it.

**Result:** One place that defines “what the bridge API looks like”; fewer mismatches between UI and bridge; optional reuse by a future open-source bridge.

---

## Option C: Reduce Boilerplate in gateway.sh

**In plain English:** The gateway script calls the bridge by building JSON (e.g. `{ "jobHash": "...", "amount": 123, "nonce": "..." }`) and parsing the response (e.g. to get `txId` and `stub`). Right now that’s done with several similar `python3 -c "import sys, json; ..."` one-liners. Option C is either (1) documenting the pattern clearly so everyone builds/parses the same way, or (2) moving that logic into a small helper script so we only maintain the payload shapes in one place.

**Where:** In the **nightpay** repo, in and around `skills/nightpay/scripts/gateway.sh` (and optionally a small helper script in the same folder).

**Why this helps:** When we add a new bridge endpoint or change a field, we don’t have to hunt through long shell scripts; we have one pattern or one script that knows the bridge API.

**When to do it:** When you find yourself copying another `python3 -c` block for a new endpoint, or when a field rename in the bridge breaks the gateway and you want to avoid that.

**Ways to reduce boilerplate:**

1. **Document the pattern (minimal change):** Write down clearly: “All bridge POST responses that we use include `stub`; when not stub, they include `txId`.” Put this in `docs/architecture.md` and add a short comment next to `bridge_post`/`bridge_get` in the gateway pointing to that doc. No new files; just one place to look when someone changes the API.
2. **Helper script (optional):** Add a small script, e.g. `skills/nightpay/scripts/bridge-json.sh` or a tiny Python script, that:
   - **Build payload:** Given a command name (e.g. `postBounty`) and key-value args, prints the JSON body for that endpoint.
   - **Parse response:** Given the raw bridge response, prints `txId` and `stub` (or similar) so the gateway can use them in shell variables.
   - The gateway then calls this script instead of repeating inline Python. The payload shapes live in one place and should match `architecture.md`.
3. **Keep current style:** If you prefer not to add another file, keep the inline Python but add a comment at the top of the bridge-calling block: “Payload and response shape: see docs/architecture.md Bridge HTTP API.” So future edits know where the source of truth is.

**Result:** Less duplicated JSON logic; easier to add or change bridge endpoints without scattering changes across the gateway.

---

## Option D: Do Not Add Midnight.js to This Repo

**In plain English:** The nightpay repo you’re in now contains the Compact contract, the gateway script, the UI, and the skill definition. It does *not* contain the bridge server. No code in this repo runs the Compact runtime or talks to the proof server—only the bridge does. So we don’t need to add Midnight.js as a dependency *here*.

**What this repo *does* do:** (1) Define and document the bridge API (in `architecture.md`), (2) optionally define shared TypeScript types for that API (Option B), and (3) document how the bridge *could* use Midnight.js and how we can reduce gateway boilerplate (this file and Option C). That way, whoever implements or maintains the bridge has clear guidance, and the rest of the project stays consistent without pulling in SDK code we don’t run.

---

## Summary

| Area | Action |
|------|--------|
| **Bridge (other repo)** | Use Midnight.js provider pattern + Compact-generated types; keep stub behaviour so gateway/UI get consistent responses when offline. |
| **This repo** | Keep bridge API spec in `architecture.md`; optionally add shared types (Option B) and a small bridge-json helper (Option C). |
| **ECOSYSTEM.md** | Track Midnight.js version (e.g. 4.1.1); refresh when SDK or Compact tools change. |

**Takeaway:** Implementing **Option A** in the bridge gives the largest benefit (type safety, less custom SDK code, easier upgrades). **Options B and C** in this repo improve consistency and reduce boilerplate without requiring the bridge code to live here. You can do B and C even if the bridge hasn’t adopted Midnight.js yet.

---

## Glossary (terms used in this doc)

| Term | Meaning |
|------|--------|
| **Bridge** | The TypeScript server that talks to the proof server and Midnight node; exposes the HTTP API used by gateway and UI. |
| **Circuit** | A piece of on-chain logic defined in the Compact contract (e.g. `postBounty`, `completeAndReceipt`). Inputs go in, the chain runs it, outputs come out. |
| **Compact** | The smart contract language used for Midnight; our contract is `receipt.compact`. |
| **Proof server** | Service that generates zero-knowledge proofs from circuit inputs; the bridge sends inputs and gets back a proof to submit to the chain. |
| **Provider** | In Midnight.js, an object that implements a small interface (e.g. “get a proof from these inputs”). Lets you swap backends without changing the rest of the code. |
| **Stub mode** | When the bridge can’t reach the proof server or chain, it still returns a valid response with `stub: true` so callers can show “simulated” or “offline.” |
| **Witness** | Private input to a circuit (e.g. funder’s secret, nonce). In NightPay, the bridge can build witnesses from the HTTP request payload; we don’t need to store private state on the server. |
| **ZK** | Zero-knowledge: prove something is true without revealing the underlying data (e.g. “this receipt is valid” without revealing who paid). |

---

## Further reading

- [architecture.md](architecture.md) — Components, bridge API table, data flow.
- [ECOSYSTEM.md](ECOSYSTEM.md) — Version table, Midnight/Masumi/OpenClaw links, refresh checklist.
- [Midnight.js README](https://github.com/midnightntwrk/midnight-js) — Official intro and package list.
- [Midnight release notes](https://docs.midnight.network/relnotes/overview) — Breaking changes and version alignment.
