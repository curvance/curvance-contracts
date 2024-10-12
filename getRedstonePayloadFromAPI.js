const { appendFileSync, rmSync } = require("fs");
const redstone = require("@redstone-finance/sdk");
const { performance } = require("perf_hooks")

let tokenSymbols, timestamp;

main().catch(err => {
  exit(1, "Failed: " + err.message + "\n\n" + err.stack);
});

async function main() {
  const startTime = performance.now();
  const todaysDate = new Date().toLocaleString();
  log(`--- Start: ${todaysDate} ---`);
  loadArgs();

  const payload = await redstone.requestRedstonePayload({
    dataServiceId: "redstone-primary-prod",
    uniqueSignersCount: 3,
    authorizedSigners: [
      "0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774",
      "0xdEB22f54738d54976C4c0fe5ce6d408E40d88499",
      "0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202",
      "0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE"
    ],
    dataPackagesIds: tokenSymbols,
    historicalTimestamp: timestamp
  });

  log(`Payload for token: ${tokenSymbols.join(',')}`, payload);
  const endTime = performance.now();
  log(`--- End, Ran in: ${endTime - startTime}ms ---`);

  // Return value to contract
  process.stdout.write("0x" + payload);

  process.exit(0);
}

function loadArgs() {
  const args = process.argv.slice(2);
  log("Arguments", JSON.stringify(args));
  if (args.length === 0) {
    exit(2, "You have to provide at least one argument");
  }

  tokenSymbols = args[0].split(",");
  if (tokenSymbols.length === 0) {
    exit(2, "You have to provide at least one token symbol");
  }

  if (args.length > 1) {
    timestamp = Number(args[1]);

    if (!Number.isInteger(timestamp)) {
      exit(2, "Timestamp should be a number");
    }
  }
}

function exit(code, message) {
  process.stderr.write(message);
  appendFileSync("./getRedstonePayloadAPI.log.txt", `***Exited (${code}) with message:***\n ${message}\n`);
  process.exit(code);
};

function log(message, data = null) {
  if (data) {
    appendFileSync("./getRedstonePayloadAPI.log.txt", `${message}:\n ${data}\n\n`);
  } else {
    appendFileSync("./getRedstonePayloadAPI.log.txt", `${message}\n\n`);
  }
}
