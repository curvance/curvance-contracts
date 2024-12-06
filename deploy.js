const { execSync } = require('child_process');
const ethers = require('ethers');
require('dotenv').config();

const exampleCmd = 'node deploy.js <network> <simulation=true> <resume=false>';
let retry_count = 0;
main().catch(console.error);

async function main() {
  const { isSim, network, rpc, resume } = setup();
  const scripts = [
    'script/DeployTestnetTokens.s.sol',
    'script/DeploySetupOracles.s.sol',
    'script/DeployExecuteRedstoneFeeds.s.sol',
    'script/DeployCurvance.s.sol'
  ];

  const generateForgeScript = (script) => {
    // Build & run command
    let forgeArgs = [
      script,
      `"${network}" --sig "run(string)"`,
      `--rpc-url ${rpc}`,
      '-vvvv',
      '--ffi',
      `--with-gas-price 30gwei`,
    ];

    if (resume) {
      forgeArgs.push('--resume');
    }

    if (isSim) {
      console.log(`Deploying to ${network} [TEST-RUN]`);
    } else {
      forgeArgs = forgeArgs.concat([
        '--broadcast',
        '--skip-simulation',
        '--no-storage-caching',
        '--priority-gas-price 200',
        '-g 230'
      ]);
      console.log(`Deploying to ${network}`);
    }

    return forgeArgs;
  }

  let finished_deploy = false;
  try {
    for (const script of scripts) {
      const forgeArgs = generateForgeScript(script);
      console.log(`Running forge script for ${script}`);
      execSync(`forge script ${forgeArgs.join(' ')}`, { stdio: 'inherit' });
    }

    finished_deploy = true;
  } catch (err) {
    console.error('\nError executing forge command.');
  }

  // Parse broadcast results to see what deployments made it
  if (!isSim) {
    console.log('REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS');
    console.log('REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS');
    console.log('REMEMBER: UPDATE INDEXER & DAPP WITH NEW CONTRACT ADDRESS');

    if (!finished_deploy && resume) {
      retry_count++
      console.log(`Deployment failed (${retry_count}), retrying...`);

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

  let resume = false;
  if (args.length > 2) {
    resume = args[2] !== 'false';
  }

  // Get RPC from env & ensure it exists
  const envPath = `ETH_NODE_URI_${network.toUpperCase()}`;
  const rpc = process.env[envPath];
  if (!rpc) {
    console.error(`RPC not found for network (${envPath}): `, network);
    process.exit(1);
  }
  const provider = new ethers.JsonRpcProvider(rpc);

  return { privateKey, forgePath, isSim, resume, network, rpc, provider };
}
