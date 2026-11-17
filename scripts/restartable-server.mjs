export function createRestartableServer(start) {
  if (typeof start !== "function") {
    throw new TypeError("start must be a function");
  }
  let current = null;
  let starting = null;
  let closing = null;
  return {
    get current() {
      return current;
    },
    get isOpen() {
      return current !== null;
    },
    async start() {
      if (current || starting || closing) {
        throw new Error("server is already open");
      }
      starting = (async () => {
        const opened = await start();
        if (!opened || typeof opened.close !== "function") {
          throw new TypeError("start must return an object with close()");
        }
        current = opened;
        return opened;
      })();
      try {
        return await starting;
      } finally {
        starting = null;
      }
    },
    close() {
      if (closing) {
        return closing;
      }
      if (starting) {
        return Promise.reject(new Error("server is still starting"));
      }
      const opened = current;
      if (!opened) return Promise.resolve();
      closing = (async () => {
        try {
          await opened.close();
          if (current !== opened) {
            throw new Error("server state changed during close");
          }
          current = null;
        } finally {
          closing = null;
        }
      })();
      return closing;
    },
  };
}
