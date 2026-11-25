// Functional test of the MorphoStrategy loop on a local EVM (ganache).
//
// Deploys the factory, a mock USDG, a mock ERC-4626 Morpho vault whose
// share rate the test can bump to simulate lending interest, and the
// MorphoStrategy. Walks the full loop: vault deposit, capped deployment,
// supply into Morpho, yield accrual, yield collection capped at real
// profit, settlement into the vault's yield reserve and claim, and a
// recall that pays idle first and redeems only the shortfall.
//
// Run with: node test/morpho.test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const solc = require('solc');
const ganache = require('ganache');
const { ethers } = require('ethers');

const MOCK_ERC20 = `
contract MockUSDG {
    string public name = "Mock USDG";
    string public symbol = "USDG";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    function mint(address to, uint256 amount) external { totalSupply += amount; balanceOf[to] += amount; emit Transfer(address(0), to, amount); }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transfer(address to, uint256 amount) external returns (bool) { _move(msg.sender, to, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }
    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount);
    }
}
`;

const MOCK_MORPHO = `
contract MockMorphoVault {
    MockUSDG public immutable assetToken;
    uint256 public rate = 1e18; // assets per 1e18 shares, scaled 1e18
    mapping(address => uint256) public balanceOf; // shares
    constructor(address _asset) { assetToken = MockUSDG(_asset); }
    function setRate(uint256 _rate) external { rate = _rate; }
    function asset() external view returns (address) { return address(assetToken); }
    function totalAssets() external view returns (uint256) { return assetToken.balanceOf(address(this)); }
    function convertToAssets(uint256 shares) public view returns (uint256) { return shares * rate / 1e18; }
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(assetToken.transferFrom(msg.sender, address(this), assets), "pull failed");
        shares = assets * 1e18 / rate;
        balanceOf[receiver] += shares;
    }
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = (assets * 1e18 + rate - 1) / rate;
        require(balanceOf[owner] >= shares, "shares");
        balanceOf[owner] -= shares;
        require(assetToken.transfer(receiver, assets), "pay failed");
    }
}
`;

function compileAll() {
  const files = ['QuiverVault.sol', 'QuiverVaultFactory.sol', 'MorphoStrategy.sol'];
  const sources = {};
  for (const f of files) {
    sources[f] = { content: fs.readFileSync(path.join(__dirname, '..', 'contracts', f), 'utf8') };
  }
  sources['MockUSDG.sol'] = { content: '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n' + MOCK_ERC20 };
  sources['MockMorphoVault.sol'] = { content: '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\nimport "./MockUSDG.sol";\n' + MOCK_MORPHO };
  const input = {
    language: 'Solidity',
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: 'shanghai',
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
    },
  };
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (out.errors || []).filter((e) => e.severity === 'error');
  assert.strictEqual(errors.length, 0, 'compile errors: ' + JSON.stringify(errors));
  const artifacts = {};
  for (const contracts of Object.values(out.contracts)) {
    for (const [name, c] of Object.entries(contracts)) artifacts[name] = { abi: c.abi, bytecode: c.evm.bytecode.object };
  }
  return artifacts;
}

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

const U = (n) => BigInt(n) * 1000000n; // USDG 6 decimals

