import { createHash, timingSafeEqual } from "node:crypto";
import { Router } from "express";
import { exchangeCode, refreshToken } from "./oauth.js";

const CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const INVALID_CLAIM = { error: "Unable to claim this connection." };

function challengeFor(verifier) {
  return createHash("sha256").update(verifier).digest("base64url");
}

// The token is released only against the verifier, never against the session
// id alone. Any Android app may register the same custom URL scheme, so the
// redirect carrying that id has to be assumed intercepted; the verifier never
// leaves the device that started the handshake.
function verifierMatches(verifier, expectedChallenge) {
  if (typeof verifier !== "string") {
    return false;
  }
  const actual = Buffer.from(challengeFor(verifier));
  const expected = Buffer.from(expectedChallenge);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function callbackFailure(message) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Zeolite connection</title></head><body><main><h1>${message}</h1></main></body></html>`;
}

function callbackSuccess(session, appScheme) {
  const deepLink = `${appScheme}://notion?session=${encodeURIComponent(session.id)}`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="0;url=${deepLink}"><title>Return to Zeolite</title><style>body{font-family:system-ui,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#f7f7f5;color:#202020}main{text-align:center;padding:2rem}.code{font-size:clamp(2rem,10vw,4rem);font-weight:700;letter-spacing:.18em;margin:1rem 0}</style></head><body><main><h1>Connection ready</h1><div class="code">${session.pairingCode}</div><p>Type this code into Zeolite if the app did not open.</p><a href="${deepLink}">Open Zeolite</a></main></body></html>`;
}

export function createNotionRouter({ config, sessions, limit, fetchImpl }) {
  const router = Router();

  router.get("/start", limit("/notion/start", 10), (request, response) => {
    const { challenge } = request.query;
    if (typeof challenge !== "string" || !CHALLENGE_PATTERN.test(challenge)) {
      response.status(400).json({ error: "Invalid request." });
      return;
    }

    const session = sessions.create(challenge);
    const authorizationUrl = new URL("https://api.notion.com/v1/oauth/authorize");
    authorizationUrl.searchParams.set("client_id", config.clientId);
    authorizationUrl.searchParams.set("response_type", "code");
    authorizationUrl.searchParams.set("owner", "user");
    authorizationUrl.searchParams.set("redirect_uri", config.redirectUri);
    authorizationUrl.searchParams.set("state", session.state);
    response.redirect(302, authorizationUrl.toString());
  });

  router.get("/callback", limit("/notion/callback", 30), async (request, response) => {
    const { code, state, error } = request.query;
    const session = typeof state === "string" ? sessions.getByState(state) : undefined;
    if (error !== undefined || typeof code !== "string" || !session) {
      response.status(400).type("html").send(callbackFailure("This link expired. Try connecting again."));
      return;
    }

    try {
      const tokenPayload = await exchangeCode(
        {
          code,
          redirectUri: config.redirectUri,
          clientId: config.clientId,
          clientSecret: config.clientSecret,
        },
        fetchImpl,
      );
      session.tokenPayload = tokenPayload;
      session.status = "ready";
      response.status(200).type("html").send(callbackSuccess(session, config.appScheme));
    } catch {
      response.status(502).type("html").send(callbackFailure("Unable to complete the connection. Try again."));
    }
  });

  router.post("/claim", limit("/notion/claim", 20), (request, response) => {
    const body = request.body ?? {};
    const session = typeof body.session === "string"
      ? sessions.getById(body.session)
      : sessions.getByPairingCode(body.code);

    if (!session || session.status !== "ready" || !verifierMatches(body.verifier, session.challenge)) {
      response.status(400).json(INVALID_CLAIM);
      return;
    }

    const tokenPayload = session.tokenPayload;
    // Deletion before serialization makes replay fail even if the response is interrupted.
    sessions.delete(session.id);
    response.status(200).json(tokenPayload);
  });

  router.post("/refresh", limit("/notion/refresh", 10), async (request, response) => {
    const value = request.body?.refresh_token;
    if (typeof value !== "string" || value.length === 0) {
      response.status(400).json({ error: "Invalid request." });
      return;
    }

    try {
      const tokenPayload = await refreshToken(
        { refreshToken: value, clientId: config.clientId, clientSecret: config.clientSecret },
        fetchImpl,
      );
      response.status(200).json(tokenPayload);
    } catch {
      response.status(502).json({ error: "Unable to refresh the connection." });
    }
  });

  return router;
}
