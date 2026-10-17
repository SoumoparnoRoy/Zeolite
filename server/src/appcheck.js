import { createHash } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { failureOf } from "./failure.js";

const JWKS_URL = "https://firebaseappcheck.googleapis.com/v1/jwks";
const ISSUER = "https://firebaseappcheck.googleapis.com/";
const SWEEP_INTERVAL_MS = 60 * 1000;

// jose caches the key set and refetches only on an unknown key id, so a flood
// of forged tokens does not turn into a flood of requests to Google.
const firebaseKeys = createRemoteJWKSet(new URL(JWKS_URL));

export function createAppCheckVerifier({ projectNumber, keys = firebaseKeys, now = Date.now }) {
  // A token is good for one read. An ordinary one lives an hour, and replayed
  // from one address at the rate limit that was exactly the day's shared
  // budget; the app asks for a limited-use token per read instead. Keyed by a
  // hash of the whole token, so nothing here depends on which claims Firebase
  // puts in it and the map holds no credentials, and kept only until the token
  // would have expired anyway.
  const spent = new Map();
  const sweepTimer = setInterval(() => {
    const currentTime = now();
    for (const [key, expiresAt] of spent) {
      if (expiresAt <= currentTime) {
        spent.delete(key);
      }
    }
  }, SWEEP_INTERVAL_MS);
  sweepTimer.unref();

  return async function verify(token) {
    if (typeof token !== "string" || token.length === 0) {
      return false;
    }
    let payload;
    try {
      ({ payload } = await jwtVerify(token, keys, {
        algorithms: ["RS256"],
        typ: "JWT",
        issuer: `${ISSUER}${projectNumber}`,
        audience: `projects/${projectNumber}`,
      }));
    } catch (error) {
      if (!isCallersFault(error)) {
        process.stderr.write(`App Check not verified: ${failureOf(error)}\n`);
      }
      return false;
    }
    // Checked and recorded with no await between, so two requests carrying
    // the same token cannot both get through.
    const key = createHash("sha256").update(token).digest("base64url");
    if (spent.has(key)) {
      // An app build from before limited-use tokens, or someone replaying one.
      process.stderr.write("App Check token used twice\n");
      return false;
    }
    spent.set(key, payload.exp * 1000);
    return true;
  };
}

// Ours, not the caller's: no key set (a network error has no jose code), or a
// real token for another project, which is a wrong FIREBASE_PROJECT_NUMBER.
const OURS = new Set([
  "ERR_JWKS_TIMEOUT",
  "ERR_JWKS_INVALID",
  "ERR_JOSE_GENERIC",
  "ERR_JWT_CLAIM_VALIDATION_FAILED",
]);

function isCallersFault(error) {
  return typeof error?.code === "string" && error.code.startsWith("ERR_J") && !OURS.has(error.code);
}
