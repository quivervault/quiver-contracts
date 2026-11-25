// Functional test of the StakingStrategy loop on a local EVM (ganache).
//
// Deploys the factory, mock WETH / wstETH, a mock Uniswap V3 pool + factory
// whose slot0 the test sets from a rate, a mock SwapRouter02 that exchanges
// ETH <-> wstETH at that same rate, and the StakingStrategy. Walks the full
// loop: vault ETH deposit, capped deployment, stake into wstETH, yield
// accrual through rate appreciation, yield collection capped at real
// profit, a recall that pays idle first and swaps back only the shortfall,
// the pause switch, and the fail-closed no-pool case.
//
// Run with: node test/staking.test.js

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const solc = require('solc');
const ganache = require('ganache');
const { ethers } = require('ethers');

const MOCK_WETH = `
contract MockWETH {
    string public name = "Mock WETH";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    function deposit() external payable { totalSupply += msg.value; balanceOf[msg.sender] += msg.value; emit Transfer(address(0), msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount; totalSupply -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "eth out failed");
        emit Transfer(msg.sender, address(0), amount);
    }
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
    receive() external payable {}
}
`;

const MOCK_WSTETH = `
contract MockWstETH {
    string public name = "Wrapped liquid staked Ether 2.0";
    string public symbol = "wstETH";
    uint8 public decimals = 18;
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

const MOCK_V3 = `
contract MockV3Pool {
    address public token0;
    address public token1;
    uint160 public sqrtPrice;
    constructor(address _token0, address _token1) { token0 = _token0; token1 = _token1; }
    function setSqrtPrice(uint160 p) external { sqrtPrice = p; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPrice, 0, 0, 0, 0, 0, true);
    }
}
contract MockV3Factory {
    address public pool;
    uint24 public fee;
    constructor(address _pool, uint24 _fee) { pool = _pool; fee = _fee; }
    function getPool(address, address, uint24 _fee) external view returns (address) {
        return _fee == fee ? pool : address(0);
    }
}
`;

const MOCK_ROUTER = `
interface IMockERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
contract MockSwapRouter {
    address public immutable weth;
    address public immutable wsteth;
    uint256 public rate = 1e18; // WETH per 1 wstETH, scaled 1e18
    constructor(address _weth, address _wsteth) { weth = _weth; wsteth = _wsteth; }
    function setRate(uint256 _rate) external { rate = _rate; }
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    struct ExactOutputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(p.tokenIn == weth && p.tokenOut == wsteth, "pair");
        require(msg.value == p.amountIn, "value");
        amountOut = p.amountIn * 1e18 / rate;
        require(amountOut >= p.amountOutMinimum, "slippage");
        require(IMockERC20(wsteth).transfer(p.recipient, amountOut), "wst out failed");
    }
    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256 amountIn) {
        require(p.tokenIn == wsteth && p.tokenOut == weth, "pair");
        // rate is WETH per wstETH, so wstETH needed = amountOut / rate.
        amountIn = (p.amountOut * 1e18 + rate - 1) / rate;
        require(amountIn <= p.amountInMaximum, "slippage");
        require(IMockERC20(wsteth).transferFrom(msg.sender, address(this), amountIn), "wst in failed");
        require(IMockERC20(weth).transfer(p.recipient, p.amountOut), "weth out failed");
    }
    receive() external payable {}
}
`;

function compileAll() {
  const files = ['QuiverVault.sol', 'QuiverVaultFactory.sol', 'StakingStrategy.sol'];
  const sources = {};
  for (const f of files) {
    sources[f] = { content: fs.readFileSync(path.join(__dirname, '..', 'contracts', f), 'utf8') };
  }
  const hdr = '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n';
  sources['MockWETH.sol'] = { content: hdr + MOCK_WETH };
  sources['MockWstETH.sol'] = { content: hdr + MOCK_WSTETH };
  sources['MockV3.sol'] = { content: hdr + MOCK_V3 };
  sources['MockSwapRouter.sol'] = { content: hdr + MOCK_ROUTER };
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
    for (const [name, c] of Object.entries(contracts)) artifacts[name] = { abi: c.abi, evmBytecode: c.evm.bytecode.object, bytecode: c.evm.bytecode.object };
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

const E = (n) => BigInt(Math.round(n * 1e6)) * 1000000000000n; // ETH amounts via micro precision
const e18 = (s) => ethers.parseEther(s);

// integer sqrt for BigInt (for slot0 sqrtPriceX96)
function isqrt(n) {
  if (n < 2n) return n;
  let x = n, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + n / x) / 2n; }
  return x;
}
// token0 = WETH, token1 = wstETH; price = wstETH per WETH = 1e18 / rate
function sqrtPriceForRate(rate) {
  return isqrt((10n ** 18n) * (2n ** 192n) / rate);
}

async function main() {
  const artifacts = compileAll();
  console.log('ok - contracts + mocks compile (solc 0.8.24, optimizer 200)');

  const server = ganache.server({ logging: { quiet: true } });
  await server.listen(0);
  const rpcUrl = 'http://127.0.0.1:' + server.address().port;
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  // NOTE: ethers' JsonRpcProvider returns stale ETH balances against this
  // ganache fallback transport (raw eth_getBalance is correct), so every
  // ETH-balance assertion below goes through rawBal().
  const rawBal = async (addr) => {
    const r = await fetch(rpcUrl, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'eth_getBalance', params: [addr, 'latest'] }) });
    return BigInt((await r.json()).result);
  };
  const admin = await provider.getSigner(0);
  const executor = await provider.getSigner(1);
  const user = await provider.getSigner(2);
  const stranger = await provider.getSigner(3);
  const sink = await provider.getSigner(4);
  const adminAddr = await admin.getAddress();
  const executorAddr = await executor.getAddress();
  const userAddr = await user.getAddress();
  const strangerAddr = await stranger.getAddress();
  const sinkAddr = await sink.getAddress();

  const deploy = async (name, signer, ...args) => {
    const f = new ethers.ContractFactory(artifacts[name].abi, artifacts[name].bytecode, signer);
    const c = await f.deploy(...args);
    await c.waitForDeployment();
    return c;
  };
  const send = async (txPromise) => { const tx = await txPromise; await tx.wait(); };

  const weth = await deploy('MockWETH', admin);
  const wethAddr = await weth.getAddress();
  const wst = await deploy('MockWstETH', admin);
  const wstAddr = await wst.getAddress();
  const pool = await deploy('MockV3Pool', admin, wethAddr, wstAddr);
  const poolAddr = await pool.getAddress();
  const v3factory = await deploy('MockV3Factory', admin, poolAddr, 3000);
  const v3factoryAddr = await v3factory.getAddress();
  const router = await deploy('MockSwapRouter', admin, wethAddr, wstAddr);
  const routerAddr = await router.getAddress();
  const factory = await deploy('QuiverVaultFactory', admin, executorAddr, ethers.ZeroAddress, wstAddr, ethers.ZeroAddress);
  const factoryAddr = await factory.getAddress();
  const strategy = await deploy('StakingStrategy', admin, factoryAddr, adminAddr, executorAddr, wethAddr, wstAddr, routerAddr, v3factoryAddr, 3000);
  const strategyAddr = await strategy.getAddress();
  await send(factory.connect(admin).setStrategy(strategyAddr, true));
  console.log('ok - factory, mocks, StakingStrategy deployed; strategy approved');

  // Router inventory: 1000 wstETH and 100 WETH.
  await send(wst.connect(admin).mint(routerAddr, e18('1000')));
  await send(weth.connect(admin).deposit({ value: e18('100') }));
  await send(weth.connect(admin).transfer(routerAddr, e18('100')));

  // Rate: 1 wstETH = 1.25 ETH.
  const R1 = e18('1.25');
  await send(router.connect(admin).setRate(R1));
  await send(pool.connect(admin).setSqrtPrice(sqrtPriceForRate(R1)));
  const rateSeen = await strategy.rate();
  assert.ok(rateSeen > e18('1.24') && rateSeen < e18('1.26'), 'rate should be ~1.25, got ' + rateSeen);
  console.log('ok - rate() reads ~1.25 ETH per wstETH from slot0');

  // Vault: profile 5 (95% cap). User deposits 20 ETH.
  await send(factory.connect(user).createVault(5));
  const vaultAddr = await factory.vaultsOf(userAddr, 0);
  const vault = new ethers.Contract(vaultAddr, artifacts.QuiverVault.abi, provider);
  await send(vault.connect(user).depositETH({ value: e18('20') }));
  assert.strictEqual(await vault.principal(ethers.ZeroAddress), e18('20'));
  console.log('ok - vault created, 20 ETH deposited');

  // Deploy 16 ETH to the strategy (80% <= 95% cap).
  await send(vault.connect(executor).deployToStrategy(strategyAddr, ethers.ZeroAddress, e18('16')));
  assert.strictEqual(await rawBal(strategyAddr), e18('16'));
  console.log('ok - 16 ETH deployed to StakingStrategy (idle)');

  // stake() is executor-only; then it sweeps all idle ETH into wstETH.
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'stake', [], 'not executor');
  await send(strategy.connect(executor).stake());
  const wstExpected1 = e18('16') * (10n ** 18n) / R1; // 12.8 wstETH
  assert.strictEqual(await strategy.wstBalance(), wstExpected1);
  assert.strictEqual(await strategy.stakedPrincipal(), e18('16'));
  assert.strictEqual(await rawBal(strategyAddr), 0n);
  assert.strictEqual(await strategy.accruedYield(), 0n);
  console.log('ok - stake() swept 16 ETH into 12.8 wstETH; principal basis 16, yield 0');

  // Simulate +5% staking appreciation: 1 wstETH = 1.3125 ETH.
  const R2 = e18('1.3125');
  await send(router.connect(admin).setRate(R2));
  await send(pool.connect(admin).setSqrtPrice(sqrtPriceForRate(R2)));
  const pos = await strategy.positionValue();
  assert.ok(pos > e18('16.79') && pos < e18('16.81'), 'position should be ~16.8 ETH, got ' + pos);
  const y = await strategy.accruedYield();
  assert.ok(y > e18('0.79') && y < e18('0.81'), 'yield should be ~0.8 ETH, got ' + y);
  console.log('ok - rate +5%: position ~16.8 ETH, accruedYield ~0.8 ETH');

  // collectYield: capped at real profit, executor only; pays ETH to the sink.
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'collectYield', [sinkAddr, e18('0.81')], 'exceeds accrued yield');
  const sinkBefore = await rawBal(sinkAddr);
  const wstBeforeCollect = await strategy.wstBalance();
  await send(strategy.connect(executor).collectYield(sinkAddr, e18('0.8')));
  const wstSpentCollect = wstBeforeCollect - (await strategy.wstBalance());
  const wstFor08 = (e18('0.8') * (10n ** 18n) + R2 - 1n) / R2; // 0.8 / 1.3125
  assert.strictEqual(wstSpentCollect, wstFor08);
  assert.strictEqual((await rawBal(sinkAddr)) - sinkBefore, e18('0.8'));
  assert.strictEqual(await strategy.stakedPrincipal(), e18('16'));
  console.log('ok - collectYield paid exactly 0.8 ETH of profit; principal basis untouched');

  // Second round: deposit 4, deploy 4, stake at the new rate.
  await send(vault.connect(user).depositETH({ value: e18('4') }));
  await send(vault.connect(executor).deployToStrategy(strategyAddr, ethers.ZeroAddress, e18('4')));
  await send(strategy.connect(executor).stake());
  assert.strictEqual(await strategy.stakedPrincipal(), e18('20'));
  console.log('ok - second stake: principal basis 20 ETH');

  // Recall: the vault pulls 6 ETH back out of the strategy first
  // (executor calls recallFromStrategy), then the owner withdraws 10.
  const wstBefore = await strategy.wstBalance();
  await send(vault.connect(executor).recallFromStrategy(strategyAddr, ethers.ZeroAddress, e18('6')));
  const wstSpent = wstBefore - (await strategy.wstBalance());
  const wstFor6 = (e18('6') * (10n ** 18n) + R2 - 1n) / R2; // 6 / 1.3125
  assert.strictEqual(wstSpent, wstFor6);
  assert.strictEqual(await strategy.stakedPrincipal(), e18('14'));
  assert.strictEqual(await strategy.accruedYield(), 0n);
  await send(vault.connect(user).withdraw(ethers.ZeroAddress, e18('10')));
  assert.strictEqual(await vault.principal(ethers.ZeroAddress), e18('14'));
  console.log('ok - recall of 6 swapped back exactly; owner withdrew 10, principal now 14');

  // A non-vault caller cannot pull funds out of the strategy.
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'withdraw', [ethers.ZeroAddress, 1n, strangerAddr], 'caller not a vault');
  console.log('ok - non-vault withdraw reverts');

  // Pause blocks stake() but not the accounting. (Principal is 14 after the
  // withdrawal, all of it deployed, so deposit 2 and deploy only 1 to stay
  // under the profile-5 95% deployment cap.)
  await send(vault.connect(user).depositETH({ value: e18('2') }));
  await send(vault.connect(executor).deployToStrategy(strategyAddr, ethers.ZeroAddress, e18('1')));
  await send(strategy.connect(admin).setStakePaused(true));
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'stake', [], 'stake paused');
  await send(strategy.connect(admin).setStakePaused(false));
  await send(strategy.connect(executor).stake());
  assert.strictEqual(await strategy.stakedPrincipal(), e18('15'));
  console.log('ok - stakePaused blocks and unblocks stake()');

  // No pool at the configured fee tier: rate 0, stake fails closed.
  await send(vault.connect(user).depositETH({ value: e18('1') }));
  await send(vault.connect(executor).deployToStrategy(strategyAddr, ethers.ZeroAddress, e18('1')));
  await send(strategy.connect(admin).setPoolFee(500));
  assert.strictEqual(await strategy.rate(), 0n);
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'stake', [], 'no pool');
  await send(strategy.connect(admin).setPoolFee(3000));
  await send(strategy.connect(executor).stake());
  assert.strictEqual(await strategy.stakedPrincipal(), e18('16'));
  console.log('ok - missing pool: rate() 0 and stake() reverts (fail closed); restored at fee 3000');

  console.log('\nALL STAKING TESTS PASSED');
  await server.close();
}

main().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
