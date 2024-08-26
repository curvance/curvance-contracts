// Doc Link: https://portal.1inch.dev/documentation/apis/swap/classic-swap/swagger?method=get&path=%2Fv6.0%2F1%2Fswap
// Test success: node getOneInchSwapData.js 1 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 0x6b175474e89094c44da98b954eedeac495271d0f 10 0xe2165a834F93C39483123Ac31533780b9c679ed4 5
// Test fail: node getOneInchSwapData.js 1 0x6b175474e89094c44da98b954eedeac495271d0f 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 10 0xe2165a834F93C39483123Ac31533780b9c679ed4 5
const { appendFileSync } = require("fs");
const { performance } = require("perf_hooks");

// Pulled this API Key from their example docs -- so not sure how long it will stay active.
const API_KEY = "EHFRkJfBH4tEXkGJXkLMxYU9sqYVYyQB";

main().catch(err => {
  console.error(err);
  exit(1, "Failed: " + err.message + "\n\n" + err.stack);
});

async function main() {
  const startTime = performance.now();
  const { chainId, fromToken, toToken, amount, swapperAddress, slippage } = loadArgs();

  let url = new URL(`https://api.1inch.dev/swap/v6.0/${chainId}/swap`);
  let params = new URLSearchParams();
  params.append("src", fromToken);
  params.append("dst", toToken);
  params.append("amount", amount);
  params.append("from", swapperAddress);
  params.append("origin", swapperAddress);
  params.append("slippage", slippage);

  try {
    const oneInchUrl = url.toString() + '?' + params.toString();
    console.log(oneInchUrl);
    const call = await fetch(oneInchUrl, {
      headers: {
        "Authorization": `Bearer ${API_KEY}`,
      }
    });
    const results = await call.json();

    if ("error" in results) {
      exit(3, `Error (${results.error}): ` + results.description);
    }

    // Return value to contract
    log("Results", JSON.stringify(results, null, 2));
    process.stdout.write(results.tx.data);
  } catch (e) {
    console.error(e);
    log(3, e);
  }

  const endTime = performance.now();
  log(`--- End, Ran in: ${endTime - startTime}ms ---`);


  process.exit(0);
}

function loadArgs() {
  const args = process.argv.slice(2);
  log("Arguments", JSON.stringify(args));
  if (args.length != 6) {
    exit(2, "You have to provide the following arguments (in order): chainId, fromToken, toToken, amount, swapperAddress, slippage (0-50)");
  }

  const chainId = args[0];
  const fromToken = args[1];
  const toToken = args[2];
  const amount = args[3];
  const swapperAddress = args[4];
  const slippage = args[5];

  console.log(amount);

  if (!chainId || !Number.isInteger(parseInt(chainId))) {
    exit(2, "Arg 0: chainId is not a valid number");
  }

  if (!fromToken || fromToken.split("0x").length != 2) {
    exit(2, "Arg 1: fromToken is not a valid address");
  }

  if (!toToken || toToken.split("0x").length != 2) {
    exit(2, "Arg 2: toToken is not a valid address");
  }

  if (!amount || amount == "" && amount.split("0x").length == 1) {
    exit(2, "Arg 3: amount is not defined, or defined incorrectly");
  }

  if (!swapperAddress || swapperAddress.split("0x").length != 2) {
    exit(2, "Arg 4: swapperAddress is not a valid address");
  }

  if (!slippage || Number(slippage) < 0 || Number(slippage) > 50) {
    exit(2, "Arg 5: slippage must be defined between 0 and 50");
  }

  return { chainId, fromToken, toToken, amount, swapperAddress, slippage };
}

function exit(code, message) {
  process.stderr.write(message);
  appendFileSync("./OneInch.log.txt", `***Exited (${code}) with message:***\n ${message}\n`);
  process.exit(code);
};

function log(message, data = null) {
  console.log(message, data);
  if (data) {
    appendFileSync("./OneInch.log.txt", `${message}:\n ${data}\n\n`);
  } else {
    appendFileSync("./OneInch.log.txt", `${message}\n\n`);
  }
}
