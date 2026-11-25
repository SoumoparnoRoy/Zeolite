import { isIPv6 } from "node:net";

const WINDOW_MS = 60 * 1000;
const SWEEP_INTERVAL_MS = 60 * 1000;

// An IPv6 subscriber usually gets a whole /64 to rotate through, so the /64 is
// the caller. IPv4, and the zero-prefixed forms that carry it, stay per address.
function callerOf(ip) {
  if (typeof ip !== "string" || !isIPv6(ip) || ip.includes(".")) {
    return ip;
  }
  const [head, tail] = ip.split("%")[0].split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups =
    tail === undefined
      ? left
      : [...left, ...Array(8 - left.length - right.length).fill("0"), ...right];
  const prefix = groups.slice(0, 4).map((group) => parseInt(group, 16));
  if (prefix[0] === 0) {
    return ip;
  }
  return `${prefix.map((group) => group.toString(16)).join(":")}::/64`;
}

export function createRateLimiter({ now = Date.now } = {}) {
  const windows = new Map();

  function removeExpired() {
    const currentTime = now();
    for (const [key, entry] of windows) {
      if (currentTime - entry.startedAt >= WINDOW_MS) {
        windows.delete(key);
      }
    }
  }

  // The limiter must not keep an otherwise idle process alive.
  const sweepTimer = setInterval(removeExpired, SWEEP_INTERVAL_MS);
  sweepTimer.unref();

  return function limit(route, maximum) {
    return function enforceLimit(request, response, next) {
      const key = `${route}:${callerOf(request.ip)}`;
      const currentTime = now();
      let entry = windows.get(key);

      if (!entry || currentTime - entry.startedAt >= WINDOW_MS) {
        entry = { count: 0, startedAt: currentTime };
        windows.set(key, entry);
      }

      entry.count += 1;
      if (entry.count > maximum) {
        response.status(429).json({ error: "Too many requests." });
        return;
      }
      next();
    };
  };
}
