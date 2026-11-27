#!/usr/bin/env node
/*
 * Quiver Executor Agent — Robinhood Chain (4663)
 *
 * What it is: the onchain executor assistant for Quiver. It monitors every
 * Quiver vault + strategy, plans the executor actions that are due, simulates
 * each one, and shows the operator a human-readable preview. It broadcasts NOTHING
 * on its own: `execute` runs exactly ONE previewed action and only with
 * `--confirm <hash>`, the short hash of that proposal's target + calldata
 * printed by `plan` (the operator's explicit confirmation, bound to the exact
 * bytes reviewed). Every state-changing call is simulated first (eth_call);
 * if simulation reverts, the agent stops.
 *
 * Safety model (enforced in code):
 *  - status/plan NEVER load a private key. Previews simulate with eth_call
 *    `from` = the known admin/executor address.
 *  - execute loads exactly one key file (admin OR executor, per action),
 *    re-simulates, checks chain id / contract code / signer balance, then
 *    sends ONE transaction with pinned fees. No loops, no batching. It also
 *    refuses to broadcast when the live gas price exceeds the configured
 *    fee cap, so a fee spike cannot strand a transaction.
 *  - Confirmation is bound to the reviewed bytes: each proposal carries a
 *    short hash of (target + calldata). `execute` recomputes it from the
 *    stored proposal and refuses if the operator's hash does not match, so
 *    re-running `plan` can never silently swap what gets signed.
 *  - Owner-only functions (vault withdraw / claimYield / setClaimSchedule)
 *    are never called. The agent only reports claim-due status.
 *  - v1 is status-only in code: a factory gets proposals ONLY when its config
 *    explicitly sets `statusOnly: false`. A missing or true flag means
 *    read-only (fail-closed), so v1 can never receive a deploy, supply,
 *    collect, or LP write from this agent.
 *  - One-sided LP mints are never proposed (they revert on-chain); when only
 *    one side is unminted the planner notes that a ratio swap is needed
 *    first instead of proposing a doomed mint.
 *  - Yield settlement into per-vault reserves (fundYield + creditYield) is
 *    NEVER auto-planned: strategies are pooled and per-vault attribution is
 *    a human decision. Collect proposals stop at the executor wallet.
 *  - Keys are read from the existing quiver-admin key files (mode 600) and
 *    are never printed, logged, or copied.
 *
 * Commands:
 *   node agent.js status                      live read-only report (v1 + v6)
 *   node agent.js plan                        proposals + simulations, saved
 *   node agent.js execute <id> --confirm <hash>  run ONE proposal from latest plan
 *   node agent.js recall-preview <vault> <strategy> <ETH|USDG> <amount>
 *   node agent.js help
 */
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const CFG = JSON.parse(fs.readFileSync(path.join(HERE, 'config.json'), 'utf8'));
const ZERO = '0x0000000000000000000000000000000000000000';
const ETH_DEC = CFG.ethDecimals;
const USDG_DEC = CFG.usdgDecimals;
const PROFILES = ['Conservative', 'Balanced', 'Growth', 'Active', 'Aggressive', 'Degen'];

const FACTORY_ABI = [
  'function admin() view returns (address)',
  'function executor() view returns (address)',
  'function vaultCount() view returns (uint256)',
  'function allVaults(uint256) view returns (address)',
  'function approvedStrategy(address) view returns (bool)',
  'function strategyApprovalEta(address) view returns (uint256)',
  'function supportedAsset(address) view returns (bool)',
  'function executeStrategyApproval(address)'
];
const VAULT_ABI = [
  'function owner() view returns (address)',
  'function executor() view returns (address)',
  'function riskProfile() view returns (uint8)',
  'function maxStrategyBps() view returns (uint16)',
  'function depositsPaused() view returns (bool)',
  'function principal(address) view returns (uint256)',
  'function deployedTotal(address) view returns (uint256)',
  'function deployedIn(address,address) view returns (uint256)',
  'function freeBalance(address) view returns (uint256)',
  'function yieldReserve(address) view returns (uint256)',
  'function yieldAccrued(address) view returns (uint256)',
  'function yieldClaimed(address) view returns (uint256)',
  'function isClaimDue() view returns (bool)',
  'function claimSchedule() view returns (uint8)',
  'function deployToStrategy(address strategy, address token, uint256 amount)',
  'function recallFromStrategy(address strategy, address token, uint256 amount)'
];
const MORPHO_ABI = [
  'function admin() view returns (address)',
  'function executor() view returns (address)',
  'function supplyPaused() view returns (bool)',
  'function shares() view returns (uint256)',
  'function positionValue() view returns (uint256)',
  'function accruedYield() view returns (uint256)',
  'function idleBalance(address) view returns (uint256)',
  'function supply() returns (uint256)',
  'function collectYield(address to, uint256 amount)'
];
const LP_ABI = [
  'function admin() view returns (address)',
  'function executor() view returns (address)',
  'function mintPaused() view returns (bool)',
  'function tokenId() view returns (uint256)',
  'function tickLower() view returns (int24)',
  'function tickUpper() view returns (int24)',
  'function principal0() view returns (uint256)',
  'function principal1() view returns (uint256)',
  'function feeBalance0() view returns (uint256)',
  'function feeBalance1() view returns (uint256)',
  'function unminted0() view returns (uint256)',
  'function unminted1() view returns (uint256)',
  'function accruedYield(address) view returns (uint256)',
  'function pool() view returns (address)',
  'function positionInfo() view returns (uint256,int24,int24,uint128,uint128,uint128)',
  'function mint(int24,int24,uint256,uint256,uint256,uint256) returns (uint256)',
  'function collectFees() returns (uint256,uint256)',
  'function collectYield(address token, address to, uint256 amount)'
];
const POOL_ABI = [
  'function tickSpacing() view returns (int24)',
  'function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'
];

