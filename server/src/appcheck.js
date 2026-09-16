import { createRemoteJWKSet, jwtVerify } from "jose";

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
    } catch {
      return false;
    }
  };
}
