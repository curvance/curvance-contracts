const { execSync } = require('child_process');
const fs = require('fs');
const ethers = require('ethers');
require('dotenv').config();

const exampleCmd = 'node deploy.js <network> <simulation=true>';
let retry_count = 0;
main().catch(console.error);

async function main() {
  const { isSim, network, rpc, provider } = setup();

  // Build & run command
  let forgeArgs = [
    'script/DeployCurvance.s.sol',
    `"${network}" --sig "run(string)"`,
    `--rpc-url ${rpc}`,
    '-vvvv',
    '--ffi'
  ];

  if (isSim) {
    console.log(`Deploying to ${network} [TEST-RUN]`);
  } else {
    forgeArgs = forgeArgs.concat([
      '--broadcast',
      '--skip-simulation',
      '--no-storage-caching',
      '--priority-gas-price 150',
      '-g 230',
      '--resume'
    ]);
    console.log(`Deploying to ${network}`);
  }

  let finished_deploy = false;
  try {
    execSync(`forge script ${forgeArgs.join(' ')}`, { stdio: 'inherit' });
    finished_deploy = true;
  } catch (err) {
    console.error('\nError executing forge command.');
  }

  // Parse broadcast results to see what deployments made it
  if (!isSim) {
    console.log('REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS');
    console.log('REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS');
    console.log('REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS');

    const rpcNetwork = await provider.getNetwork();
    const chainId = rpcNetwork.chainId;
    const deployResults = JSON.parse(fs.readFileSync(`./broadcast/DeployCurvance.s.sol/${chainId}/run-latest.json`, 'utf8'));
    const simResults = JSON.parse(fs.readFileSync(`./deployments/${network}.json`, 'utf8'));
    let reverseSimResults = {};

    for (const key in simResults) {
      const contractAddress = simResults[key].toLowerCase();
      reverseSimResults[contractAddress] = key;
    }

    const contracts_deployed = deployResults.receipts.reduce((acc, val) => {
      if (val.to == null && val.contractAddress != null) {
        const contractAddress = val.contractAddress.toLowerCase();
        if (reverseSimResults[contractAddress]) {
          const contractName = reverseSimResults[contractAddress];
          acc[contractName] = contractAddress;
        }
      }
      return acc;
    }, {});

    if (fs.existsSync(`./deployments/deployed/${network}.json`)) {
      const oldDeployments = JSON.parse(fs.readFileSync(`./deployments/deployed/${network}.json`, 'utf8'));
      for (const key in oldDeployments) {
        if (!contracts_deployed[key]) {
          contracts_deployed[key] = oldDeployments[key];
        }
      }
    }

    fs.writeFileSync(`./deployments/deployed/${network}.json`, JSON.stringify(contracts_deployed, null, 2), { encoding: 'utf8', flag: 'w' });


    if (!finished_deploy) {
      retry_count++
      console.log(`Deployment failed (${retry_count}), retrying... Sleeping for 60 seconds before retrying`);

      await new Promise((resolve) => setTimeout(resolve, 15000));
      console.log('Retrying in 45 seconds...');
      await new Promise((resolve) => setTimeout(resolve, 15000));
      console.log('Retrying in 30 seconds...');
      await new Promise((resolve) => setTimeout(resolve, 15000));
      console.log('Retrying in 15 seconds...');
      await new Promise((resolve) => setTimeout(resolve, 15000));

      await main();
    }
  }
}

function setup() {
  // Load .env file
  if (!process.env.PRIVATE_KEY) {
    console.error('Error loading .env file');
    process.exit(1);
  }

  // Validate private key
  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.error('PRIVATE_KEY not set in .env');
    process.exit(1);
  }
  if (!privateKey.startsWith('0x')) {
    console.error('PRIVATE_KEY must start with 0x');
    process.exit(1);
  }

  // Require forge
  let forgePath;
  try {
    forgePath = execSync('which forge').toString().trim();
  } catch (err) {
    console.error('Forge not found. Please install foundry.');
    process.exit(1);
  }

  // Require network & setup args
  const args = process.argv.slice(2);
  if (args.length < 1) {
    console.error('Incorrect number of arguments. Example: \n', exampleCmd);
    process.exit(1);
  }
  const network = args[0];
  let isSim = true;
  if (args.length > 1) {
    isSim = args[1] !== 'false';
  }

  // Get RPC from env & ensure it exists
  const envPath = `ETH_NODE_URI_${network.toUpperCase()}`;
  const rpc = process.env[envPath];
  if (!rpc) {
    console.error(`RPC not found for network (${envPath}): `, network);
    process.exit(1);
  }
  const provider = new ethers.providers.JsonRpcProvider(rpc);

  return { privateKey, forgePath, isSim, network, rpc, provider };
}
