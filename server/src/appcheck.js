import { createRemoteJWKSet, jwtVerify } from "jose";
import { failureOf } from "./failure.js";

const JWKS_URL = "https://firebaseappcheck.googleapis.com/v1/jwks";
const ISSUER = "https://firebaseappcheck.googleapis.com/";

// jose caches the key set and refetches only on an unknown key id, so a flood
// of forged tokens does not turn into a flood of requests to Google.
const firebaseKeys = createRemoteJWKSet(new URL(JWKS_URL));

export function createAppCheckVerifier({ projectNumber, keys = firebaseKeys }) {
  return async function verify(token) {
    if (typeof token !== "string" || token.length === 0) {
      return false;
    }
    try {
      await jwtVerify(token, keys, {
        algorithms: ["RS256"],
        typ: "JWT",
        issuer: `${ISSUER}${projectNumber}`,
        audience: `projects/${projectNumber}`,
      });
      return true;
    } catch (error) {
      if (!isCallersFault(error)) {
        process.stderr.write(`App Check not verified: ${failureOf(error)}\n`);
      }
      return false;
    }
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
