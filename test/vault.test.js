// Functional test of the Quiver vault loop on a local EVM (ganache).
//
// Deploys the factory and the idle strategy, creates a vault, and walks
// the full loop: deposit, capped strategy deployment, recall, withdraw,
// and the funded-yield claim path. Also checks the guard rails: the
// profile cap, owner-only withdrawals, and that yield cannot be claimed
// before any is funded and credited.
//
// Run with: npm test

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const solc = require('solc');
const ganache = require('ganache');
const { ethers } = require('ethers');

const ETH = ethers.ZeroAddress;
const one = ethers.parseEther('1');

function compileAll() {
  const files = ['QuiverVault.sol', 'QuiverVaultFactory.sol', 'SimpleStrategy.sol', 'PerpStrategy.sol'];
  const sources = {};
  for (const f of files) {
    sources[f] = { content: fs.readFileSync(path.join(__dirname, '..', 'contracts', f), 'utf8') };
  }
  const input = {
    language: 'Solidity',
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      // The deployed build (compile.js) uses solc's default EVM target.
      // The local test chain cannot run that target, so the test compiles
      // the same sources for Shanghai; the logic under test is identical.
      evmVersion: 'shanghai',
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
    },
  };
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (out.errors || []).filter((e) => e.severity === 'error');
  assert.strictEqual(errors.length, 0, 'compile errors: ' + JSON.stringify(errors));
  const artifacts = {};
  for (const contracts of Object.values(out.contracts)) {
    for (const [name, c] of Object.entries(contracts)) {
      artifacts[name] = { abi: c.abi, bytecode: c.evm.bytecode.object };
    }
  }
  // Interfaces legitimately have no bytecode; the four contracts must.
  for (const name of files.map((f) => f.replace('.sol', ''))) {
    assert.ok(artifacts[name].bytecode.length > 100, name + ' has no bytecode');
  }
  return artifacts;
}

async function expectRevert(thunk, needle) {
  try {
    await thunk();
  } catch (e) {
    let extra = '';
    try { extra = JSON.stringify(e); } catch (_) { /* circular error objects */ }
    const text = [e && e.message, e && e.reason, e && e.shortMessage, extra].join(' ');
    if (needle) assert.ok(text.includes(needle), 'revert should mention "' + needle + '", got: ' + text.slice(0, 300));
    return;
  }
  assert.fail('expected revert' + (needle ? ' ("' + needle + '")' : '') + ' but the call succeeded');
}

// Balance reads can race the local chain's state right after a mined tx,
// so poll briefly until the balance settles before asserting.
async function assertBalance(provider, address, expected, label) {
  let actual = -1n;
  for (let i = 0; i < 30; i++) {
    actual = await provider.getBalance(address);
    if (actual === expected) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  assert.strictEqual(actual, expected, label + ': balance mismatch');
}

// Reason-checked revert probe over a raw JSON-RPC eth_call: ethers drops
// ganache's revert payload, the raw response keeps the reason string.
async function expectRevertReason(rpcUrl, contract, from, method, args, needle) {
  const tx = { from, to: await contract.getAddress(), data: contract.interface.encodeFunctionData(method, args) };
  const res = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [tx, 'latest'] }),
  });
  const j = await res.json();
  assert.ok(j.error, method + ' should revert but the call succeeded');
  const text = JSON.stringify(j.error);
  assert.ok(text.includes(needle), 'revert should mention "' + needle + '", got: ' + text.slice(0, 300));
}

async function main() {
  const artifacts = compileAll();
  console.log('ok - all 4 contracts compile (solc 0.8.24, optimizer 200)');

  // Serve ganache over HTTP: revert reasons survive the round trip there,
  // unlike through the in-process provider wrapper.
  const server = ganache.server({ logging: { quiet: true } });
  await server.listen(0);
  const rpcUrl = 'http://127.0.0.1:' + server.address().port;
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const admin = await provider.getSigner(0);
  const executor = await provider.getSigner(1);
  const user = await provider.getSigner(2);
  const stranger = await provider.getSigner(3);
  const executorAddr = await executor.getAddress();
  const userAddr = await user.getAddress();

  const deploy = async (name, signer, ...args) => {
    const f = new ethers.ContractFactory(artifacts[name].abi, artifacts[name].bytecode, signer);
    const c = await f.deploy(...args);
    await c.waitForDeployment();
    return c;
  };

  const factory = await deploy('QuiverVaultFactory', admin, executorAddr, ETH, ETH, ETH);
  // Constructor treats address(0) token args as "add later"; ETH itself is always supported.
  const factoryAddr = await factory.getAddress();
  const strategy = await deploy('SimpleStrategy', admin, factoryAddr);
  const strategyAddr = await strategy.getAddress();
  await factory.setStrategy(strategyAddr, true);
  console.log('ok - factory deployed, SimpleStrategy approved');

  await (await factory.connect(user).createVault(1)).wait();
  const vaultAddr = await factory.vaultsOf(userAddr, 0);
  const vault = new ethers.Contract(vaultAddr, artifacts.QuiverVault.abi, user);
  const vaultByExecutor = vault.connect(executor);
  const vaultByStranger = vault.connect(stranger);
  console.log('ok - vault created for profile 1 (35% strategy cap)');

  await (await vault.depositETH({ value: one })).wait();
  await assertBalance(provider, vaultAddr, one, 'deposit');
  console.log('ok - deposit: vault holds 1 ETH');

  // Profile 1 cap is 35% of principal: 0.36 ETH must revert, 0.3 ETH must pass.
  await expectRevertReason(rpcUrl, vault, executorAddr, 'deployToStrategy', [strategyAddr, ETH, ethers.parseEther('0.36')], 'profile cap exceeded');
  await (await vaultByExecutor.deployToStrategy(strategyAddr, ETH, ethers.parseEther('0.3'))).wait();
  await assertBalance(provider, strategyAddr, ethers.parseEther('0.3'), 'deploy (strategy)');
  await assertBalance(provider, vaultAddr, ethers.parseEther('0.7'), 'deploy (vault)');
  console.log('ok - cap enforced; executor deployed 0.3 ETH to the strategy');

  // Only the owner can withdraw principal.
  await expectRevert(() => vaultByStranger.withdraw(ETH, ethers.parseEther('0.1')));
  console.log('ok - non-owner withdrawal reverts');

  await (await vaultByExecutor.recallFromStrategy(strategyAddr, ETH, ethers.parseEther('0.3'))).wait();
  await assertBalance(provider, vaultAddr, one, 'recall');
  console.log('ok - recall returned the full 0.3 ETH to the vault');

  // No funded yield, no claim.
  await expectRevertReason(rpcUrl, vault, userAddr, 'claimYield', [ETH], 'nothing to claim');
  // Fund the reserve with real ETH, credit it, then the owner can claim.
  await (await vaultByExecutor.fundYieldETH({ value: ethers.parseEther('0.05') })).wait();
  await (await vaultByExecutor.creditYield(ETH, ethers.parseEther('0.05'))).wait();
  await (await vault.claimYield(ETH)).wait();
  await assertBalance(provider, vaultAddr, one, 'claim');
  console.log('ok - funded yield credited and claimed; vault back to principal only');

  await (await vault.withdraw(ETH, one)).wait();
  await assertBalance(provider, vaultAddr, 0n, 'withdraw');
  console.log('ok - owner withdrew the full principal');

  console.log('\nALL TESTS PASSED');
  await server.close();
}

main().catch((e) => {
  console.error('TEST FAILED:', e.message || e);
  process.exit(1);
});
