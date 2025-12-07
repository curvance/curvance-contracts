const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

main().catch(console.error);

async function main() {
  const compiled_contracts = getJsonFilesWithContents(`${process.cwd()}/artifacts`);

  let errorMap = {};

  for (const contract_name in compiled_contracts) {
    const contract = compiled_contracts[contract_name];
    if ('abi' in contract === false) {
      continue;
    }

    for (const item of contract.abi) {
      if (item.type === 'error') {
        const full_error = `${item.name}(${item.inputs.map((input) => input.type).join(',')})`;
        const signature = ethers.keccak256(ethers.toUtf8Bytes(full_error)).slice(0, 10);
        const real_contract_name = contract_name.replace('.json', '');

        if (errorMap[signature]) {
          // If error already exists, add contract to the list
          if (!errorMap[signature].contracts.includes(real_contract_name)) {
            errorMap[signature].contracts.push(real_contract_name);
          }
        } else {
          // New error, create entry
          errorMap[signature] = {
            error: item.name,
            full_signature: full_error,
            contracts: [real_contract_name],
            inputs: item.inputs
          };
        }
      }
    }
  }

  // Save as error_map.json
  fs.writeFileSync('error_map.json', JSON.stringify(errorMap, null, 2));

  console.log(`Generated error_map.json with ${Object.keys(errorMap).length} unique error signatures`);

  // Display first few errors as example
  console.log('\nExample mappings:');
  Object.entries(errorMap).slice(0, 5).forEach(([sig, errorInfo]) => {
    console.log(`${sig} -> ${errorInfo.error}`);
  });

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
