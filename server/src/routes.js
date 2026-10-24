import { createHash, timingSafeEqual } from "node:crypto";
import express, { Router } from "express";
import { failureOf } from "./failure.js";
import { exchangeCode, refreshToken } from "./oauth.js";
import { SESSION_TTL_MS } from "./sessions.js";

const CHALLENGE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const BROWSER_COOKIE = "zeolite_notion";
const INVALID_CLAIM = { error: "Unable to claim this connection." };
const PAGE_POLICY = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'";

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
  return sameValue(challengeFor(verifier), expectedChallenge);
}

function sameValue(left, right) {
  const actual = Buffer.from(left);
  const expected = Buffer.from(right);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

// PKCE proves who started the handshake, not who approved it, so the ready
// page and the session id and code on it belong to the starting browser only.
function fromStartingBrowser(request, session) {
  for (const part of (request.headers.cookie ?? "").split(";")) {
    const [name, ...value] = part.trim().split("=");
    if (name === BROWSER_COOKIE) {
      return sameValue(value.join("="), session.browser);
    }
  }
  return false;
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
  const parseBody = express.json();
  // A browser drops a Secure cookie set over plain http, which a local server is.
  const secureCookie = new URL(config.redirectUri).protocol === "https:";

  router.get("/start", limit("/notion/start", 10), (request, response) => {
    const { challenge } = request.query;
    if (typeof challenge !== "string" || !CHALLENGE_PATTERN.test(challenge)) {
      response.status(400).json({ error: "Invalid request." });
      return;
    }

    const session = sessions.create(challenge);
    if (!session) {
      response.status(503).json({ error: "Unable to start a connection right now." });
      return;
    }
    const authorizationUrl = new URL("https://api.notion.com/v1/oauth/authorize");
    authorizationUrl.searchParams.set("client_id", config.clientId);
    authorizationUrl.searchParams.set("response_type", "code");
    authorizationUrl.searchParams.set("owner", "user");
    authorizationUrl.searchParams.set("redirect_uri", config.redirectUri);
    authorizationUrl.searchParams.set("state", session.state);
    // Lax still rides along on Notion's top-level redirect back to the callback.
    response.cookie(BROWSER_COOKIE, session.browser, {
      httpOnly: true,
      secure: secureCookie,
      sameSite: "lax",
      path: "/notion",
      maxAge: SESSION_TTL_MS,
    });
    response.redirect(302, authorizationUrl.toString());
  });

  router.get("/callback", limit("/notion/callback", 30), async (request, response) => {
    response.set("Content-Security-Policy", PAGE_POLICY);
    const { code, state, error } = request.query;
    if (error !== undefined) {
      response
        .status(400)
        .type("html")
        .send(
          callbackFailure(
            "Connection cancelled. You can close this tab and try again from Zeolite.",
          ),
        );
      return;
    }

    const session = typeof state === "string" ? sessions.getByState(state) : undefined;
    const expired = () =>
      response
        .status(400)
        .type("html")
        .send(callbackFailure("This link expired. Try connecting again."));
    if (typeof code !== "string" || !session || !fromStartingBrowser(request, session)) {
      expired();
      return;
    }

    // A reload of the "ready" tab brings back a code Notion has already spent.
    if (session.status !== "pending") {
      response.status(200).type("html").send(callbackSuccess(session, config.appScheme));
      return;
    }

    try {
      const tokenPayload = await exchangeCode(
        {
          code,
          redirectUri: config.redirectUri,
          clientId: config.clientId,
          clientSecret: config.clientSecret,
          timeoutMs: config.notionTimeoutMs,
        },
        fetchImpl,
      );
      // The session may have expired, or another callback finished, meanwhile.
      if (sessions.getById(session.id) !== session) {
        expired();
        return;
      }
      if (session.status === "pending") {
        session.tokenPayload = tokenPayload;
        session.status = "ready";
      }
      response.status(200).type("html").send(callbackSuccess(session, config.appScheme));
    } catch (error) {
      process.stderr.write(`Notion code exchange failed: ${failureOf(error)}\n`);
      // A duplicate callback fails on the code the first one already spent.
      if (session.status === "ready" && sessions.getById(session.id) === session) {
        response.status(200).type("html").send(callbackSuccess(session, config.appScheme));
        return;
      }
      response
        .status(502)
        .type("html")
        .send(callbackFailure("Unable to complete the connection. Try again."));
    }
  });

  router.post("/claim", limit("/notion/claim", 20), parseBody, (request, response) => {
    const body = request.body ?? {};
    const session =
      typeof body.session === "string"
        ? sessions.getById(body.session)
        : sessions.getByPairingCode(body.code);

    if (
      !session ||
      session.status !== "ready" ||
      !verifierMatches(body.verifier, session.challenge)
    ) {
      response.status(400).json(INVALID_CLAIM);
      return;
    }

    const tokenPayload = session.tokenPayload;
    // Deletion before serialization makes replay fail even if the response is interrupted.
    sessions.delete(session.id);
    response.status(200).json(tokenPayload);
  });

  router.post("/refresh", limit("/notion/refresh", 10), parseBody, async (request, response) => {
    const value = request.body?.refresh_token;
    if (typeof value !== "string" || value.trim().length === 0) {
      response.status(400).json({ error: "Invalid request." });
      return;
    }

    try {
      const tokenPayload = await refreshToken(
        {
          refreshToken: value,
          clientId: config.clientId,
          clientSecret: config.clientSecret,
          timeoutMs: config.notionTimeoutMs,
        },
        fetchImpl,
      );
      response.status(200).json(tokenPayload);
    } catch (error) {
      process.stderr.write(`Notion token refresh failed: ${failureOf(error)}\n`);
      response.status(502).json({ error: "Unable to refresh the connection." });
    }
  });

  return router;
}