function fmt(raw, dec) { return ethers.formatUnits(raw, dec); }
function decFor(token) { return token === ZERO ? ETH_DEC : USDG_DEC; }
function symFor(token) { return token === ZERO ? 'ETH' : 'USDG'; }
function short(a) { return a.slice(0, 6) + '…' + a.slice(-4); }
function wib(tsSec) {
  return new Date(tsSec * 1000).toLocaleString('en-US', { timeZone: 'UTC', hour12: true }) + ' UTC';
}
function parseAmt(s, dec) { return ethers.parseUnits(String(s), dec); }

async function getProvider() {
  const p = new ethers.JsonRpcProvider(CFG.rpc);
  const net = await p.getNetwork();
  if (Number(net.chainId) !== CFG.chainId) {
    throw new Error(`chain id mismatch: got ${net.chainId}, expected ${CFG.chainId} — refusing to continue`);
  }
  return p;
}

async function assertContract(p, addr, label) {
  const code = await p.getCode(addr);
  if (!code || code === '0x') throw new Error(`${label} ${addr} has no code on chain ${CFG.chainId}`);
}

async function readVault(p, vaultAddr, strategies) {
  const v = new ethers.Contract(vaultAddr, VAULT_ABI, p);
  const [owner, executor, profile, capBps, paused, claimDue, schedule] = await Promise.all([
    v.owner(), v.executor(), v.riskProfile(), v.maxStrategyBps(), v.depositsPaused(), v.isClaimDue(), v.claimSchedule()
  ]);
  const assets = {};
  for (const token of [ZERO, CFG.usdg]) {
    const [principal, deployed, free, reserve, accrued, claimed] = await Promise.all([
      v.principal(token), v.deployedTotal(token), v.freeBalance(token),
      v.yieldReserve(token), v.yieldAccrued(token), v.yieldClaimed(token)
    ]);
    const perStrategy = {};
    for (const [sName, sAddr] of Object.entries(strategies)) {
      perStrategy[sName] = await v.deployedIn(sAddr, token);
    }
    // Deployable headroom under the profile cap: cap share of principal minus already deployed.
    const capMax = (principal * BigInt(capBps)) / 10000n;
    const headroom = capMax > deployed ? capMax - deployed : 0n;
    const deployable = free < headroom ? free : headroom;
    assets[symFor(token)] = { token, principal, deployed, free, reserve, accrued, claimed, perStrategy, capMax, headroom, deployable };
  }
  return { address: vaultAddr, owner, executor, profile: Number(profile), capBps: Number(capBps), paused, claimDue, schedule: Number(schedule), assets };
}

