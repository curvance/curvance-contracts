const { appendFileSync } = require("fs");
const {
  DataPackage,
  NumericDataPoint,
  RedstonePayload,
} = require("./node_modules/@redstone-finance/protocol/dist/src/index");

const args = process.argv.slice(2);

const exit = (code, message) => {
  process.stderr.write(message);
  appendFileSync("./getRedstonePayload.log.txt", message);
  process.exit(code);
};

if (args.length === 0) {
  exit(1, "You have to provide at least on dataFeed");
}

const dataFeeds = args[0].split(",");

if (dataFeeds.length === 0) {
  exit(2, "You have to provide at least on dataFeed");
}

const timestampMilliseconds = Date.now();

const PRIVATE_KEY_1 =
  "0x56938289786ae24fdb687a2a740e755d6ed7e72a1f82f8f9c3ed6eac5b38ba23";
const PRIVATE_KEY_2 =
  "0x4022f8e215d01e76d90987d7f56a09513fe76f97add10db250215bdbfab3e9c1";
// const PRIVATE_KEY_3 =
//   "0x00b2ff109fc6421974dff44f7e2f95a0ebbba51acb43b6975b77615c6cba12b2";
// const PRIVATE_KEY_4 =
//   "0x7058697b9c2cd9dc583f9c44577ba4867e4b0c3fa5924a34db983c7b031266b4";

const dataPoints = dataFeeds.map(arg => {
  const [dataFeedId, value, decimals] = arg.split(":");

  if (!dataFeedId || !value || !decimals) {
    exit(
      3,
      "Input should have format: dataFeedId:value:decimals (example: BTC:120:8)",
    );
  }

  return new NumericDataPoint({
    dataFeedId,
    value: parseInt(value),
    decimals: parseInt(decimals),
  });
});

// Prepare unsigned data package
const dataPackage = new DataPackage(dataPoints, timestampMilliseconds);

// Prepare signed data packages
const signedDataPackages = [dataPackage.sign(PRIVATE_KEY_1), dataPackage.sign(PRIVATE_KEY_2)];

const payload = RedstonePayload.prepare(signedDataPackages, "");

process.stdout.write("0x" + payload);
process.exit(0);
