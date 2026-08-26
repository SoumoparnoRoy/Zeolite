const TOKEN_URL = "https://api.notion.com/v1/oauth/token";

function authorizationHeader(clientId, clientSecret) {
  return `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString("base64")}`;
}

async function requestToken(body, clientId, clientSecret, fetchImpl) {
  const response = await fetchImpl(TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: authorizationHeader(clientId, clientSecret),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  // Upstream response details stay server-side so provider errors cannot leak data.
  if (!response.ok) {
    throw new Error("Notion OAuth request failed");
  }
  return response.json();
}

export function exchangeCode(
  { code, redirectUri, clientId, clientSecret },
  fetchImpl = globalThis.fetch,
) {
  return requestToken(
    { grant_type: "authorization_code", code, redirect_uri: redirectUri },
    clientId,
    clientSecret,
    fetchImpl,
  );
}

export function refreshToken(
  { refreshToken: value, clientId, clientSecret },
  fetchImpl = globalThis.fetch,
) {
  return requestToken(
    { grant_type: "refresh_token", refresh_token: value },
    clientId,
    clientSecret,
    fetchImpl,
  );
}