async function readFactory(p, key) {
  const cfg = CFG.factories[key];
  await assertContract(p, cfg.factory, `${key} factory`);
  const f = new ethers.Contract(cfg.factory, FACTORY_ABI, p);
  const [admin, executor, count] = await Promise.all([f.admin(), f.executor(), f.vaultCount()]);
  const strategies = { morpho: cfg.morpho, lp: cfg.lp };
  const approvals = {};
  for (const [sName, sAddr] of Object.entries(strategies)) {
    await assertContract(p, sAddr, `${key} ${sName}`);
    const approved = await f.approvedStrategy(sAddr);
    let eta = null;
    if (cfg.hasTimelockGetters) {
      try { eta = await f.strategyApprovalEta(sAddr); } catch { eta = null; }
    }
    approvals[sName] = { address: sAddr, approved, eta };
  }
  const vaults = [];
  for (let i = 0; i < Number(count); i++) {
    vaults.push(await readVault(p, await f.allVaults(i), strategies));
  }
  const morpho = new ethers.Contract(cfg.morpho, MORPHO_ABI, p);
  const [mExec, mAdmin, mPaused, mShares, mPos, mAcc, mIdle] = await Promise.all([
    morpho.executor(), morpho.admin(), morpho.supplyPaused(), morpho.shares(),
    morpho.positionValue(), morpho.accruedYield(), morpho.idleBalance(CFG.usdg)
  ]);
  const lp = new ethers.Contract(cfg.lp, LP_ABI, p);
  const [lExec, lAdmin, lPaused, lTokenId, lU0, lU1, lF0, lF1, lP0, lP1] = await Promise.all([
    lp.executor(), lp.admin(), lp.mintPaused(), lp.tokenId(), lp.unminted0(), lp.unminted1(),
    lp.feeBalance0(), lp.feeBalance1(), lp.principal0(), lp.principal1()
  ]);
  let owed0 = 0n, owed1 = 0n, liq = 0n;
  if (lTokenId !== 0n) {
    const info = await lp.positionInfo();
    liq = info[3]; owed0 = info[4]; owed1 = info[5];
  }
  return {
    key, cfg, admin, executor, vaults, approvals,
    morpho: { executor: mExec, admin: mAdmin, paused: mPaused, shares: mShares, positionValue: mPos, accruedYield: mAcc, idleUsdg: mIdle },
    lp: { executor: lExec, admin: lAdmin, paused: lPaused, tokenId: lTokenId, unminted0: lU0, unminted1: lU1, fee0: lF0, fee1: lF1, principal0: lP0, principal1: lP1, liquidity: liq, owed0, owed1 }
  };
}

async function readAll(p) {
  const block = await p.getBlockNumber();
  const blk = await p.getBlock(block);
  const [adminBal, execBal, gasPrice] = await Promise.all([
    p.getBalance(CFG.adminWallet), p.getBalance(CFG.executorWallet), p.getFeeData()
  ]);
  const out = { block, ts: blk.timestamp, adminBal, execBal, gasPrice: gasPrice.gasPrice, factories: {} };
  for (const key of Object.keys(CFG.factories)) out.factories[key] = await readFactory(p, key);
  return out;
}

function printStatus(s) {
  console.log(`Quiver Executor Agent — status live`);
  console.log(`Block ${s.block} | ${wib(s.ts)} | gas ~${ethers.formatUnits(s.gasPrice || 0n, 'gwei')} gwei`);
  console.log(`Admin    ${CFG.adminWallet} : ${fmt(s.adminBal, ETH_DEC)} ETH`);
  console.log(`Executor ${CFG.executorWallet} : ${fmt(s.execBal, ETH_DEC)} ETH`);
  if (s.execBal < parseAmt(CFG.policy.lowGasWarnEth, ETH_DEC)) {
    console.log(`  WARNING: executor gas balance below ${CFG.policy.lowGasWarnEth} ETH — top up before running many executions.`);
  }
  for (const f of Object.values(s.factories)) {
    console.log(`\n=== ${f.key.toUpperCase()} factory ${f.cfg.factory} ===`);
    console.log(`admin ${f.admin} | executor ${f.executor}`);
    for (const [sName, a] of Object.entries(f.approvals)) {
      let extra = '';
      if (!a.approved && a.eta !== null && a.eta !== 0n) {
        const etaN = Number(a.eta);
        extra = etaN <= s.ts ? ` | timelock LEWAT (${wib(etaN)}) — siap executeStrategyApproval` : ` | timelock sampai ${wib(etaN)}`;
      }
      console.log(`  ${sName} ${a.address} approved=${a.approved}${extra}`);
    }
    console.log(`  Morpho: position ${fmt(f.morpho.positionValue, USDG_DEC)} USDG | accrued yield ${fmt(f.morpho.accruedYield, USDG_DEC)} USDG | idle ${fmt(f.morpho.idleUsdg, USDG_DEC)} USDG | supplyPaused=${f.morpho.paused}`);
    console.log(`  LP: tokenId=${f.lp.tokenId.toString()} | unminted ${fmt(f.lp.unminted0, ETH_DEC)} WETH/ETH + ${fmt(f.lp.unminted1, USDG_DEC)} USDG | unsettled fees ${fmt(f.lp.fee0, ETH_DEC)} + ${fmt(f.lp.fee1, USDG_DEC)} USDG | mintPaused=${f.lp.paused}`);
    if (f.lp.tokenId !== 0n) console.log(`      position: liquidity ${f.lp.liquidity.toString()} | uncollected fees ${fmt(f.lp.owed0, ETH_DEC)} + ${fmt(f.lp.owed1, USDG_DEC)} USDG`);
    console.log(`  Vault (${f.vaults.length}):`);
    if (f.vaults.length === 0) console.log(`    (no vaults yet — the site has not moved to this factory)`);
    for (const v of f.vaults) {
      console.log(`    ${v.address} owner=${short(v.owner)} profile=${PROFILES[v.profile]}(${v.capBps}bps) paused=${v.paused} claimDue=${v.claimDue}`);
      for (const [sym, a] of Object.entries(v.assets)) {
        const dec = decFor(a.token);
        if (a.principal === 0n && a.deployed === 0n && a.accrued === 0n) continue;
        console.log(`      ${sym}: principal ${fmt(a.principal, dec)} | deployed ${fmt(a.deployed, dec)} | free ${fmt(a.free, dec)} | deployable ${fmt(a.deployable, dec)} | yield accrued ${fmt(a.accrued, dec)} (reserve ${fmt(a.reserve, dec)})`);
      }
    }
  }
  console.log(`\nNote: this status is read-only. Run "plan" for proposals + simulations.`);
}

