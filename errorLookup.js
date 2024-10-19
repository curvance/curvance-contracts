const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

main().catch(console.error);

async function main() {
  const hashGiven = process.argv[2];
  if (!hashGiven) {
    throw new Error('Error hash not provided');
  }

  const compiled_contracts = getJsonFilesWithContents(`${process.cwd()}/artifacts`);

  let errors = {};
  for (const contract_name in compiled_contracts) {
    const contract = compiled_contracts[contract_name];
    if ('abi' in contract === false) {
      continue;
    }

    for (const item of contract.abi) {
      if (item.type === 'error') {
        const full_error = `${item.name}(${item.inputs.map((input) => input.type).join(',')})`;
        const signature = ethers.keccak256(ethers.toUtf8Bytes(full_error)).slice(0, 10);

        errors[signature] = {
          contract: contract_name,
          full_error: full_error,
          error: item.name,
          signature: signature,
          inputs: item.inputs,
        };
      }
    }
  }

  if (errors[hashGiven]) {
    console.log(errors[hashGiven]);
  } else {
    console.log('Error not found');
  }

  process.exit();
}


// Function to recursively get all .json files and their parsed content
function getJsonFilesWithContents(dir) {
  let jsonFilesWithContent = {};

  // Read all files and directories within the current directory
  const items = fs.readdirSync(dir);

  items.forEach((item) => {
    const fullPath = path.join(dir, item);

    // Check if it's a directory
    if (fs.lstatSync(fullPath).isDirectory()) {
      // Recursively process subdirectories
      Object.assign(jsonFilesWithContent, getJsonFilesWithContents(fullPath));
    } else if (path.extname(fullPath) === '.json') {
      // If it's a .json file, read and parse the JSON content
      const content = fs.readFileSync(fullPath, 'utf8');
      const fileName = path.basename(fullPath);  // Extract just the file name
      jsonFilesWithContent[fileName] = JSON.parse(content);
    }
  });

  return jsonFilesWithContent;
}
