const { appendFileSync } = require("fs");
const { AbiCoder, keccak256, toUtf8Bytes } = require("ethers");

const KYBER_ROUTER = "0x6131B5fae19EA4f9D964eAc0408E4408b66337b5";
const KURU_ROUTER = "0xb3e6778480b2E488385E8205eA05E20060B813cb";
const abiCoder = AbiCoder.defaultAbiCoder();


// 1. Try to get calldata from Kyber
// 2. If successful, check to see if the calldata is valid by checking the form and function selector.
// 2a. If the calldata is valid, return the calldata and the aggregator code.
// 3. If not successful, try to get calldata from Kuru
// 4. If successful, check to see if the calldata is valid by checking the form and function selector.
// 4a. If the calldata is valid, return the calldata and the aggregator code.
// 5. If not successful, throw an error.

// 0 = Kyber used
// 1 = Kuru used
// 2 = Both Kyber and Kuru failed

// Kyber MetaAggregationRouterV2.swap(SwapExecutionParams)
const KYBER_SELECTORS = [
    keccak256(
        toUtf8Bytes(
            "swap((address,address,bytes,(address,address,address[],uint256[],address[],uint256[],address,uint256,uint256,uint256,bytes),bytes))"
        )
    ).slice(0, 10).toLowerCase(),
];

// Kuru IKuruFlowRouter.executeSwap(SwapIntent,FeeCollection,bytes)
const KURU_SELECTORS = [
    keccak256(
        toUtf8Bytes(
            "executeSwap((address,uint256,address,uint256),(address,uint256,address,uint256,bool),bytes)"
        )
    ).slice(0, 10).toLowerCase(),
];

main().catch((err) => {
    console.error(err);
    exit(1, "Failed: " + err.message + "\n\n" + (err.stack || ""));
});

async function main() {
    const {
        chainId,
        wallet,
        tokenIn,
        tokenOut,
        amountIn,
        daoAddress,
        slippageBps,
    } = loadArgs();

    let selectedCalldata = null;
    let aggregatorCode = 0; // 1 = Kyber, 2 = Kuru

    // 1. Try Kyber first: get calldata from Kyber API and validate selector.
    try {
        const kyberCalldata = await getKyberCalldata(
            chainId,
            tokenIn,
            tokenOut,
            amountIn,
            wallet,
            slippageBps
        );

        if (
            typeof kyberCalldata !== "string" ||
            !kyberCalldata.startsWith("0x") ||
            kyberCalldata.length < 10
        ) {
            throw new Error("Kyber calldata is malformed");
        }

        const selector = kyberCalldata.slice(0, 10).toLowerCase();
        if (!KYBER_SELECTORS.includes(selector)) {
            throw new Error(
                `Kyber calldata has unexpected function selector: ${selector}`
            );
        }

        selectedCalldata = kyberCalldata;
        aggregatorCode = 1;
    } catch (e) {
        console.error("Kyber path failed, trying Kuru:", e.message);
    }

    // 2. If Kyber failed, fallback to Kuru: get calldata from Kuru API.
    if (!selectedCalldata) {
        try {
            const kuruCalldata = await getKuruCalldata(
                wallet,
                tokenIn,
                tokenOut,
                amountIn,
                daoAddress
            );

            // Basic shape check
            if (
                typeof kuruCalldata !== "string" ||
                !kuruCalldata.startsWith("0x") ||
                kuruCalldata.length < 10
            ) {
                throw new Error("Kuru calldata is malformed");
            }

            const selector = kuruCalldata.slice(0, 10).toLowerCase();
            if (!KURU_SELECTORS.includes(selector)) {
                throw new Error(
                    `Kuru calldata has unexpected function selector: ${selector}`
                );
            }

            selectedCalldata = kuruCalldata;
            aggregatorCode = 2;
        } catch (e) {
            exit(2, "Both Kyber and Kuru paths failed: " + e.message);
        }
    }

    // Return calldata and aggregator code to know which aggregator was used in our tests
    const encoded = abiCoder.encode(
        ["bytes", "uint8"],
        [selectedCalldata, aggregatorCode]
    );

    process.stdout.write(encoded);
    process.exit(0);
}