async function main() {
  const artifacts = compileAll();
  console.log('ok - contracts + mocks compile (solc 0.8.24, optimizer 200)');

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
  const strangerAddr = await stranger.getAddress();

  const deploy = async (name, signer, ...args) => {
    const f = new ethers.ContractFactory(artifacts[name].abi, artifacts[name].bytecode, signer);
    const c = await f.deploy(...args);
    await c.waitForDeployment();
    return c;
  };
  const send = async (txPromise) => { const tx = await txPromise; await tx.wait(); };

  const usdg = await deploy('MockUSDG', admin);
  const usdgAddr = await usdg.getAddress();
  const factory = await deploy('QuiverVaultFactory', admin, executorAddr, ethers.ZeroAddress, usdgAddr, ethers.ZeroAddress);
  const factoryAddr = await factory.getAddress();
  const morpho = await deploy('MockMorphoVault', admin, usdgAddr);
  const morphoAddr = await morpho.getAddress();
  const strategy = await deploy('MorphoStrategy', admin, factoryAddr, await admin.getAddress(), executorAddr, morphoAddr, usdgAddr);
  const strategyAddr = await strategy.getAddress();
  await send(factory.connect(admin).setStrategy(strategyAddr, true));
  console.log('ok - factory, mock USDG, mock Morpho vault, MorphoStrategy deployed; strategy approved');

  // Vault: profile 5 (95% cap). User deposits 1000 USDG.
  await send(factory.connect(user).createVault(5));
  const vaultAddr = await factory.vaultsOf(userAddr, 0);
  const vault = new ethers.Contract(vaultAddr, artifacts.QuiverVault.abi, provider);
  await send(usdg.connect(admin).mint(userAddr, U(1000)));
  await send(usdg.connect(user).approve(vaultAddr, U(1000)));
  await send(vault.connect(user).deposit(usdgAddr, U(1000)));
  assert.strictEqual(await vault.principal(usdgAddr), U(1000));
  console.log('ok - vault created, 1000 USDG deposited');

  // Deploy 800 to the strategy (80% <= 95% cap).
  await send(vault.connect(executor).deployToStrategy(strategyAddr, usdgAddr, U(800)));
  assert.strictEqual(await usdg.balanceOf(strategyAddr), U(800));
  console.log('ok - 800 USDG deployed to MorphoStrategy (idle)');

  // supply() is executor-only.
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'supply', [], 'not executor');
  await send(strategy.connect(executor).supply());
  assert.strictEqual(await strategy.suppliedPrincipal(), U(800));
  assert.strictEqual(await usdg.balanceOf(strategyAddr), 0n);
  assert.strictEqual(await strategy.positionValue(), U(800));
  assert.strictEqual(await strategy.accruedYield(), 0n);
  console.log('ok - supply() swept 800 into Morpho; position 800, yield 0');

  // Simulate +5% lending interest inside Morpho.
  await send(morpho.connect(admin).setRate(1050000000000000000n));
  assert.strictEqual(await strategy.positionValue(), U(840));
  assert.strictEqual(await strategy.accruedYield(), U(40));
  assert.strictEqual(await strategy.balanceOf(usdgAddr), U(840));
  console.log('ok - rate +5%: position 840, accruedYield 40, balanceOf 840');

  // collectYield: capped at real profit, executor only.
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'collectYield', [executorAddr, U(41)], 'exceeds accrued yield');
  await send(strategy.connect(executor).collectYield(executorAddr, U(40)));
  assert.strictEqual(await usdg.balanceOf(executorAddr), U(40));
  assert.strictEqual(await strategy.accruedYield(), 0n);
  assert.strictEqual(await strategy.suppliedPrincipal(), U(800));
  console.log('ok - collectYield paid exactly the 40 profit; principal basis untouched');

  // Settle the profit into the vault reserve and let the owner claim it.
  await send(usdg.connect(executor).approve(vaultAddr, U(40)));
  await send(vault.connect(executor).fundYield(usdgAddr, U(40)));
  await send(vault.connect(executor).creditYield(usdgAddr, U(40)));
  const userBefore = await usdg.balanceOf(userAddr);
  await send(vault.connect(user).claimYield(usdgAddr));
  assert.strictEqual((await usdg.balanceOf(userAddr)) - userBefore, U(40));
  console.log('ok - fundYield -> creditYield -> claimYield settled 40 to the owner');

  // Second deposit + deploy leaves 200 idle in the strategy; a 250 recall
  // must pay 200 idle and redeem only 50 from Morpho.
  await send(usdg.connect(admin).mint(userAddr, U(200)));
  await send(usdg.connect(user).approve(vaultAddr, U(200)));
  await send(vault.connect(user).deposit(usdgAddr, U(200)));
  await send(vault.connect(executor).deployToStrategy(strategyAddr, usdgAddr, U(200)));
  assert.strictEqual(await usdg.balanceOf(strategyAddr), U(200));
  await send(vault.connect(executor).recallFromStrategy(strategyAddr, usdgAddr, U(250)));
  assert.strictEqual(await strategy.suppliedPrincipal(), U(750));
  // ERC-4626 withdrawals round share burns in the vault's favour, so the
  // remaining position can sit a few wei under the redeemed amount.
  const posAfterRecall = await strategy.positionValue();
  assert.ok(U(750) - posAfterRecall >= 0n && U(750) - posAfterRecall <= 10n, 'position after recall ~750, got ' + posAfterRecall);
  console.log('ok - recall of 250 paid 200 idle + 50 redeemed; basis and position now 750');

  // Owner withdraws all free principal: 1200 principal - 750 deployed = 450.
  const before2 = await usdg.balanceOf(userAddr);
  await send(vault.connect(user).withdraw(usdgAddr, U(450)));
  assert.strictEqual((await usdg.balanceOf(userAddr)) - before2, U(450));
  console.log('ok - owner withdrew 450 free principal');

  // Direct recall by a non-vault is refused.
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'withdraw', [usdgAddr, U(1), strangerAddr], 'caller not a vault');
  console.log('ok - direct withdraw by a non-vault reverts');

  await server.close();
  console.log('\nALL MORPHO STRATEGY TESTS PASSED');
}

main().catch((e) => { console.error(e); process.exit(1); });
