# Quiver PerpStrategy — Design (v1 draft, 2026-11-24)

Goal: give Quiver vaults a real yield source from perpetual-market funding, using
**Lighter** on Robinhood Chain, without breaking Quiver's core rule — every
depositor's vault stays isolated and self-custodied.

## What the research established

- Perps on Robinhood Chain are real and liquid (DefiLlama, 23 Nov 2026):
  $721M volume / 24h, $228M open interest.
- **Lighter** is the dominant venue ($585M / 24h, ~$97M TVL) and the one
  integrated into Robinhood Wallet. Margin on the Robinhood Chain deployment
  is **USDG** — which Quiver already supports in the factory.
- Lighter's order flow is **off-chain**: an account is owned by an L1 wallet
  address; trading is done with registered **API keys** (indexes 4–254,
  registered once with a wallet signature); orders are signed L2 transactions
  submitted to Lighter's API. A Solidity contract cannot place orders.
- Safety property worth using: Lighter API-key withdrawals can only send
  funds **back to the account owner's wallet**. A leaked trading key cannot
  drain funds to a third party.
- Arcus (2nd venue) has the same off-chain model (Ed25519 trading keys) —
  no advantage for us. Meridian/Scion are too small.

## Architecture

Three components:

### 1. PerpStrategy contract (on-chain, Robinhood Chain)
Implements the same strategy interface the factory already approves, so vaults
use it exactly like SimpleStrategy — but instead of idling, it manages a
funding-harvest bookkeeping ledger:

- Accepts deployed capital from vaults (existing executor flow, existing
  per-profile caps 20–95% still enforced by the vaults themselves).
- Tracks **per-vault shares** of the strategy (deposit-weighted), so PnL is
  credited pro-rata and vaults stay isolated in accounting even though margin
  is pooled operationally on the exchange (unavoidable — an exchange account
  is a single account).
- `sendMargin(amount)` — moves USDG margin to the Lighter deposit path for
  the **one whitelisted executor account**. Hard-coded whitelist; no other
  destination is possible from this contract.
- `receiveSettlement(amount)` — accepts returned USDG (margin + realised PnL)
  from the executor wallet only.
- `creditYield(vault, amount)` — credits realised, actually-received yield to
  a vault, consistent with the existing rule: yield is only credited against
  funds actually held. Unrealised exchange PnL is NEVER credited.
- Pause switch (admin): stops new margin sends; withdrawals of vault
  principal from the strategy remain open.

### 2. Executor bot (off-chain, run by the control wallet)
A small service holding the Lighter API key for the executor account:

- **Strategy: delta-neutral funding harvest.** For each unit of margin:
  short ETH perp on Lighter at 1x (fully collateralised by design), while
  the matching long spot ETH stays in the PerpStrategy contract on-chain.
  PnL ≈ funding received − fees. No directional bet, no leverage stacking.
- Rebalances when vault deposits/withdrawals change the deployed total.
- **Risk loop (every minute):** check margin ratio; if it falls below the
  safety threshold, reduce the short (never add), and alert. If the API or
  price feed is unreachable for >N minutes, flatten to neutral and alert.
- **Settlement loop (daily):** withdraw realised profit above the margin
  target from Lighter (withdrawals can only return to the executor wallet),
  forward it to PerpStrategy `receiveSettlement`, then credit vaults pro-rata.
- Kill switch: a single command (and an on-chain pause flag it watches)
  flattens all positions and returns all margin.

### 3. Reconciliation (public verifiability)
- The bot publishes a daily snapshot: Lighter account equity, open position,
  funding collected, amounts settled on-chain (tx hashes).
- Anyone can check: strategy contract balance + Lighter account equity ≈
  total deployed + credited yield. Discrepancy = visible immediately.

## Trust model — stated plainly

Quiver's vaults remain non-custodial. The perp leg adds ONE trusted
component: the **executor wallet** temporarily holds exchange margin, the
same wallet that is already factory admin + executor today. Mitigations:

- Margin float kept minimal (target = required margin + small buffer);
  profits swept daily.
- PerpStrategy can only ever send margin to that one account.
- Lighter withdrawals can only return to that same wallet — a compromised
  API key can trade badly but cannot exfiltrate funds.
- Per-profile caps still bound how much of any vault can be deployed.
- This trust assumption must be disclosed on the website wherever the perp
  strategy is described. No hidden custody.

## Rollout phases

