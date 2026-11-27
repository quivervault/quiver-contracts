# Quiver Executor Agent

Onchain executor assistant for Quiver on Robinhood Chain (4663). It monitors
every Quiver vault and strategy, plans the executor actions that are due,
simulates each one, and executes **exactly one transaction per explicit
operator confirmation**. It never broadcasts on its own and never holds user
funds — vault withdrawals and yield claims stay owner-only in the contracts.

Built 2026-11-27. Shared here for public review (incl. HEY Research Lab)
before the v6 activation on Sunday 29 Nov 2026.

## Usage

```bash
cd executor-agent
npm install                 # ethers
cp config.example.json config.json   # then set local key paths (never commit keys)
node agent.js status        # live read-only report (v1 + v6), loads no keys
node agent.js plan          # proposals + simulation for each, saved to runs/latest-plan.json
node agent.js execute P1 --confirm GAS   # ONE proposal, only after explicit confirmation
node agent.js recall-preview <vault> <strategy> <ETH|USDG> <amount>
```

A plan stays valid for 30 minutes; `execute` refuses stale plans, re-simulates
immediately before broadcast, and stops on any drift.

## What it plans

- **Activation (admin):** `executeStrategyApproval` for the v6 Morpho + LP
  strategies once their timelock elapses.
- **Deploy (executor):** idle vault capital up to each vault's profile cap
  (USDG → Morpho, ETH → LP), only into factory-approved strategies.
- **Supply (executor):** sweep idle USDG in MorphoStrategy into Steakhouse.
- **Mint LP (executor):** one full-range position from unminted principal,
  99.6% minimums (the contract enforces a 99.5% floor).
- **Collect (executor):** LP fees and Morpho/LP yield to the executor wallet.
  Settlement into per-vault yield reserves (`fundYield` + `creditYield`) is
  **never** auto-planned — strategies are pooled and per-vault attribution is
  an operator decision.
- **Recall:** never auto-proposed; preview only on explicit instruction with
  vault + strategy + token + amount.

## Safety model (enforced in code)

- `status`/`plan` never load a private key; simulation uses `eth_call` from
  the known admin/executor addresses.
- `execute` loads exactly one key file (admin or executor, per action),
  verifies the signer address, chain id 4663, target contract code, and gas
  balance, then sends one transaction with pinned fees (maxFee 0.025 gwei,
  gasLimit = estimate × 1.3).
- All v1 LPStrategy writes are hard-blocked by standing instruction.
- Owner-only functions (vault `withdraw` / `claimYield` / `setClaimSchedule`)
  are never called; the agent only reports claim-due status.
- Keys are never printed, logged, or copied. `config.json`, `keys/`, `runs/`
  and `node_modules/` are git-ignored.

## Live state when built (2026-11-27 11:12 WIB, block 123,979,707)

- v6 factory `0xee7f6607aaBb3E62F1Eee7143Cc52AEC93472369`: 0 vaults; Morpho
  `0x8070A912be3E5ed7a92ee98739E1a223c07551A5` and LP
  `0x265F9cfF1fdf2Bf396e3e15Cc6bb3ac8cF09c8Cd` proposed, ETA Sun 29 Nov 2026
  02:34 WIB.
- v1 factory `0x681eE15f4c271143dAbf4a752eAaecB7F015A2E9`: 3 vaults, all
  deposits-paused, principal 0 except bookkeeping dust in the test vault.
- Tested read-only: `status` matches independent manual reads; `plan`
  correctly proposes nothing while the timelock runs; `execute` guards refuse
  without `--confirm GAS` or for unknown proposal ids.

## Files

- `agent.js` — CLI (status / plan / execute / recall-preview)
- `config.example.json` — addresses, policy thresholds, key-path placeholders
- `status.html` — single-file read-only dashboard (browser RPC reads, no keys)
- `package.json` — ethers dependency
