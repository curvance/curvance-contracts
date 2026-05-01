const { appendFileSync, writeSync } = require("fs");

const DEFAULT_ATTEMPTS = 3;
const DEFAULT_TIMEOUT_MS = 15000;
const DEFAULT_RETRY_DELAY_MS = 500;

function writeFfiResult(value) {
    writeSync(1, String(value));
    process.exitCode = 0;
}

function failFfi(code, message, logPath) {
    const text = String(message || `Exited with code ${code}`);
    process.stderr.write(text);
    if (logPath) {
        appendFileSync(
            logPath,
            `***Exited (${code}) with message:***\n ${text}\n`
        );
    }
    process.exit(code);
}

function logFfi(logPath, message, data = null) {
    if (!logPath) return;
    if (data) {
        appendFileSync(logPath, `${message}:\n ${data}\n\n`);
    } else {
        appendFileSync(logPath, `${message}\n\n`);
    }
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function isRetryableStatus(status) {
    return status === 408 || status === 409 || status === 425 ||
        status === 429 || status >= 500;
}

async function fetchWithRetry(url, options = {}, config = {}) {
    const attempts = config.attempts || DEFAULT_ATTEMPTS;
    const timeoutMs = config.timeoutMs || DEFAULT_TIMEOUT_MS;
    const retryDelayMs = config.retryDelayMs || DEFAULT_RETRY_DELAY_MS;

    let lastError;
    for (let i = 0; i < attempts; ++i) {
        try {
            const response = await fetch(url, {
                ...options,
                signal: AbortSignal.timeout(timeoutMs),
            });

            if (
                response.ok ||
                !isRetryableStatus(response.status) ||
                i + 1 === attempts
            ) {
                return response;
            }

            await response.text();
            lastError = new Error(
                `Retryable HTTP ${response.status} ${response.statusText}`
            );
        } catch (e) {
            lastError = e;
            if (i + 1 === attempts) break;
        }

        await sleep(retryDelayMs * (i + 1));
    }

    throw lastError;
}

async function readJsonResponse(response, label) {
    const text = await response.text();
    let body;
    try {
        body = text ? JSON.parse(text) : {};
    } catch (e) {
        throw new Error(
            `${label} returned non-JSON body: ${text.slice(0, 500)}`
        );
    }

    if (!response.ok) {
        const requestId =
            body.requestId ||
            body.requestID ||
            (body.data && (body.data.requestId || body.data.requestID));
        throw new Error(
            `${label}: ${response.status} ${response.statusText}` +
                (requestId ? ` (requestId=${requestId})` : "")
        );
    }

    return body;
}

async function getJsonWithRetry(url, headers = {}, config = {}) {
    const response = await fetchWithRetry(
        url,
        {
            method: "GET",
            headers,
        },
        config
    );
    return readJsonResponse(response, config.label || "GET request");
}

async function postJsonWithRetry(url, body, headers = {}, config = {}) {
    const response = await fetchWithRetry(
        url,
        {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                ...headers,
            },
            body: JSON.stringify(body),
        },
        config
    );
    return readJsonResponse(response, config.label || "POST request");
}

module.exports = {
    failFfi,
    fetchWithRetry,
    getJsonWithRetry,
    logFfi,
    postJsonWithRetry,
    sleep,
    writeFfiResult,
};
