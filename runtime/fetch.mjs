function createAbortError() {
  return new DOMException("The operation was aborted.", "AbortError");
}

function normalizeHeaders(headers = {}) {
  if (!headers) {
    return {};
  }

  if (headers instanceof Headers) {
    return Object.fromEntries(headers.entries());
  }

  if (Array.isArray(headers)) {
    return Object.fromEntries(headers);
  }

  return Object.fromEntries(
    Object.entries(headers).map(([key, value]) => [key, String(value)])
  );
}

function encodeBody(body) {
  if (body == null) {
    return { body: null, bodyEncoding: "text" };
  }

  if (typeof body === "string") {
    return { body, bodyEncoding: "text" };
  }

  if (body instanceof ArrayBuffer) {
    return {
      body: Buffer.from(body).toString("base64"),
      bodyEncoding: "base64",
    };
  }

  if (ArrayBuffer.isView(body)) {
    return {
      body: Buffer.from(body.buffer, body.byteOffset, body.byteLength).toString("base64"),
      bodyEncoding: "base64",
    };
  }

  throw new TypeError("Unsupported body type");
}

function decodeBody(body, bodyEncoding = "text") {
  if (body == null) {
    return null;
  }

  if (bodyEncoding === "base64") {
    return Buffer.from(body, "base64");
  }

  return body;
}

function resolveUrl(input) {
  if (typeof input === "string") {
    return input;
  }

  if (input instanceof URL) {
    return input.toString();
  }

  if (typeof Request !== "undefined" && input instanceof Request) {
    return input.url;
  }

  return String(input);
}

async function resolveRequestBody(input, init = {}) {
  if (Object.prototype.hasOwnProperty.call(init, "body")) {
    return init.body;
  }

  if (typeof Request !== "undefined" && input instanceof Request) {
    if (input.body == null) {
      return null;
    }

    return input.clone().arrayBuffer();
  }

  return null;
}

export function createRuntimeFetch({ callRpc, createRequestId }) {
  return async function runtimeFetch(input, init = {}) {
    const method = init.method ?? (typeof Request !== "undefined" && input instanceof Request ? input.method : "GET");
    const headers = normalizeHeaders(
      init.headers ?? (typeof Request !== "undefined" && input instanceof Request ? input.headers : {})
    );
    const requestBody = await resolveRequestBody(input, init);
    const { body, bodyEncoding } = encodeBody(requestBody);
    const requestId = createRequestId();
    const signal = init.signal;

    let abortListener = null;
    if (signal?.aborted) {
      throw createAbortError();
    }

    const rpcPromise = callRpc("network.fetch", {
      requestId,
      url: resolveUrl(input),
      method,
      headers,
      body,
      bodyEncoding,
    });

    const abortPromise = signal
      ? new Promise((_, reject) => {
          abortListener = () => {
            Promise.resolve(callRpc("request.cancel", { requestId })).catch(() => {});
            reject(createAbortError());
          };
          signal.addEventListener("abort", abortListener, { once: true });
        })
      : null;

    try {
      const result = await (abortPromise ? Promise.race([rpcPromise, abortPromise]) : rpcPromise);
      return new Response(decodeBody(result?.body ?? null, result?.bodyEncoding), {
        status: result?.status ?? 200,
        statusText: result?.statusText ?? "",
        headers: result?.headers ?? {},
      });
    } finally {
      if (abortListener) {
        signal?.removeEventListener("abort", abortListener);
      }
    }
  };
}
