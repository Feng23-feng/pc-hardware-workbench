function guardError(message, code) {
  return Object.assign(new Error(message), { code });
}

export function installSingleThreadRequestGuard(driver, {
  onThreadStarted = () => {},
  onTurnStarted = () => {},
  onBlocked = () => {},
} = {}) {
  const originalRequest = driver.request.bind(driver);
  let threadCount = 0;
  let turnCount = 0;
  let threadStartInFlight = false;

  driver.request = async (method, params, timeoutMs) => {
    if (/thread\/(resume|read|list)|thread\/turns\/list/u.test(method)) {
      const error = guardError(
        "forbidden thread history access",
        "forbidden_thread_history_access",
      );
      onBlocked(error);
      throw error;
    }
    if (method === "thread/start") {
      if (threadCount > 0 || threadStartInFlight) {
        const error = guardError(
          "single-thread guard rejected another thread/start",
          "single_thread_violation",
        );
        onBlocked(error);
        throw error;
      }
      threadStartInFlight = true;
    }
    if (
      method === "turn/start" &&
      (threadCount !== 1 || turnCount > 0)
    ) {
      const error = guardError(
        "single-turn guard rejected another turn/start",
        turnCount > 0 ? "single_turn_violation" : "single_thread_violation",
      );
      onBlocked(error);
      throw error;
    }

    let result;
    try {
      result = await originalRequest(method, params, timeoutMs);
    } finally {
      if (method === "thread/start") {
        threadStartInFlight = false;
      }
    }
    if (method === "thread/start") {
      threadCount += 1;
      onThreadStarted(result);
    }
    if (method === "turn/start") {
      turnCount += 1;
      onTurnStarted(result);
    }
    return result;
  };

  return {
    get threadCount() {
      return threadCount;
    },
    get turnCount() {
      return turnCount;
    },
  };
}
