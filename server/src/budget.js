const DAY_MS = 24 * 60 * 60 * 1000;

// Workers AI refills at 00:00 UTC, so this counts UTC days; a rolling window
// would drift and refuse calls on a quota already back.
function utcDay(at) {
  return Math.floor(at / DAY_MS);
}

// The rate limiter guards a caller. This guards the account, whose free
// allocation is one pool shared by everyone using the app.
export function createDailyBudget({ maximum, now = Date.now } = {}) {
  let day = -1;
  let spent = 0;

  return {
    // Reserved up front: a failed call has usually still cost the neurons.
    take() {
      const today = utcDay(now());
      if (today !== day) {
        day = today;
        spent = 0;
      }
      if (spent >= maximum) {
        return false;
      }
      spent += 1;
      return true;
    },
  };
}
