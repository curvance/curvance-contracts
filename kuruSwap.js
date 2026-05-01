const api = process.env.KURU_API_BASE || "https://ws.kuru.io/api";
const {
    postJsonWithRetry,
    sleep,
    writeFfiResult,
} = require("./ffiHelpers");

main().catch(err => {
    console.error(err);
    process.exit(1);
});

async function main() {
    const args = process.argv.slice(2);
    if (args.length < 5) {
        throw new Error("You have to provide the following arguments (in order): wallet, tokenIn, tokenOut, amount, _ref [mode]\n");
    }

    const wallet = args[0];
    const tokenIn = args[1];
    const tokenOut = args[2];
    const amount = args[3];
    const referrerAddressArg = args[4];
    const mode = args[5] || "calldata"; // modes: 'calldata' | 'amountOut'

    const response = await quote(wallet, tokenIn, tokenOut, amount, referrerAddressArg);
    // Wait 1 second to avoid rate limiting if the contract is hitting this FFI call multiple times.
    await sleep(1000);

    const calldata = response && response.transaction && response.transaction.calldata;
    if (mode === "amountOut") {
        const minOut = response && (response.minOut ?? response.output);
        if (minOut === undefined || minOut === null) {
            throw new Error("Failed to get minOut/output from response");
        }
        // Force to BigInt
        const normalizedBigInt = typeof minOut === "bigint" ? minOut : BigInt(String(minOut).trim());
        const outHex = "0x" + normalizedBigInt.toString(16).padStart(64, "0"); // 32-byte hex
        writeFfiResult(outHex);
    } else {
        if (!calldata || typeof calldata !== "string") {
            throw new Error("Failed to get calldata from response");
        }
        writeFfiResult(calldata);
    }
}

async function getJwt(wallet) {
    const data = await postJsonWithRetry(
        `${api}/generate-token`,
        { user_address: wallet },
        {},
        { label: "Kuru JWT" }
    );
    return data.token;
}

async function quote(wallet, tokenIn, tokenOut, amount, _referrerAddress) {
    const jwt = await getJwt(wallet);
    const payload = {
        userAddress: wallet,
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amount: amount,
        autoSlippage: true,
        referrerAddress: _referrerAddress,
        referrerFeeBps: 10,
    };

    return postJsonWithRetry(
        `${api}/quote`,
        payload,
        { "Authorization": `Bearer ${jwt}` },
        { label: "Kuru quote" }
    );
}
// Test: node kuruSwap.js 0xe2165a834F93C39483123Ac31533780b9c679ed4 0x3a98250F98Dd388C211206983453837C8365BDc1 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea 5000000000000000000
