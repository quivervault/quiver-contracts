# Contributing

Thanks for looking at the code. This repository publishes the exact
sources of the contracts deployed on Robinhood Chain, so changes here do
not change anything on-chain; they document, test, and prepare future
versions.

## Build and test

```sh
npm install
npm run compile   # compiles all contracts into out/
npm test          # functional test of the vault loop on a local EVM
```

The test suite deploys the factory, the idle strategy, and a vault to a
throwaway local chain and exercises the full loop: create vault, deposit,
deploy to strategy within the profile cap, recall, withdraw, and the
funded-yield claim path. It must pass before any pull request is merged.

## Ground rules

- **Never commit keys.** No private keys, seed phrases, keystore files, or
  `.env` files, ever. They are gitignored on purpose.
- Keep the honesty bar: if a change alters behaviour described in the
  README or `docs/ARCHITECTURE.md`, update the docs in the same change.
- Contract changes must compile with solc 0.8.24 and the optimizer at 200
  runs, matching the deployed build settings.
- Anything that would change the deployed contracts' behaviour belongs in
  a new version and a CHANGELOG entry, not a quiet edit.
