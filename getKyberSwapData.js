const { appendFileSync } = require("fs");
const { performance } = require("perf_hooks");

main().catch(err => {
    console.error(err);
    exit(1, "Failed: " + err.message + "\n\n" + err.stack);
});

async function main() {
    const startTime = performance.now();
    const {
        chainId,
        fromToken,
        toToken,
        amount,
        swapperAddress,
        slippageBps,
        feeReceiver,
        feeBps,
        mode,
        chargeFeeBy,
        isInBps,
    } = loadArgs();

    const chain = mapChainIdToKyberChain(chainId);

    const baseUrl = "https://aggregator-api.kyberswap.com";

    // 1. Get route
    const routesUrl = `${baseUrl}/${chain}/api/v1/routes`;
    const routeParams = new URLSearchParams({
        tokenIn: fromToken,
        tokenOut: toToken,
        amountIn: amount,
        gasInclude: "true",
        onlySinglePath: "true",
    });

    // Only include fee params if feeReceiver is provided (allows no-fee calldata).
    if (feeReceiver) {
        routeParams.set("chargeFeeBy", chargeFeeBy);
        routeParams.set("feeReceiver", feeReceiver);
        routeParams.set("isInBps", isInBps);
        routeParams.set("feeAmount", feeBps);
    }

    let response = await fetch(
        `${routesUrl}?${routeParams.toString()}`,
        {
            method: "GET",
            headers: {
                "Accept": "application/json",
                "X-Client-Id": "CurvanceProtocol"
            }
        }
    );

    if (!response.ok) {
        const body = await response.json();
        const requestId =
            body.requestId ||
            body.requestID ||
            (body.data && (body.data.requestId || body.data.requestID));
        exit(
            3,
            `Error in Kyber routes: ${response.status} ${response.statusText} (requestId=${requestId})`
        );
    }

    const routesJson = await response.json();
    const routeData = routesJson && routesJson.data;
    if (!routeData || !routeData.routeSummary) {
        exit(3, "Kyber routes response missing data.routeSummary");
    }

    const routeSummary = routeData.routeSummary;

    // Return only the output amount
    if (mode === "amountOut") {
        const rawOut =
            (routeSummary && (routeSummary.amountOut || routeSummary.AmountOut)) ??
            null;

        if (rawOut === null || rawOut === undefined) {
            exit(3, "Kyber routes response missing amountOut/AmountOut");
        }

        const normalizedBigInt =
            typeof rawOut === "bigint" ? rawOut : BigInt(String(rawOut).trim());

        const outHex =
            "0x" + normalizedBigInt.toString(16).padStart(64, "0");

        process.stdout.write(outHex);
        process.exit(0);
    }

    // 2. Build transaction calldata
    const buildUrl = `${baseUrl}/${chain}/api/v1/route/build`;

    const buildBody = {
        routeSummary,
        // Address providing the funds (our zapper / positionManager)
        sender: swapperAddress,
        // Address receiving dstToken (our zapper / positionManager)
        recipient: swapperAddress,
        slippageTolerance: Number(slippageBps),
        // default deadline (20 minutes from now)
        deadline: Math.floor(Date.now() / 1000) + 20 * 60,
    };

    response = await fetch(
        buildUrl,
        {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Client-Id": "CurvanceProtocol"
            },
            body: JSON.stringify(buildBody)
        }
    );

    if (!response.ok) {
        const body = await response.json();
        const requestId =
            body.requestId ||
            body.requestID ||
            (body.data && (body.data.requestId || body.data.requestID));
        exit(
            3,
            `Error in Kyber build: ${response.status} ${response.statusText} (requestId=${requestId})`
        );
    }

    const buildJson = await response.json();
    const buildData = buildJson && buildJson.data;
    if (!buildData) {
        exit(3, "Kyber build response missing data field");
    }

    const calldata =
        buildData.data ||
        buildData.txData ||
        buildData.calldata ||
        buildData.inputData;

    if (!calldata || typeof calldata !== "string") {
        exit(3, "Failed to extract calldata from Kyber build response");
    }

    process.stdout.write(calldata);

    process.exit(0);
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
        exit(2, `Unsupported chainId for Kyber: ${chainId}`);
    }
    return chain;
}

function loadArgs() {
    const args = process.argv.slice(2);

    const chainId = args[0];
    const fromToken = args[1];
    const toToken = args[2];
    const amount = args[3];
    const swapperAddress = args[4];
    const slippageBps = args[5];
    const feeReceiver = args[6] || "";
    const feeBps = args[7] || "0";
    const mode = args[8] || "calldata";
    const chargeFeeBy = args[9] || "currency_in";
    const isInBps = args[10] || "true";

    return {
        chainId,
        fromToken,
        toToken,
        amount,
        swapperAddress,
        slippageBps,
        feeReceiver,
        feeBps,
        mode,
        chargeFeeBy,
        isInBps,
    };
}

function exit(code, message) {
    process.stderr.write(String(message));
    appendFileSync(
        "./KyberSwap.log.txt",
        `***Exited (${code}) with message:***\n ${message}\n`
    );
    process.exit(code);
}


