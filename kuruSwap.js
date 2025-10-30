const api = "https://ws.staging.kuru.io/api";

main().catch(err => {
    console.error(err);
    process.exit(1);
});

async function main() {
    const args = process.argv.slice(2);
    if (args.length < 4) {
        throw new Error("You have to provide the following arguments (in order): wallet, tokenIn, tokenOut, amount, slippageTolerance (optional)\n");
    }

    const wallet = args[0];
    const tokenIn = args[1];
    const tokenOut = args[2];
    const amount = args[3];
    const slippageTolerance = args[4] ?? null;

    console.log(wallet, tokenIn, tokenOut, amount, slippageTolerance);
    const response = await quote(wallet, tokenIn, tokenOut, amount, slippageTolerance);
    // Wait 1 second to avoid rate limiting if the contract is hitting this FFI call multiple times.
    await new Promise(resolve => setTimeout(resolve, 1000));

    console.log(response);
    return response;
}

async function getJwt(wallet) {
    const resp = await fetch(`${api}/generate-token`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            user_address: wallet,
        }),
        keepalive: true
    });

    if(!resp.ok) {
        throw new Error(`Failed to fetch JWT: ${resp.status} ${resp.statusText}`);
    }

    const data = await resp.json();

    return data.token;
}

async function quote(wallet, tokenIn, tokenOut, amount) {
    const jwt = await getJwt(wallet);
    const payload = {
        userAddress: wallet,
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amount: amount,
        autoSlippage: true,
        slippageTolerance: 50,
        referrerAddress: "0xBAaf22d2Bc4Ac001BBDDA7De73d3ae1bA71dfDDB",
        referrerFeeBps: 10,
    };

    const resp = await fetch(`${api}/quote`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            // "X-API-Key": "ad5944c136775d648c2530a4950188c3",
            "Authorization": `Bearer ${jwt}`
        },
        body: JSON.stringify(payload),
    });

    console.log(JSON.stringify(payload));

    if(!resp.ok) {
        console.log(resp);
        throw new Error(`Failed to fetch quote: ${resp.status} ${resp.statusText}`);
    }

    const data = await resp.json();

    return data;
}
// Test: node kuruSwap.js 0xe2165a834F93C39483123Ac31533780b9c679ed4 0x3a98250F98Dd388C211206983453837C8365BDc1 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea 5000000000000000000