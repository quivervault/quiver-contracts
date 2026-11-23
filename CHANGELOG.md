# Changelog

## 0.1.0 - 2026-11-24

Initial public release of the contract sources.

- Published the sources of the four contracts live on Robinhood Chain:
  `QuiverVaultFactory`, `QuiverVault`, `SimpleStrategy`, and
  `PerpStrategy`. All four are verified on Sourcify with an exact match
  against the deployed bytecode.
- Added `deployments/robinhood-chain.json` with the deployed addresses.
- Added a functional test suite (`npm test`) that runs the full vault
  loop on a local EVM: vault creation, ETH deposit, capped strategy
  deployment, recall, withdrawal, and the funded-yield claim path,
  including the cap and access-control reverts.
- Added architecture notes (`docs/ARCHITECTURE.md`), a security policy
  (`SECURITY.md`), and CI that compiles the contracts and runs the tests
  on every push.

Status at release: contracts unaudited; PerpStrategy deployed and
approved with its margin cap at 0 (disabled) until the executor's
Lighter account is activated.
