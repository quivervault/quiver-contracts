# Security

## Honest status

These contracts are **not yet audited**. They are live on Robinhood Chain
with real funds possible, so treat them accordingly: use small amounts,
and do not deposit anything you cannot afford to lose.

What is already in place:

- Every deployed contract is verified on Sourcify with an **exact match**:
  the sources in this repository are byte-for-byte the code running
  on-chain (creation and runtime).
- Vault withdrawals and yield claims are **owner-only by construction**.
  Neither the factory admin nor the strategy executor has any path to
  withdraw a depositor's principal to itself.
- The executor can only deploy a per-profile capped share of a vault's
  principal, and only into strategies the factory has approved.
- Yield is credited only against tokens actually funded into the vault's
  yield reserve. Nothing is minted or promised from thin air.

## Reporting a vulnerability

If you find a security issue, please do not open a public issue with
exploit details. Reach out privately instead:

- X: [@quivervaultHQ](https://x.com/quivervaultHQ) (DM)

Include the affected contract address, a description of the issue, and a
minimal reproduction if you have one. Reports that help protect depositors
are appreciated and will be credited publicly if the reporter wishes.
