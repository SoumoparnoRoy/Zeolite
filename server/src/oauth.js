const TOKEN_URL = "https://api.notion.com/v1/oauth/token";

// A token exchange answers in well under a second, so anything this slow has
// stalled, and the person is watching a browser tab while it does.
export const NOTION_TIMEOUT_MS = 15_000;

function authorizationHeader(clientId, clientSecret) {
  return `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`;
}

async function requestToken(body, clientId, clientSecret, fetchImpl, timeoutMs) {
  const response = await fetchImpl(TOKEN_URL, {
    method: "POST",
    signal: AbortSignal.timeout(timeoutMs),
    headers: {
      Authorization: authorizationHeader(clientId, clientSecret),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  // Upstream response details stay server-side so provider errors cannot leak data.
  // The status is logged; it alone tells a revoked refresh token from an outage.
  if (!response.ok) {
    throw new Error(`Notion OAuth request failed (${response.status})`);
  }
  // A parse error quotes the body, which here could hold a token.
  const payload = await response.json().catch(() => {
    throw new Error(`Notion sent a reply that is not JSON (${response.status})`);
  });
  if (typeof payload?.access_token !== "string") {
    throw new Error("Notion sent no access token");
  }
  return payload;
}

export function exchangeCode(
  { code, redirectUri, clientId, clientSecret, timeoutMs = NOTION_TIMEOUT_MS },
  fetchImpl = globalThis.fetch,
) {
  return requestToken(
    { grant_type: "authorization_code", code, redirect_uri: redirectUri },
    clientId,
    clientSecret,
    fetchImpl,
    timeoutMs,
  );
}

export function refreshToken(
  { refreshToken: value, clientId, clientSecret, timeoutMs = NOTION_TIMEOUT_MS },
  fetchImpl = globalThis.fetch,
) {
  return requestToken(
    { grant_type: "refresh_token", refresh_token: value },
    clientId,
    clientSecret,
    fetchImpl,
    timeoutMs,
  );
}
