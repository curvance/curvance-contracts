// Doc Link: https://docs.odos.xyz/build/api-docs
const { appendFileSync } = require("fs");
const { performance } = require("perf_hooks");
const { ethers } = require("ethers");

main().catch(err => {
    console.error(err);
    exit(1, "Failed: " + err.message + "\n\n" + err.stack);
});

async function main() {
    const startTime = performance.now();
    const { chainId, fromToken, toToken, amount, swapperAddress, slippage } = loadArgs();

    const quoteUrl = 'https://api.odos.xyz/sor/quote/v2';
    const assembleUrl = 'https://api.odos.xyz/sor/assemble';
    const quoteRequestBody = {
        chainId,
        inputTokens: [
            {
                tokenAddress: fromToken,
                amount
            }
        ],
        outputTokens: [
            {
                tokenAddress: toToken,
                proportion: 1
            }
        ],
        userAddr: swapperAddress,
        slippageLimitPercent: slippage / 10,
        compact: false,
    };
    const assembleRequestBody = {
        userAddr: swapperAddress,
        pathId: "",
    };

    try {
        let response = await fetch(
            quoteUrl,
            {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(quoteRequestBody),
            });

        if (response.status === 200) {
            const quote = await response.json();
            assembleRequestBody.pathId = quote.pathId;
        } else {
            exit(3, `Error in Quote: ` + response.statusText);
        }

        response = await fetch(
            assembleUrl,
            {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(assembleRequestBody),
            });

        if (response.status === 200) {
            const assembledTransaction = await response.json();
            // log("Results", JSON.stringify(assembledTransaction, null, 2));

            const output = ethers.utils.defaultAbiCoder.encode(["uint", "bytes"],
                [assembledTransaction.outputTokens[0].amount, assembledTransaction.transaction.data]);
            process.stdout.write(output);
        } else {
            exit(3, `Error in Transaction Assembly: ` + response.statusText);
        }
    } catch (e) {
        console.error(e);
        log(3, e);
    }

    const endTime = performance.now();
    // log(`--- End, Ran in: ${endTime - startTime}ms ---`);


    process.exit(0);
}

function loadArgs() {
    const args = process.argv.slice(2);
    if (args.length != 6) {
        exit(2, "You have to provide the following arguments (in order): chainId, fromToken, toToken, amount, swapperAddress, slippage (0-50)");
    }

    const chainId = args[0];
    const fromToken = args[1];
    const toToken = args[2];
    const amount = args[3];
    const swapperAddress = args[4];
    const slippage = args[5];

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
    appendFileSync("./Odos.log.txt", `***Exited (${code}) with message:***\n ${message}\n`);
    process.exit(code);
};

function log(message, data = null) {
    console.log(message, data);
    if (data) {
        appendFileSync("./Odos.log.txt", `${message}:\n ${data}\n\n`);
    } else {
        appendFileSync("./Odos.log.txt", `${message}\n\n`);
    }
}
