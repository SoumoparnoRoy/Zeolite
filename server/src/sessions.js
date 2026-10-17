import { randomBytes } from "node:crypto";

export const SESSION_TTL_MS = 5 * 60 * 1000;
const SWEEP_INTERVAL_MS = 60 * 1000;
const PAIRING_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";

// Anyone can start a session, so many addresses would grow this without end;
// one app never has thousands of people connecting in the same five minutes.
const MOST_SESSIONS = 5000;

function randomPairingCode() {
  let code = "";
  for (let index = 0; index < 8; index += 1) {
    code += PAIRING_ALPHABET[randomBytes(1)[0] % PAIRING_ALPHABET.length];
  }
  return code;
}

export function createSessionStore({ now = Date.now } = {}) {
  const byId = new Map();
  const byState = new Map();
  const byPairingCode = new Map();

  function isExpired(session) {
    return now() - session.createdAt >= SESSION_TTL_MS;
  }

  function add(session) {
    byId.set(session.id, session);
    byState.set(session.state, session);
    byPairingCode.set(session.pairingCode, session);
  }

  function remove(session) {
    byId.delete(session.id);
    byState.delete(session.state);
    byPairingCode.delete(session.pairingCode);
  }

  function removeExpired() {
    for (const session of byId.values()) {
      if (isExpired(session)) {
        remove(session);
      }
    }
  }

  // Expiry is also enforced during lookup so timer scheduling cannot extend a session.
  const sweepTimer = setInterval(removeExpired, SWEEP_INTERVAL_MS);
  sweepTimer.unref();

  function create(challenge) {
    if (byId.size >= MOST_SESSIONS) {
      removeExpired();
      if (byId.size >= MOST_SESSIONS) {
        return undefined;
      }
    }
    // A shared code would leave one of the two sessions unreachable by code.
    let pairingCode;
    do {
      pairingCode = randomPairingCode();
    } while (byPairingCode.has(pairingCode));

    const session = {
      id: randomBytes(32).toString("base64url"),
      state: randomBytes(32).toString("base64url"),
      browser: randomBytes(32).toString("base64url"),
      challenge,
      pairingCode,
      createdAt: now(),
      status: "pending",
    };
    add(session);
    return session;
  }

  function live(session) {
    if (session && isExpired(session)) {
      remove(session);
      return undefined;
    }
    return session;
  }

  return {
    create,
    getById(id) {
      return live(byId.get(id));
    },
    getByState(state) {
      return live(byState.get(state));
    },
    getByPairingCode(code) {
      const normalizedCode = typeof code === "string" ? code.toUpperCase() : "";
      return live(byPairingCode.get(normalizedCode));
    },
    delete(id) {
      const session = byId.get(id);
      if (session) {
        remove(session);
      }
    },
  };
}
