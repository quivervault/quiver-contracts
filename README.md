# Quiver — smart contracts

Non-custodial yield vaults on **Robinhood Chain**. One isolated vault per
depositor; only the vault owner can withdraw principal or claim yield.
Yield is credited **only** against real tokens funded into the vault's
yield reserve — never minted from thin air.

Live site: https://quivervault.xyz · X: [@quivervaultHQ](https://x.com/quivervaultHQ)

## Deployed contracts (Robinhood Chain, chain 4663)

| Contract | Address | Sourcify |
|---|---|---|
| QuiverVaultFactory | `0x681eE15f4c271143dAbf4a752eAaecB7F015A2E9` | exact match |
| SimpleStrategy (idle, 0%) | `0xf116aEa2e1D7fF46708763927df1Ba499D78ddC1` | exact match |
| PerpStrategy (Lighter funding harvest) | `0xB119368e1E1Abf8DF775577CFBCB103bB8fd2736` | exact match |
| QuiverVault (reference vault) | `0xd01E1ea70F672030d58D9a9BaC1352490a9Eb261` | exact match |

All sources in this repository match the deployed bytecode byte-for-byte
(Sourcify exact match, creation + runtime). Compiler: solc 0.8.24,
optimizer 200 runs.

## How it works

- **QuiverVaultFactory** creates one `QuiverVault` per depositor and keeps
  the registries of supported assets and approved strategies. The factory
  holds no user funds and has no withdraw function.
- **QuiverVault** holds the depositor's principal. The owner alone can
  withdraw and claim. A protocol executor may deploy a capped share of
  capital (per risk profile: 20%–95%) to approved strategies and credit
  yield — capped by the funded yield reserve — but can never withdraw
  to itself.
- **SimpleStrategy** is the starter strategy: capital sits idle (0%).
  It proves the full deploy / recall / withdraw loop end-to-end.
- **PerpStrategy** harvests perpetual funding on Lighter (Robinhood Chain
  deployment): ETH held in the contract is the long spot leg; USDG margin
  is posted to a single whitelisted executor account for a 1x short.
  Margin movement is bounded by an on-chain cap (0 = disabled) set by the
  admin. Realised profit is settled back to each vault's yield reserve.
  Design notes: [PERP_STRATEGY_DESIGN.md](PERP_STRATEGY_DESIGN.md).

## Honest status

- Contracts are **not yet audited**. Use small amounts.
- PerpStrategy is deployed and approved in the factory, with its margin
  cap at 0 (disabled) until the executor's Lighter account is activated.
- Target APRs are variable and derive from trailing perpetual funding
  rates; they are not guaranteed returns.

## Repository layout

- `contracts/` - the four deployed contract sources
- `docs/ARCHITECTURE.md` - roles, flows, and the trust model
- `deployments/` - deployed addresses per network
- `test/` - functional tests of the vault loop on a local EVM
- `PERP_STRATEGY_DESIGN.md` - design notes for the funding-harvest strategy
- `SECURITY.md` - security status and how to report a vulnerability

## Build and test

```sh
npm install
npm run compile   # compiles all contracts into out/
npm test          # runs the vault-loop test suite on a local EVM
```

## License

MIT
