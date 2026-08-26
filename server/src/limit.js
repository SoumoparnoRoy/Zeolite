const WINDOW_MS = 60 * 1000;
const SWEEP_INTERVAL_MS = 60 * 1000;

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
      const key = `${route}:${request.ip}`;
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
