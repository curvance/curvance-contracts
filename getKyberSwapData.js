const { performance } = require("perf_hooks");
const {
    failFfi,
    getJsonWithRetry,
    postJsonWithRetry,
    writeFfiResult,
} = require("./ffiHelpers");

const LOG_PATH = "./KyberSwap.log.txt";

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

    const routesJson = await getJsonWithRetry(
        `${routesUrl}?${routeParams.toString()}`,
        {
            "Accept": "application/json",
            "X-Client-Id": "CurvanceProtocol"
        },
        { label: "Kyber routes" }
    );
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

        writeFfiResult(outHex);
        return;
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

    const buildJson = await postJsonWithRetry(
        buildUrl,
        buildBody,
        {
            "Accept": "application/json",
            "X-Client-Id": "CurvanceProtocol"
        },
        { label: "Kyber build" }
    );
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

    writeFfiResult(calldata);
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
    failFfi(code, message, LOG_PATH);
}
