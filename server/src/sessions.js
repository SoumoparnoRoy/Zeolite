import { randomBytes } from "node:crypto";

const SESSION_TTL_MS = 5 * 60 * 1000;
const SWEEP_INTERVAL_MS = 60 * 1000;
const PAIRING_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

function randomPairingCode() {
  let code = "";
  for (let index = 0; index < 8; index += 1) {
    code += PAIRING_ALPHABET[randomBytes(1)[0] % PAIRING_ALPHABET.length];
  }
  return code;
}

export function createSessionStore({ now = Date.now } = {}) {
  const sessions = new Map();

  function isExpired(session) {
    return now() - session.createdAt >= SESSION_TTL_MS;
  }

  function removeExpired() {
    for (const [id, session] of sessions) {
      if (isExpired(session)) {
        sessions.delete(id);
      }
    }
  }

  // Expiry is also enforced during lookup so timer scheduling cannot extend a session.
  const sweepTimer = setInterval(removeExpired, SWEEP_INTERVAL_MS);
  sweepTimer.unref();

  function create(challenge) {
    const session = {
      id: randomBytes(32).toString("base64url"),
      state: randomBytes(32).toString("base64url"),
      challenge,
      pairingCode: randomPairingCode(),
      createdAt: now(),
      status: "pending",
    };
    sessions.set(session.id, session);
    return session;
  }

  function find(predicate) {
    for (const [id, session] of sessions) {
      if (predicate(session)) {
        if (isExpired(session)) {
          sessions.delete(id);
          return undefined;
        }
        return session;
      }
    }
    return undefined;
  }

  return {
    create,
    getById(id) {
      return find((session) => session.id === id);
    },
    getByState(state) {
      return find((session) => session.state === state);
    },
    getByPairingCode(code) {
      const normalizedCode = typeof code === "string" ? code.toUpperCase() : "";
      return find((session) => session.pairingCode === normalizedCode);
    },
    delete(id) {
      sessions.delete(id);
    },
  };
}