// ---------- HEY Research Lab record (read-only) ----------
// The agent reads Quiver's public record on HEY (heyresearch.xyz) as part of
// status, so the on-chain view can be compared with what HEY has recorded.
// Every call carries the integration header HEY asked for:
//   x-hey-integration: quiver-executor/1.0.0
// Read-only, no key, fails soft: if HEY is unreachable, status still prints.

async function heyGet(pathName) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), CFG.hey.timeoutMs || 15000);
  try {
    const res = await fetch(`${CFG.hey.apiBase}${pathName}`, {
      headers: { 'x-hey-integration': CFG.hey.integration, 'accept': 'application/json' },
      signal: ctrl.signal
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

async function printHey() {
  console.log(`\n=== HEY Research Lab record (${CFG.hey.projectSlug}) ===`);
  try {
    const token = await heyGet(`/token/4663/${CFG.hey.quivToken}`);
    const proj = token.project || {};
    console.log(`Project: ${proj.name || '?'} ($${proj.symbol || '?'}) | ${proj.url || ''}`);
    console.log(`Activity status: ${proj.activityStatus || '?'} — ${proj.activityLabel || ''}`);
    console.log(`Research level: ${proj.researchLevel || '?'} | ships last 30 days: ${proj.shipsLast30Days ?? '?'} | activity measured: ${proj.activityMeasured ?? '?'}`);
    if (proj.deployedAt) console.log(`Token deployed: ${proj.deployedAt}`);
    const snap = await heyGet(`/projects/${CFG.hey.projectSlug}/snapshot`).catch(() => null);
    if (snap && snap.project) {
      const sp = snap.project;
      if (sp.lastShippedAt) console.log(`Last shipped (HEY): ${sp.lastShippedAt}`);
      if (sp.stillBuildingState) console.log(`Still Building: ${sp.stillBuildingState}`);
    }
    console.log(`Badge: ${proj.badgeUrl || `https://heyresearch.xyz/badge/${CFG.hey.projectSlug}.svg`}`);
  } catch (e) {
    console.log(`(HEY unreachable right now: ${e.message} — the on-chain status above still stands.)`);
  }
}

// ---------- Planner ----------
// Each proposal: { id, kind, signer: 'admin'|'executor', factoryKey, to, fn, args (JSON-safe), describe }
// args are stored as strings; execute() re-encodes from the stored proposal
// after re-validating live state, so a stale plan cannot silently drift.

async function simulate(p, from, to, iface, fn, args) {
  const data = iface.encodeFunctionData(fn, args);
  const res = await p.call({ to, from, data });
  let gas = null;
  try { gas = await p.estimateGas({ to, from, data }); } catch { gas = null; }
  return { ok: true, result: res, gas, data };
}

async function buildPlan(p, s) {
  const proposals = [];
  const notes = [];
  const pol = CFG.policy;
  const minDeployEth = parseAmt(pol.minDeployEth, ETH_DEC);
  const minDeployUsdg = parseAmt(pol.minDeployUsdg, USDG_DEC);
  const minSupply = parseAmt(pol.minSupplyUsdg, USDG_DEC);
  const minCollectUsdg = parseAmt(pol.minCollectYieldUsdg, USDG_DEC);
  const minCollectEth = parseAmt(pol.minCollectYieldEth, ETH_DEC);
  let n = 0;
  const add = (pr) => { pr.id = 'P' + (++n); proposals.push(pr); };

  for (const f of Object.values(s.factories)) {
    const fIface = new ethers.Interface(FACTORY_ABI);
    const vIface = new ethers.Interface(VAULT_ABI);
    const mIface = new ethers.Interface(MORPHO_ABI);
    const lIface = new ethers.Interface(LP_ABI);

    // Status-only gate (fail-closed): a factory receives proposals ONLY when
    // its config explicitly sets statusOnly: false. A missing flag reads as
    // blocked, so v1 (and any future retired factory) can never be written to.
    if (f.cfg.statusOnly !== false) {
      notes.push(`[${f.key}] status-only factory — read-only, no proposals are generated for it.`);
      continue;
    }

    // A. Activation (admin): execute timelocked approvals that are due.
    for (const [sName, a] of Object.entries(f.approvals)) {
      if (!a.approved && a.eta !== null && a.eta !== 0n) {
        if (Number(a.eta) <= s.ts) {
          add({
            kind: 'ACTIVATE_STRATEGY', signer: 'admin', factoryKey: f.key, to: f.cfg.factory,
            fn: 'executeStrategyApproval', args: [a.address],
            describe: `[${f.key}] Activate strategy ${sName} ${a.address} (timelock passed ${wib(Number(a.eta))})`
          });
        } else {
          notes.push(`[${f.key}] ${sName}: approval still timelocked until ${wib(Number(a.eta))} — cannot be activated yet.`);
        }
      }
    }

    // B. Deploy idle vault capital (executor), only into approved strategies.
    for (const v of f.vaults) {
      for (const [sym, a] of Object.entries(v.assets)) {
        const min = sym === 'ETH' ? minDeployEth : minDeployUsdg;
        if (a.deployable < min) continue;
        const target = sym === 'USDG' ? 'morpho' : 'lp';
        if (!f.approvals[target].approved) {
          notes.push(`[${f.key}] vault ${short(v.address)} has ${fmt(a.deployable, decFor(a.token))} ${sym} ready to deploy, but strategy ${target} is not approved yet — wait for activation.`);
          continue;
        }
        add({
          kind: 'DEPLOY', signer: 'executor', factoryKey: f.key, to: v.address,
          fn: 'deployToStrategy', args: [f.cfg[target], a.token, a.deployable.toString()],
          describe: `[${f.key}] Deploy ${fmt(a.deployable, decFor(a.token))} ${sym} from vault ${v.address} (owner ${short(v.owner)}, ${PROFILES[v.profile]}) to ${target} ${f.cfg[target]}`
        });
      }
    }

    // C. Morpho supply sweep (executor).
    if (f.morpho.idleUsdg >= minSupply) {
      if (f.morpho.paused) notes.push(`[${f.key}] Morpho idle ${fmt(f.morpho.idleUsdg, USDG_DEC)} USDG but supplyPaused=true — supply not proposed.`);
      else add({
        kind: 'SUPPLY', signer: 'executor', factoryKey: f.key, to: f.cfg.morpho, fn: 'supply', args: [],
        describe: `[${f.key}] Supply ${fmt(f.morpho.idleUsdg, USDG_DEC)} USDG idle di MorphoStrategy ke Steakhouse Morpho vault`
      });
    }

    // D. Morpho yield collect (executor -> executor wallet; settlement is manual).
    if (f.morpho.accruedYield >= minCollectUsdg) {
      add({
        kind: 'COLLECT_YIELD_MORPHO', signer: 'executor', factoryKey: f.key, to: f.cfg.morpho,
        fn: 'collectYield', args: [CFG.executorWallet, f.morpho.accruedYield.toString()],
        describe: `[${f.key}] Collect Morpho yield ${fmt(f.morpho.accruedYield, USDG_DEC)} USDG to the executor wallet (settling to vaults is a separate manual step)`
      });
    }

    // E. LP actions (executor) — v1 writes hard-blocked by standing instruction.
    if (f.cfg.lpWritesBlocked) {
      if (f.lp.tokenId !== 0n || f.lp.fee0 > 0n || f.lp.fee1 > 0n) {
        notes.push(`[${f.key}] LP has active state but ALL v1 LP writes are hard-blocked — no LP proposals.`);
      }
    } else {
      const oneSided = f.lp.tokenId === 0n && ((f.lp.unminted0 >= minDeployEth) !== (f.lp.unminted1 >= minDeployUsdg));
      if (oneSided) {
        notes.push(`[${f.key}] LP has only one side unminted (${fmt(f.lp.unminted0, ETH_DEC)} WETH/ETH + ${fmt(f.lp.unminted1, USDG_DEC)} USDG) — a one-sided full-range mint reverts on-chain, so no mint is proposed; a ratio swap is needed first (manual step).`);
      }
      if (f.lp.tokenId === 0n && f.lp.unminted0 >= minDeployEth && f.lp.unminted1 >= minDeployUsdg) {
        if (f.lp.paused) notes.push(`[${f.key}] LP has unminted funds but mintPaused=true — mint not proposed.`);
        else {
          const lpC = new ethers.Contract(f.cfg.lp, LP_ABI, p);
          const poolAddr = await lpC.pool();
          const pool = new ethers.Contract(poolAddr, POOL_ABI, p);
          const spacing = Number(await pool.tickSpacing());
          const lower = Math.floor(-887272 / spacing) * spacing;
          const upper = Math.floor(887272 / spacing) * spacing;
          const amt0 = f.lp.unminted0, amt1 = f.lp.unminted1;
          const keep = 10000n - BigInt(pol.mintSlippageBps);
          const min0 = (amt0 * keep) / 10000n, min1 = (amt1 * keep) / 10000n;
          add({
            kind: 'MINT_LP', signer: 'executor', factoryKey: f.key, to: f.cfg.lp,
            fn: 'mint', args: [lower, upper, amt0.toString(), amt1.toString(), min0.toString(), min1.toString()],
            describe: `[${f.key}] Mint LP full-range [${lower}, ${upper}] with ${fmt(amt0, ETH_DEC)} WETH/ETH + ${fmt(amt1, USDG_DEC)} USDG (min ${(100 - pol.mintSlippageBps / 100)}%)`
          });
        }
      }
      if (f.lp.tokenId !== 0n && (f.lp.owed0 > 0n || f.lp.owed1 > 0n)) {
        add({
          kind: 'COLLECT_FEES_LP', signer: 'executor', factoryKey: f.key, to: f.cfg.lp, fn: 'collectFees', args: [],
          describe: `[${f.key}] Collect fees from LP position #${f.lp.tokenId.toString()} (uncollected ~${fmt(f.lp.owed0, ETH_DEC)} + ${fmt(f.lp.owed1, USDG_DEC)} USDG)`
        });
      }
      if (f.lp.fee1 >= minCollectUsdg) {
        add({
          kind: 'COLLECT_YIELD_LP', signer: 'executor', factoryKey: f.key, to: f.cfg.lp,
          fn: 'collectYield', args: [CFG.usdg, CFG.executorWallet, f.lp.fee1.toString()],
          describe: `[${f.key}] Collect LP yield ${fmt(f.lp.fee1, USDG_DEC)} USDG to the executor wallet (settling to vaults is a separate manual step)`
        });
      }
      if (f.lp.fee0 >= minCollectEth) {
        add({
          kind: 'COLLECT_YIELD_LP', signer: 'executor', factoryKey: f.key, to: f.cfg.lp,
          fn: 'collectYield', args: [ZERO, CFG.executorWallet, f.lp.fee0.toString()],
          describe: `[${f.key}] Collect LP yield ${fmt(f.lp.fee0, ETH_DEC)} ETH to the executor wallet (settling to vaults is a separate manual step)`
        });
      }
    }
  }

  // Simulate every proposal from its signer address (no keys loaded).
  const ifaces = { FACTORY: new ethers.Interface(FACTORY_ABI), VAULT: new ethers.Interface(VAULT_ABI), MORPHO: new ethers.Interface(MORPHO_ABI), LP: new ethers.Interface(LP_ABI) };
  const ifaceFor = (pr) => pr.kind === 'ACTIVATE_STRATEGY' ? ifaces.FACTORY : pr.kind === 'DEPLOY' ? ifaces.VAULT : (pr.kind === 'SUPPLY' || pr.kind === 'COLLECT_YIELD_MORPHO') ? ifaces.MORPHO : ifaces.LP;
  for (const pr of proposals) {
    const from = pr.signer === 'admin' ? CFG.adminWallet : CFG.executorWallet;
    const args = pr.args.map((x) => (typeof x === 'string' && /^\d+$/.test(x) ? BigInt(x) : x));
    // Confirmation hash bound to the exact bytes: short hash of target + calldata.
    const data = ifaceFor(pr).encodeFunctionData(pr.fn, args);
    pr.confirmHash = ethers.keccak256(ethers.concat([pr.to, data])).slice(2, 12);
    try {
      const sim = await simulate(p, from, pr.to, ifaceFor(pr), pr.fn, args);
      pr.simOk = true; pr.gasEstimate = sim.gas ? sim.gas.toString() : null;
      pr.feeEstimateEth = sim.gas ? fmt(sim.gas * BigInt(CFG.gas.maxFeePerGasWei), ETH_DEC) : null;
    } catch (e) {
      pr.simOk = false; pr.simError = e.shortMessage || e.message;
    }
  }
  return { proposals, notes };
}

function printPlan(plan, s) {
  console.log(`Quiver Executor Agent — plan (block ${s.block}, ${wib(s.ts)})`);
  if (plan.proposals.length === 0) console.log(`No executor actions are due right now.`);
  for (const pr of plan.proposals) {
    console.log(`\n${pr.id} [${pr.signer}] ${pr.describe}`);
    console.log(`   target ${pr.to} | ${pr.fn}(${pr.args.join(', ')})`);
    console.log(`   confirm hash: ${pr.confirmHash}`);
    if (pr.simOk) console.log(`   simulation OK | gas ~${pr.gasEstimate || '?'} | max fee ~${pr.feeEstimateEth || '?'} ETH`);
    else console.log(`   SIMULATION FAILED: ${pr.simError} — do not execute, investigate first.`);
  }
  if (plan.notes.length) { console.log(`\nNotes:`); for (const n of plan.notes) console.log(`- ${n}`); }
  console.log(`\nExecute only after explicit operator confirmation of the hash shown for that ID: node agent.js execute <id> --confirm <hash>`);
}

// ---------- Execute (one tx, only with --confirm <hash>) ----------
async function executeProposal(p, proposalId, confirmHash) {
  const planPath = path.join(HERE, 'runs', 'latest-plan.json');
  if (!fs.existsSync(planPath)) throw new Error('no plan yet. Run: node agent.js plan');
  const plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
  const age = Math.floor(Date.now() / 1000) - plan.createdAt;
  if (age > CFG.policy.planMaxAgeSeconds) throw new Error(`plan is ${age} seconds old (max ${CFG.policy.planMaxAgeSeconds}). Re-run plan for a fresh preview.`);
  const pr = plan.proposals.find((x) => x.id === proposalId);
  if (!pr) throw new Error(`proposal ${proposalId} is not in the latest plan.`);
  if (!pr.simOk) throw new Error(`proposal ${proposalId} failed simulation at plan time — refusing to execute.`);

  // Confirmation is bound to the reviewed bytes: recompute the short hash of
  // (target + calldata) from the stored proposal BEFORE any key is loaded,
  // and refuse unless it matches both the plan's hash and the operator's.
  const abiEarly = pr.kind === 'ACTIVATE_STRATEGY' ? FACTORY_ABI : pr.kind === 'DEPLOY' || pr.kind === 'RECALL' ? VAULT_ABI : (pr.kind === 'SUPPLY' || pr.kind === 'COLLECT_YIELD_MORPHO') ? MORPHO_ABI : LP_ABI;
  const argsEarly = pr.args.map((x) => (typeof x === 'string' && /^\d+$/.test(x) ? BigInt(x) : x));
  const dataEarly = new ethers.Interface(abiEarly).encodeFunctionData(pr.fn, argsEarly);
  const recomputed = ethers.keccak256(ethers.concat([pr.to, dataEarly])).slice(2, 12);
  if (recomputed !== pr.confirmHash) throw new Error(`confirmation hash mismatch: stored proposal encodes to ${recomputed}, plan recorded ${pr.confirmHash} — the proposal changed since plan. Re-run plan and confirm the new hash.`);
  if (String(confirmHash).toLowerCase() !== recomputed) throw new Error(`confirmation refused: --confirm ${confirmHash} does not match proposal ${pr.id}'s hash ${recomputed}. Confirm the exact hash shown by plan for this proposal.`);

  const keyPath = pr.signer === 'admin' ? CFG.adminKeyPath : CFG.executorKeyPath;
  const expected = pr.signer === 'admin' ? CFG.adminWallet : CFG.executorWallet;
  const key = fs.readFileSync(keyPath, 'utf8').trim();
  const wallet = new ethers.Wallet(key, p);
  if (wallet.address.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`signer mismatch: key yields ${wallet.address}, expected ${expected} — stopping.`);
  }
  await assertContract(p, pr.to, 'target');
  const abi = pr.kind === 'ACTIVATE_STRATEGY' ? FACTORY_ABI : pr.kind === 'DEPLOY' || pr.kind === 'RECALL' ? VAULT_ABI : (pr.kind === 'SUPPLY' || pr.kind === 'COLLECT_YIELD_MORPHO') ? MORPHO_ABI : LP_ABI;
  const contract = new ethers.Contract(pr.to, abi, wallet);
  const args = pr.args.map((x) => (typeof x === 'string' && /^\d+$/.test(x) ? BigInt(x) : x));

  // Re-simulate immediately before broadcast; drift = stop.
  const data = contract.interface.encodeFunctionData(pr.fn, args);
  await p.call({ to: pr.to, from: wallet.address, data });
  const gasEst = await p.estimateGas({ to: pr.to, from: wallet.address, data });
  const gasLimit = (gasEst * BigInt(CFG.gas.gasLimitMultiplierBps)) / 10000n;
  const maxFee = BigInt(CFG.gas.maxFeePerGasWei);
  // Refuse to broadcast into a fee spike above the cap: the tx would sit
  // stuck. Raise CFG.gas.maxFeePerGasWei deliberately instead.
  const feeData = await p.getFeeData();
  if (feeData.gasPrice && feeData.gasPrice > maxFee) {
    throw new Error(`live gas price ${ethers.formatUnits(feeData.gasPrice, 'gwei')} gwei exceeds the configured cap ${ethers.formatUnits(maxFee, 'gwei')} gwei — refusing to broadcast. Raise gas.maxFeePerGasWei in config if this is intentional.`);
  }
  const bal = await p.getBalance(wallet.address);
  const need = gasLimit * maxFee;
  if (bal < need) throw new Error(`signer balance ${fmt(bal, ETH_DEC)} ETH < max gas needed ${fmt(need, ETH_DEC)} ETH — top up first.`);

  console.log(`Executing ${pr.id}: ${pr.describe}`);
  console.log(`signer ${wallet.address} (${pr.signer}) | gasLimit ${gasLimit.toString()} | maxFee ${ethers.formatUnits(maxFee, 'gwei')} gwei`);
  const tx = await contract[pr.fn](...args, { maxFeePerGas: maxFee, gasLimit });
  console.log(`tx sent: ${tx.hash}`);
  const rc = await tx.wait();
  console.log(`status ${rc.status} | block ${rc.blockNumber} | gasUsed ${rc.gasUsed.toString()}`);
  const after = await p.getBalance(wallet.address);
  console.log(`signer balance after: ${fmt(after, ETH_DEC)} ETH`);
  const log = { at: new Date().toISOString(), proposal: pr, txHash: tx.hash, status: rc.status, block: rc.blockNumber, gasUsed: rc.gasUsed.toString(), signerBalanceAfter: after.toString() };
  fs.writeFileSync(path.join(HERE, 'runs', `exec-${pr.id}-${Date.now()}.json`), JSON.stringify(log, null, 2));
  if (rc.status !== 1) throw new Error('tx revert on-chain — cek log di runs/.');
  return log;
}

// ---------- Recall preview (explicit operator instruction only) ----------
async function recallPreview(p, vaultAddr, strategyAddr, sym, amountStr) {
  const token = sym.toUpperCase() === 'ETH' ? ZERO : CFG.usdg;
  const dec = decFor(token);
  const amount = parseAmt(amountStr, dec);
  const v = new ethers.Contract(vaultAddr, VAULT_ABI, p);
  const [owner, executor, deployedIn] = await Promise.all([v.owner(), v.executor(), v.deployedIn(strategyAddr, token)]);
  console.log(`Recall preview: ${amountStr} ${sym} from strategy ${strategyAddr} to vault ${vaultAddr}`);
  console.log(`owner ${owner} | executor ${executor} | deployedIn this strategy: ${fmt(deployedIn, dec)} ${sym}`);
  if (amount > deployedIn) throw new Error('recall amount exceeds deployedIn — stopping.');
  const iface = new ethers.Interface(VAULT_ABI);
  const sim = await simulate(p, executor, vaultAddr, iface, 'recallFromStrategy', [strategyAddr, token, amount]);
  console.log(`recallFromStrategy simulation from executor: OK | gas ~${sim.gas ? sim.gas.toString() : '?'}`);
  console.log(`This is only a preview. Execution needs explicit operator confirmation of amount + target first.`);
}

async function main() {
  const cmd = process.argv[2] || 'help';
  const p = await getProvider();
  if (cmd === 'status') {
    printStatus(await readAll(p));
    await printHey();
  } else if (cmd === 'plan') {
    const s = await readAll(p);
    const plan = await buildPlan(p, s);
    printPlan(plan, s);
    fs.mkdirSync(path.join(HERE, 'runs'), { recursive: true });
    const saved = { createdAt: Math.floor(Date.now() / 1000), block: s.block, proposals: plan.proposals, notes: plan.notes };
    fs.writeFileSync(path.join(HERE, 'runs', 'latest-plan.json'), JSON.stringify(saved, null, 2));
    console.log(`Plan saved: runs/latest-plan.json (valid ${CFG.policy.planMaxAgeSeconds / 60} minutes for execute).`);
  } else if (cmd === 'execute') {
    const id = process.argv[3];
    const confirmHash = process.argv.includes('--confirm') ? process.argv[process.argv.indexOf('--confirm') + 1] : null;
    if (!id) throw new Error('usage: node agent.js execute <id> --confirm <hash>');
    if (!confirmHash) throw new Error('refused: execute needs --confirm <hash> (the short hash plan printed for this proposal — explicit operator confirmation bound to the reviewed bytes).');
    await executeProposal(p, id, confirmHash);
  } else if (cmd === 'recall-preview') {
    const [, , , vault, strategy, sym, amount] = process.argv;
    if (!vault || !strategy || !sym || !amount) throw new Error('usage: node agent.js recall-preview <vault> <strategy> <ETH|USDG> <amount>');
    await recallPreview(p, vault, strategy, sym, amount);
  } else {
    console.log(`Quiver Executor Agent\n  node agent.js status\n  node agent.js plan\n  node agent.js execute <id> --confirm <hash>\n  node agent.js recall-preview <vault> <strategy> <ETH|USDG> <amount>`);
  }
}

main().catch((e) => { console.error('FAILED:', e.shortMessage || e.message); process.exit(1); });
