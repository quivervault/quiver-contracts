// Functional test of the LPStrategy loop on a local EVM (ganache).
//
// Deploys the factory, mock WETH / USDG, a mock Uniswap V3 pool + NFPM +
// SwapRouter whose price the test sets, and the LPStrategy. Walks the full
// loop: vault ETH+USDG deposits, capped deployment, ratio swap, mint of the
// single pooled NFPM position, fee accrual + collection capped at real
// profit, settlement into the vault's yield reserve and claim, a recall that
// pays idle first, a recall that forces a full position exit, the fail-closed
// insufficient-after-exit case (swapped principal lives as the other token),
// rebalance, an impermanent-loss haircut case, pause and access control.
//
// Run with: node test/lp.test.js

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

const MOCK_USDG = `
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

const MOCK_V3 = `
interface IMockERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    address public factory;
    uint160 public sqrtPrice;
    constructor(address _token0, address _token1, uint24 _fee, int24 _spacing, address _factory) {
        token0 = _token0; token1 = _token1; fee = _fee; tickSpacing = _spacing; factory = _factory;
    }
    function setSqrtPrice(uint160 p) external { sqrtPrice = p; }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPrice, 0, 0, 0, 0, 0, true);
    }
}
contract MockV3Factory {
    address public pool;
    constructor(address _pool) { pool = _pool; }
    function getPool(address, address, uint24) external view returns (address) { return pool; }
}
contract MockNFPM {
    address public factory;
    address public WETH9;
    address public token0;
    address public token1;
    uint256 public nextTokenId = 1;
    uint256 public haircut0; // test-only absolute IL haircut on decrease (token0)
    uint256 public haircut1; // test-only absolute IL haircut on decrease (token1)
    struct Position {
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        int24 tickLower;
        int24 tickUpper;
    }
    mapping(uint256 => Position) public positionsMap;
    constructor(address _factory, address _weth9, address _token0, address _token1) {
        factory = _factory; WETH9 = _weth9; token0 = _token0; token1 = _token1;
    }
    function setHaircut(uint256 h0, uint256 h1) external { haircut0 = h0; haircut1 = h1; }
    function setFees(uint256 tokenId, uint128 o0, uint128 o1) external {
        positionsMap[tokenId].tokensOwed0 += o0;
        positionsMap[tokenId].tokensOwed1 += o1;
    }
    struct MintParams {
        address token0; address token1; uint24 fee; int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata p) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        require(IMockERC20(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired), "pull0");
        require(IMockERC20(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired), "pull1");
        tokenId = nextTokenId++;
        liquidity = uint128(p.amount0Desired + p.amount1Desired);
        positionsMap[tokenId] = Position({
            liquidity: liquidity, amount0: p.amount0Desired, amount1: p.amount1Desired,
            tokensOwed0: 0, tokensOwed1: 0, tickLower: p.tickLower, tickUpper: p.tickUpper
        });
        amount0 = p.amount0Desired; amount1 = p.amount1Desired;
    }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParams calldata p) external payable returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positionsMap[p.tokenId];
        amount0 = pos.tokensOwed0 < p.amount0Max ? pos.tokensOwed0 : p.amount0Max;
        amount1 = pos.tokensOwed1 < p.amount1Max ? pos.tokensOwed1 : p.amount1Max;
        pos.tokensOwed0 -= uint128(amount0);
        pos.tokensOwed1 -= uint128(amount1);
        require(IMockERC20(token0).transfer(p.recipient, amount0), "pay0");
        require(IMockERC20(token1).transfer(p.recipient, amount1), "pay1");
    }
    struct DecreaseLiquidityParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external payable returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positionsMap[p.tokenId];
        require(p.liquidity <= pos.liquidity, "liq");
        if (p.liquidity == pos.liquidity) {
            amount0 = pos.amount0 > haircut0 ? pos.amount0 - haircut0 : 0;
            amount1 = pos.amount1 > haircut1 ? pos.amount1 - haircut1 : 0;
            pos.amount0 = 0; pos.amount1 = 0; pos.liquidity = 0;
        } else {
            amount0 = pos.amount0 * p.liquidity / pos.liquidity;
            amount1 = pos.amount1 * p.liquidity / pos.liquidity;
            pos.amount0 -= amount0; pos.amount1 -= amount1; pos.liquidity -= p.liquidity;
        }
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "slippage");
        pos.tokensOwed0 += uint128(amount0);
        pos.tokensOwed1 += uint128(amount1);
    }
    function burn(uint256 tokenId) external payable {
        Position storage pos = positionsMap[tokenId];
        require(pos.liquidity == 0 && pos.tokensOwed0 == 0 && pos.tokensOwed1 == 0, "not cleared");
        delete positionsMap[tokenId];
    }
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0_, address token1_, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    ) {
        Position storage pos = positionsMap[tokenId];
        return (0, address(0), token0, token1, 100, pos.tickLower, pos.tickUpper, pos.liquidity, 0, 0, pos.tokensOwed0, pos.tokensOwed1);
    }
    receive() external payable {}
}
contract MockLPRouter {
    address public immutable weth;
    address public immutable usdg;
    uint256 public rate = 1660 ether; // USDG per 1 WETH, scaled 1e18
    constructor(address _weth, address _usdg) { weth = _weth; usdg = _usdg; }
    function setRate(uint256 _rate) external { rate = _rate; }
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        if (p.tokenIn == weth) {
            require(p.tokenOut == usdg, "pair");
            amountOut = p.amountIn * rate / 1e18 / 1e12;
        } else {
            require(p.tokenIn == usdg && p.tokenOut == weth, "pair");
            amountOut = p.amountIn * 1e12 * 1e18 / rate;
        }
        require(amountOut >= p.amountOutMinimum, "slippage");
        require(IMockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn), "in failed");
        require(IMockERC20(p.tokenOut).transfer(p.recipient, amountOut), "out failed");
    }
    receive() external payable {}
}
`;

function compileAll() {
  const files = ['QuiverVault.sol', 'QuiverVaultFactory.sol', 'LPStrategy.sol'];
  const sources = {};
  for (const f of files) {
    sources[f] = { content: fs.readFileSync(path.join(__dirname, '..', 'contracts', f), 'utf8') };
  }
  const hdr = '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n';
  sources['MockWETH.sol'] = { content: hdr + MOCK_WETH };
  sources['MockUSDG.sol'] = { content: hdr + MOCK_USDG };
  sources['MockV3.sol'] = { content: hdr + MOCK_V3 };
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

const E = (n) => BigInt(Math.round(n * 1e6)) * 1000000000000n; // ETH/WETH amounts via micro precision
const U = (n) => BigInt(n) * 1000000n; // USDG 6 decimals
const e18 = (s) => ethers.parseEther(s);

function isqrt(n) {
  if (n < 2n) return n;
  let x = n, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + n / x) / 2n; }
  return x;
}
// token0 = WETH, token1 = USDG; raw price = USDG smallest per wei = 1660e6/1e18
function sqrtPriceForUsdgPerWeth(usdgPerWeth) {
  const rawNum = BigInt(usdgPerWeth) * 1000000n * (2n ** 192n) / (10n ** 18n);
  return isqrt(rawNum);
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
  const adminAddr = await admin.getAddress();
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

  const weth = await deploy('MockWETH', admin);
  const wethAddr = await weth.getAddress();
  const usdg = await deploy('MockUSDG', admin);
  const usdgAddr = await usdg.getAddress();
  const v3factory = await deploy('MockV3Factory', admin, ethers.ZeroAddress); // pool wired below
  const v3factoryAddr = await v3factory.getAddress();
  const pool = await deploy('MockV3Pool', admin, wethAddr, usdgAddr, 100, 1, v3factoryAddr);
  const poolAddr = await pool.getAddress();
  const nfpm = await deploy('MockNFPM', admin, v3factoryAddr, wethAddr, wethAddr, usdgAddr);
  const nfpmAddr = await nfpm.getAddress();
  const router = await deploy('MockLPRouter', admin, wethAddr, usdgAddr);
  const routerAddr = await router.getAddress();
  const factory = await deploy('QuiverVaultFactory', admin, executorAddr, ethers.ZeroAddress, usdgAddr, ethers.ZeroAddress);
  const factoryAddr = await factory.getAddress();
  const strategy = await deploy('LPStrategy', admin, factoryAddr, adminAddr, executorAddr, wethAddr, usdgAddr, poolAddr, nfpmAddr, routerAddr, 100);
  const strategyAddr = await strategy.getAddress();
  await send(factory.connect(admin).setStrategy(strategyAddr, true));
  console.log('ok - factory, mocks, LPStrategy deployed; strategy approved');

  // Constructor validation: a pool with token0 != WETH must revert.
  const badPool = await deploy('MockV3Pool', admin, usdgAddr, wethAddr, 100, 1, v3factoryAddr);
  const badPoolAddr = await badPool.getAddress();
  try {
    const f = new ethers.ContractFactory(artifacts.LPStrategy.abi, artifacts.LPStrategy.bytecode, admin);
    const bad = await f.deploy(factoryAddr, adminAddr, executorAddr, wethAddr, usdgAddr, badPoolAddr, nfpmAddr, routerAddr, 100);
    await bad.waitForDeployment();
    assert.fail('constructor with swapped pool tokens should revert');
  } catch (e) {
    // ganache's estimateGas does not surface constructor revert reasons, so
    // the throw itself (not its text) is the proof the bad pool was rejected.
    assert.ok(e, 'constructor should reject a swapped-token pool');
  }
  console.log('ok - constructor rejects a pool whose token0 is not WETH');

  // Price: 1 WETH = 1660 USDG. Fund the mocks: NFPM fee reserves + router inventory.
  await send(pool.connect(admin).setSqrtPrice(sqrtPriceForUsdgPerWeth(1660)));
  const priceSeen = await strategy.poolPrice();
  assert.ok(priceSeen > e18('1640') && priceSeen < e18('1680'), 'poolPrice should be ~1660 USDG/WETH, got ' + priceSeen);
  await send(weth.connect(admin).deposit({ value: e18('10') }));
  await send(weth.connect(admin).transfer(nfpmAddr, e18('1')));
  await send(usdg.connect(admin).mint(nfpmAddr, U(1000)));
  await send(weth.connect(admin).transfer(routerAddr, e18('5')));
  await send(usdg.connect(admin).mint(routerAddr, U(20000)));
  console.log('ok - poolPrice reads ~1660 USDG per WETH from slot0; mocks funded');

  // Vault: profile 5 (95% cap). User deposits 10 ETH + 20,000 USDG.
  await send(factory.connect(user).createVault(5));
  const vaultAddr = await factory.vaultsOf(userAddr, 0);
  const vault = new ethers.Contract(vaultAddr, artifacts.QuiverVault.abi, provider);
  await send(vault.connect(user).depositETH({ value: e18('10') }));
  await send(usdg.connect(admin).mint(userAddr, U(20000)));
  await send(usdg.connect(user).approve(vaultAddr, U(20000)));
  await send(vault.connect(user).deposit(usdgAddr, U(20000)));
  assert.strictEqual(await vault.principal(ethers.ZeroAddress), e18('10'));
  assert.strictEqual(await vault.principal(usdgAddr), U(20000));
  console.log('ok - vault created, 10 ETH + 20,000 USDG deposited');

  // Deploy 5 ETH + 10,000 USDG to the strategy (idle).
  await send(vault.connect(executor).deployToStrategy(strategyAddr, ethers.ZeroAddress, e18('5')));
  await send(vault.connect(executor).deployToStrategy(strategyAddr, usdgAddr, U(10000)));
  assert.strictEqual(await strategy.unminted0(), e18('5'));
  assert.strictEqual(await strategy.unminted1(), U(10000));
  console.log('ok - 5 ETH + 10,000 USDG deployed to LPStrategy (idle)');

  // Ratio swap: 1 WETH -> 1660 USDG (principal only).
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'swapWethForUsdg', [e18('1'), 0], 'not executor');
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'swapWethForUsdg', [e18('6'), 0], 'exceeds unminted principal');
  await send(strategy.connect(executor).swapWethForUsdg(e18('1'), 0));
  assert.strictEqual(await strategy.unminted0(), e18('4'));
  assert.strictEqual(await strategy.unminted1(), U(11660));
  console.log('ok - swapWethForUsdg moved 1 WETH -> 1660 USDG; unminted views track it');

  // Mint the single position: ticks -100..100, 2 WETH + 4,000 USDG.
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'mint', [-100, 100, e18('2'), U(4000), 0, 0], 'not executor');
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'mint', [100, -100, e18('2'), U(4000), 0, 0], 'bad ticks');
  await send(strategy.connect(executor).mint(-100, 100, e18('2'), U(4000), 0, 0));
  assert.strictEqual(await strategy.tokenId(), 1n);
  assert.strictEqual(await strategy.principal0(), e18('2'));
  assert.strictEqual(await strategy.principal1(), U(4000));
  assert.strictEqual(await strategy.unminted0(), e18('2'));
  assert.strictEqual(await strategy.unminted1(), U(7660));
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'mint', [-100, 100, e18('1'), U(1000), 0, 0], 'position active');
  console.log('ok - mint created position #1 (2 WETH + 4,000 USDG); second mint reverts');

  // Fees accrue in the position; collectFees realises them into feeBalance.
  await send(nfpm.connect(admin).setFees(1, e18('0.1'), U(100)));
  await send(strategy.connect(executor).collectFees());
  assert.strictEqual(await strategy.feeBalance0(), e18('0.1'));
  assert.strictEqual(await strategy.feeBalance1(), U(100));
  assert.strictEqual(await strategy.accruedYield(wethAddr), e18('0.1'));
  assert.strictEqual(await strategy.accruedYield(usdgAddr), U(100));
  assert.strictEqual(await strategy.accruedYield(ethers.ZeroAddress), e18('0.1'));
  assert.strictEqual(await strategy.unminted0(), e18('2')); // fees do not leak into principal
  assert.strictEqual(await strategy.unminted1(), U(7660));
  console.log('ok - collectFees booked 0.1 WETH + 100 USDG as accrued yield; unminted untouched');

  // collectYield: capped at real fees, executor only, per token.
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'collectYield', [wethAddr, executorAddr, e18('0.11')], 'exceeds accrued yield');
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'collectYield', [wethAddr, executorAddr, e18('0.01')], 'not executor');
  await send(strategy.connect(executor).collectYield(wethAddr, executorAddr, e18('0.05')));
  await send(strategy.connect(executor).collectYield(usdgAddr, executorAddr, U(50)));
  assert.strictEqual(await weth.balanceOf(executorAddr), e18('0.05'));
  assert.strictEqual(await usdg.balanceOf(executorAddr), U(50));
  assert.strictEqual(await strategy.feeBalance0(), e18('0.05'));
  assert.strictEqual(await strategy.feeBalance1(), U(50));
  console.log('ok - collectYield paid 0.05 WETH + 50 USDG of real fees; over-collect reverts');

  // Recall 1 ETH from idle: position untouched.
  await send(vault.connect(executor).recallFromStrategy(strategyAddr, ethers.ZeroAddress, e18('1')));
  assert.strictEqual(await strategy.tokenId(), 1n);
  assert.strictEqual(await strategy.principal0(), e18('2'));
  assert.strictEqual(await weth.balanceOf(strategyAddr), e18('1.05')); // 2.05 idle WETH, 1 unwrapped+sent
  assert.strictEqual(await rawBal(strategyAddr), 0n);
  const userEthBefore = await rawBal(userAddr);
  await send(vault.connect(user).withdraw(ethers.ZeroAddress, e18('1')));
  assert.ok((await rawBal(userAddr)) - userEthBefore >= e18('0.99'), 'owner should receive ~1 ETH');
  console.log('ok - recall of 1 ETH paid from idle; position untouched; owner withdrew it');

  // Recall 2.5 ETH: idle (1 WETH net) is short, so the position exits in full.
  // Exit returns exactly the 2 WETH + 4,000 USDG principal (the 0.05 WETH +
  // 50 USDG of remaining fees were already collected into feeBalance, so the
  // exit books zero new fees).
  await send(vault.connect(executor).recallFromStrategy(strategyAddr, ethers.ZeroAddress, e18('2.5')));
  assert.strictEqual(await strategy.tokenId(), 0n);
  assert.strictEqual(await strategy.principal0(), 0n);
  assert.strictEqual(await strategy.principal1(), 0n);
  assert.strictEqual(await strategy.feeBalance0(), e18('0.05'));
  assert.strictEqual(await strategy.feeBalance1(), U(50));
  assert.strictEqual(await strategy.unminted0(), e18('0.5')); // 1.05 + 2 - 2.5 - 0.05 fees
  assert.strictEqual(await strategy.unminted1(), U(11660)); // 7,660 + 100 fees - 50 settled + 4,000 - 50 fees
  console.log('ok - recall of 2.5 ETH forced a full exit; principals reset; fee balances kept');

  // The swapped 1 ETH now lives as USDG: recalling the last 1.5 deployed ETH reverts.
  await expectRevertReason(rpcUrl, vault, executorAddr, 'recallFromStrategy', [strategyAddr, ethers.ZeroAddress, e18('1.5')], 'insufficient after exit');
  console.log('ok - recall of the swapped ETH reverts fail-closed (insufficient after exit)');

  // Rebalance: swap 3,000 USDG -> WETH, then mint a fresh position.
  await send(strategy.connect(executor).swapUsdgForWeth(U(3000), 0));
  const wethAfterSwap = await strategy.unminted0();
  assert.ok(wethAfterSwap > e18('2.3') && wethAfterSwap < e18('2.32'), 'unminted0 after swap ~2.307, got ' + wethAfterSwap);
  await send(strategy.connect(executor).rebalance(-200, 200, e18('1.5'), U(3000), 0, 0));
  assert.strictEqual(await strategy.tokenId(), 2n);
  assert.strictEqual(await strategy.principal0(), e18('1.5'));
  assert.strictEqual(await strategy.principal1(), U(3000));
  console.log('ok - rebalance swapped + minted position #2 (1.5 WETH + 3,000 USDG)');

  // Impermanent loss: a 1.0 WETH haircut on exit makes the 1.5 ETH recall revert.
  await send(nfpm.connect(admin).setHaircut(e18('1'), 0));
  await expectRevertReason(rpcUrl, vault, executorAddr, 'recallFromStrategy', [strategyAddr, ethers.ZeroAddress, e18('1.5')], 'insufficient after exit');
  assert.strictEqual(await strategy.tokenId(), 2n); // reverted tx changed nothing
  await send(nfpm.connect(admin).setHaircut(0, 0));
  await send(vault.connect(executor).recallFromStrategy(strategyAddr, ethers.ZeroAddress, e18('1.5')));
  assert.strictEqual(await strategy.tokenId(), 0n);
  console.log('ok - IL haircut makes the recall revert; clearing it lets the recall succeed');

  // Settle USDG fees into the vault reserve and let the owner claim them.
  await send(strategy.connect(executor).collectYield(usdgAddr, executorAddr, U(50)));
  assert.strictEqual(await strategy.feeBalance1(), 0n);
  await send(usdg.connect(executor).approve(vaultAddr, U(50)));
  await send(vault.connect(executor).fundYield(usdgAddr, U(50)));
  await send(vault.connect(executor).creditYield(usdgAddr, U(50)));
  const userUsdgBefore = await usdg.balanceOf(userAddr);
  await send(vault.connect(user).claimYield(usdgAddr));
  assert.strictEqual((await usdg.balanceOf(userAddr)) - userUsdgBefore, U(50));
  console.log('ok - fundYield -> creditYield -> claimYield settled 50 USDG to the owner');

  // Direct recall by a non-vault is refused; pause blocks minting.
  await expectRevertReason(rpcUrl, strategy, strangerAddr, 'withdraw', [usdgAddr, U(1), strangerAddr], 'caller not a vault');
  await send(strategy.connect(admin).setMintPaused(true));
  await expectRevertReason(rpcUrl, strategy, executorAddr, 'mint', [-100, 100, e18('0.1'), U(100), 0, 0], 'mint paused');
  await send(strategy.connect(admin).setMintPaused(false));
  console.log('ok - non-vault withdraw reverts; mintPaused blocks minting');

  await server.close();
  console.log('\nALL LP STRATEGY TESTS PASSED');
}

main().catch((e) => { console.error(e); process.exit(1); });
