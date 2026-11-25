const fs = require('fs');
const path = require('path');
const solc = require('solc');

const sources = {};
for (const f of ['QuiverVault.sol', 'QuiverVaultFactory.sol', 'SimpleStrategy.sol', 'PerpStrategy.sol', 'MorphoStrategy.sol', 'StakingStrategy.sol', 'LPStrategy.sol']) {
  sources[f] = { content: fs.readFileSync(path.join(__dirname, 'contracts', f), 'utf8') };
}
const input = {
  language: 'Solidity',
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
  },
};
const out = JSON.parse(solc.compile(JSON.stringify(input)));
let failed = false;
for (const e of out.errors || []) {
  console.log(e.severity.toUpperCase() + ': ' + e.formattedMessage);
  if (e.severity === 'error') failed = true;
}
if (failed) process.exit(1);
fs.mkdirSync(path.join(__dirname, 'out'), { recursive: true });
for (const [file, contracts] of Object.entries(out.contracts)) {
  for (const [name, c] of Object.entries(contracts)) {
    fs.writeFileSync(path.join(__dirname, 'out', name + '.json'),
      JSON.stringify({ contractName: name, source: file, abi: c.abi, bytecode: c.evm.bytecode.object }, null, 2));
    console.log(`OK ${name}: bytecode ${c.evm.bytecode.object.length / 2} bytes, ${c.abi.length} ABI entries`);
  }
}