async function getKyberCalldata(
    chainId,
    tokenIn,
    tokenOut,
    amount,
    swapperAddress,
    slippageBps
) {
    const chain = mapChainIdToKyberChain(chainId);
    const baseUrl = "https://aggregator-api.kyberswap.com";

    // 1. Get route
    const routesUrl = `${baseUrl}/${chain}/api/v1/routes`;
    const routeParams = new URLSearchParams({
        tokenIn,
        tokenOut,
        amountIn: amount,
        gasInclude: "true",
        onlySinglePath: "true",
    });

    let response = await fetch(`${routesUrl}?${routeParams.toString()}`, {
        method: "GET",
        headers: {
            Accept: "application/json",
            "X-Client-Id": "CurvanceProtocol",
        },
    });

    if (!response.ok) {
        const body = await response.json();
        const requestId =
            body.requestId ||
            body.requestID ||
            (body.data && (body.data.requestId || body.data.requestID));
        throw new Error(
            `Error in Kyber routes: ${response.status} ${response.statusText} (requestId=${requestId})`
        );
    }

    const routesJson = await response.json();
    const routeData = routesJson && routesJson.data;
    if (!routeData || !routeData.routeSummary) {
        throw new Error("Kyber routes response missing data.routeSummary");
    }

    const routeSummary = routeData.routeSummary;

    // 2. Build transaction calldata
    const buildUrl = `${baseUrl}/${chain}/api/v1/route/build`;

    const buildBody = {
        routeSummary,
        sender: swapperAddress,
        recipient: swapperAddress,
        slippageTolerance: Number(slippageBps),
        deadline: Math.floor(Date.now() / 1000) + 60 * 60,
    };

    response = await fetch(buildUrl, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
            "X-Client-Id": "CurvanceProtocol",
        },
        body: JSON.stringify(buildBody),
    });

    if (!response.ok) {
        const body = await response.json();
        const requestId =
            body.requestId ||
            body.requestID ||
            (body.data && (body.data.requestId || body.data.requestID));
        throw new Error(
            `Error in Kyber build: ${response.status} ${response.statusText} (requestId=${requestId})`
        );
    }

    const buildJson = await response.json();
    const buildData = buildJson && buildJson.data;
    if (!buildData) {
        throw new Error("Kyber build response missing data field");
    }

    const calldata =
        buildData.data ||
        buildData.txData ||
        buildData.calldata ||
        buildData.inputData;

    if (!calldata || typeof calldata !== "string") {
        throw new Error("Failed to extract calldata from Kyber build response");
    }

    return calldata;
}

async function getKuruCalldata(wallet, tokenIn, tokenOut, amount, daoAddress) {
    const api = process.env.KURU_API_BASE || "https://ws.kuru.io/api";

    async function getJwt(addr) {
        const resp = await fetch(`${api}/generate-token`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
            },
            body: JSON.stringify({
                user_address: addr,
            }),
            keepalive: true,
        });

        if (!resp.ok) {
            throw new Error(`Failed to fetch JWT: ${resp.status} ${resp.statusText}`);
        }

        const data = await resp.json();
        return data.token;
    }

    async function quote(addr, tIn, tOut, amt, refAddr) {
        const jwt = await getJwt(addr);
        const payload = {
            userAddress: addr,
            tokenIn: tIn,
            tokenOut: tOut,
            amount: amt,
            autoSlippage: true,
            referrerAddress: refAddr,
            referrerFeeBps: 10,
        };

        const resp = await fetch(`${api}/quote`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${jwt}`,
            },
            body: JSON.stringify(payload),
        });

        if (!resp.ok) {
            throw new Error(`Failed to fetch Kuru quote: ${resp.status} ${resp.statusText}`);
        }

        const data = await resp.json();
        return data;
    }

    const response = await quote(wallet, tokenIn, tokenOut, amount, daoAddress);

    // Small delay to avoid rate limiting when tests hammer the API
    await new Promise((resolve) => setTimeout(resolve, 1000));

    const calldata =
        response &&
        response.transaction &&
        response.transaction.calldata;

    if (!calldata || typeof calldata !== "string") {
        throw new Error("Failed to get calldata from Kuru response");
    }

    return calldata;
}

function mapChainIdToKyberChain(chainId) {
    const mapping = {
        "1": "ethereum",
        "137": "polygon",
        "42161": "arbitrum",
        "10": "optimism",
        "56": "bsc",
        "43114": "avalanche",
        "324": "zksync-era",
        "143": "monad",
    };

    const key = String(chainId);
    const chain = mapping[key];
    if (!chain) {
        throw new Error(`Unsupported chainId for Kyber: ${chainId}`);
    }
    return chain;
}

function loadArgs() {
    const args = process.argv.slice(2);

    if (args.length < 7) {
        exit(
            1,
            "Expected arguments: chainId, wallet, tokenIn, tokenOut, tokenInAmount, daoAddress, slippageBps"
        );
    }

    const chainId = args[0];
    const wallet = args[1];
    const tokenIn = args[2];
    const tokenOut = args[3];
    const amountIn = args[4];
    const daoAddress = args[5];
    const slippageBps = args[6];

    return {
        chainId,
        wallet,
        tokenIn,
        tokenOut,
        amountIn,
        daoAddress,
        slippageBps,
    };
}

function exit(code, message) {
    if (message) {
        process.stderr.write(String(message));
        appendFileSync(
            "./KyberSwap.log.txt",
            `***Exited (${code}) with message:***\n ${message}\n`
        );
    }
    process.exit(code);
}