- **Phase 0 — verification (no funds):** confirm the Robinhood Chain Lighter
  deployment specifics (deposit contract address, API endpoints for this
  deployment — they differ from the zkLighter mainnet ones — USDG margin
  markets list, ETH perp funding history). Register the executor account and
  API key; paper-trade the bot against the API.
- **Phase 1 — tiny live test:** deploy PerpStrategy, approve it in the
  factory, run the full loop with the control wallet's own test vault and a
  few dollars of USDG. Verify funding actually arrives and settlement credits
  the vault. (Needs USDG in the control wallet — it currently holds none.)
- **Phase 2 — automation:** bot as a supervised service, alerts to chat,
  daily reconciliation snapshots.
- **Phase 3 — before any real scale:** independent contract audit, and the
  website copy updated to describe the perp strategy + trust model honestly.

## Open questions to close in Phase 0

1. Exact Lighter deposit/withdraw contract + API base URL on Robinhood Chain.
2. Whether ETH perp funding on Lighter (Robinhood deployment) is
   persistently positive enough to beat fees — pull 30 days of funding data.
3. Minimum deposit / minimum order sizes on that deployment.
4. Whether sub-accounts can map 1:1 to vaults later (would restore full
   on-exchange isolation); v1 assumes one pooled account + share accounting.

## Status update (2026-11-24): BUILT + DEPLOYED

Febri ordered the test phase skipped ("lewati saja tes nya dan buat").
- **PerpStrategy deployed: 0xB119368e1E1Abf8DF775577CFBCB103bB8fd2736**
  (deploy tx 0x069985325bd043c538c3336774d34c325cd03ee9812139c43a2b7d1ea7b6e540)
  and **approved in the factory** (setStrategy tx
  0xdf58dcf20d514e9bf63e10e33f16138c7d615f5c554cb87ad5d4889fc7d762b0;
  approvedStrategy = true, verified on-chain). Margin cap = 0
  (sendMargin disabled, fail-closed) until an admin tx sets it.
- Executor bot v1 (monitor + planner, read-only) at
  ~/workspace/quiver-admin/perp-bot/perp_bot.mjs — verified running against
  the deployed strategy. Live order placement stays locked until the
  executor's Lighter account + API key exist.
- First deploy attempt failed pre-broadcast (ethers maxFee buffer vs tiny
  balance); febri topped up ±0.0000421 ETH and the deploy then succeeded.
  Total gas for both txs: 0.0000251 ETH; control wallet left at 0.0000448 ETH.
- Still blocking live trading: the executor Lighter account is created by a
  first deposit (ETH or USDG) from the control wallet — the control wallet
  holds neither USDG nor enough ETH for the $10 minimum order.

## Phase 0 findings (verified live, 2026-11-24)

- App: https://robinhoodchain.lighter.xyz (HTTP 200). REST base:
  **https://api.rh.lighter.xyz**. Signing chain ID **466324**; quote asset USDG.
- Deposit/withdraw contract (from `GET /info`):
  **0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d** (proxy; implementation not
  source-verified on Sourcify).
- 73 markets listed. **ETH perp = market_id 0**, active; min base 0.005 ETH,
  min quote $10; size decimals 4, price decimals 2; default initial margin
  fraction 5000 (50%). USDG is a margin-enabled asset.
- **ETH funding, last 30 days (720 hourly settlements, pulled from
  `/api/v1/fundings`):** a 1x short would have earned **mean ≈ 6.7% APR**
  (median ≈ 10.5%); longs paid shorts in 86% of hours, shorts paid in 12%;
  worst single hour −0.0029%. Cross-checked against the venue's current
  funding-rates quote (8h-equivalent fraction) — magnitudes agree.
  → Funding harvest alone roughly covers Quiver's Conservative–Growth target
  range (3.8–7.8%); it does NOT by itself reach Advanced/Aggressive targets.
- Trading fees on this deployment are reported as zero maker/taker
  (third-party integration notes; not yet confirmed from an official fee
  schedule).
- Still open: account + API-key registration requires a first USDG deposit
  (the account is created on first credited deposit). The control wallet
  holds no USDG, so registration is blocked on a small funding decision.
  Paper-trading environment for the RH deployment: unconfirmed.

## What this design does NOT do

- No leverage >1x on the short leg, no directional positions, no other
  venues, no other assets than ETH perp vs USDG margin in v1.
- No yield is promised or credited before it is realised and received
  on-chain — the APR figures on the website remain targets, as today.
