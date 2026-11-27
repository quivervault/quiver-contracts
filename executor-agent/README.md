# Quiver Executor Agent

On-chain executor assistant for Quiver (Robinhood Chain, chain id 4663). It
monitors every Quiver vault and strategy, plans the executor actions that are
due, simulates each one, and executes exactly one transaction per explicit
human confirmation. It never broadcasts on its own and never holds user
funds: vault withdrawals and yield claims stay owner-only in the contracts.

## Safety model

- `status` and `plan` never load a private key. Previews simulate with
  `eth_call` from the known admin/executor address.
- `execute` runs exactly one previewed proposal, only with
  `--confirm <hash>`, the short hash of that proposal's target + calldata
  printed by `plan`. The hash is recomputed from the stored proposal before
  any key is loaded, and execution refuses on mismatch, so re-running `plan`
  can never silently swap what gets signed. `execute` re-simulates, checks
  chain id, contract code, and signer balance, and refuses to broadcast
  when the live gas price exceeds the configured fee cap. No loops, no
  batching.
- Owner-only functions (vault withdraw, claimYield, setClaimSchedule) are
  never called. The agent only reports claim-due status.
- Retired factories are status-only in code: a factory receives proposals
  only when its config explicitly sets `statusOnly: false`. A missing flag
  reads as blocked (fail-closed), so v1 can never receive a deploy, supply,
  collect, or LP write from this agent.
- One-sided LP mints are never proposed (they revert on-chain); the planner
  notes when a ratio swap is needed first instead.
- Yield settlement into per-vault reserves is never auto-planned: strategies
  are pooled and per-vault attribution is a human decision. Collect
  proposals stop at the executor wallet.
- Keys are read from local key files (mode 600) and are never printed,
  logged, or copied. Copy `config.example.json` to `config.json` and point
  `adminKeyPath` / `executorKeyPath` at your own files.

## Usage

```
npm install
node agent.js status                      # live read-only report (v1 + v6)
node agent.js plan                        # proposals + simulations, saved to runs/
node agent.js execute P1 --confirm <hash> # run ONE proposal from the latest plan
node agent.js recall-preview <vault> <strategy> <ETH|USDG> <amount>
```

Normal flow: run `plan`, review the preview (target, amount, gas, simulation
result), then `execute <id> --confirm <hash>` with the confirm hash `plan`
printed for that specific proposal. A plan is valid for 30 minutes; after
that, re-plan.

## HEY Research Lab integration

`status` also reads Quiver's public record on HEY Research Lab
(heyresearch.xyz) so the on-chain view can be compared with what HEY has
recorded. Every HEY call sends the integration header:

```
x-hey-integration: quiver-executor/1.0.0
```

Endpoints read (public, no key, read-only):

- `GET /api/token/4663/<QUIV contract>` — token to project record
- `GET /api/projects/quivervault/snapshot` — one-read project state

The read fails soft: if HEY is unreachable, the on-chain status still prints.

## Contracts

Quiver vault contracts, deployments, and review history live in this
repository (see `contracts-v6/` and `deployments/`). The v6 factory is
`0xee7f6607aaBb3E62F1Eee7143Cc52AEC93472369` on Robinhood Chain.
