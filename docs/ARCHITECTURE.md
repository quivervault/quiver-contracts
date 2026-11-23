# Architecture

Quiver is a non-custodial yield vault system on Robinhood Chain. One
factory creates one isolated vault per depositor; strategies are separate
contracts the vaults can deploy capped shares of principal into; yield is
paid only from tokens actually funded into a vault's reserve.

## Roles

- **Depositor (vault owner).** The only account that can withdraw
  principal or claim yield from a vault. Every vault has exactly one
  owner, fixed at creation.
- **Factory admin.** Configures the shared registries (supported assets,
  approved strategies, per-profile caps, the executor) and can pause
  deposits per vault. The admin has **no** path to user funds: no vault
  function lets the admin or the factory move principal out.
- **Executor.** A protocol account that operates strategies on behalf of
  vaults: it can deploy and recall principal within the caps, and credit
  yield against the funded reserve. It can never withdraw to itself;
  strategy recalls return funds to the calling vault only, and yield
  claims pay the vault owner only.

## Contracts

### QuiverVaultFactory

Creates vaults and holds the shared registries:

- supported deposit assets (ETH is `address(0)`; USDG at launch),
- approved strategies,
- the executor address,
- deployment caps per risk profile, in basis points of principal:
  profile 0: 20%, 1: 35%, 2: 50%, 3: 65%, 4: 80%, 5: 95%.

`createVault(riskProfile)` deploys a fresh `QuiverVault` owned by the
caller, wired to the factory's current executor and cap for that profile.

### QuiverVault

One per depositor. Holds principal per asset and tracks how much is
deployed into each strategy.

- `depositETH()` / `deposit(token, amount)` add principal.
- `withdraw(token, amount)` is owner-only and returns principal to the
  owner.
- `deployToStrategy(...)` / `recallFromStrategy(...)` are executor-only,
  limited to factory-approved strategies, and the total deployed per
  asset may never exceed the profile cap times principal.
- `freeBalance(token)` is the vault balance minus the yield reserve:
  tokens backing credited yield are never deployable as principal.

### Yield accounting

Yield is deliberately boring, because it is backed by real tokens:

1. Strategy returns are funded into the vault with `fundYield` /
   `fundYieldETH`. Anyone can fund; funding only ever adds to the
   reserve.
2. The executor calls `creditYield(token, amount)` to accrue yield to
   the owner. The amount is capped by the unallocated reserve, so yield
   can never be credited beyond what was actually funded.
3. The owner calls `claimYield(token)` to collect. Claims follow the
   owner's schedule: Manual (any time), Weekly, or Monthly.

With an unfunded reserve, `creditYield` and `claimYield` simply revert.
There is no code path that invents yield.

### SimpleStrategy

The starter strategy: capital sits idle (0%). It proves the full deploy,
recall, and withdraw loop end to end with no external dependency. A
recall can only send funds back to the vault that deployed them.

### PerpStrategy

The funding-harvest strategy. ETH held in the contract is the long spot
leg; USDG margin is posted to a single whitelisted executor account on
Lighter for a 1x short, so the pair collects perpetual funding while
staying market-neutral. Margin movement is bounded by an on-chain cap
set by the admin; the cap is 0 (disabled) until the executor's Lighter
account is activated. Realised profit is settled back into each vault's
yield reserve through the same funding path described above. Full design
notes: [PERP_STRATEGY_DESIGN.md](../PERP_STRATEGY_DESIGN.md).

## Trust model, plainly

- A depositor trusts the vault code (public, Sourcify-verified) and the
  executor's strategy operation, bounded by the caps.
- The executor cannot steal principal: recalls return to the vault,
  claims pay the owner, and deployment targets must be pre-approved.
- The admin cannot steal principal either, but can pause deposits and
  change registries, which is why the admin is a dedicated control
  wallet.
- The contracts are not yet audited. See [SECURITY.md](../SECURITY.md).
