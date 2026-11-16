import express from "express";
import { pathToFileURL } from "node:url";
import { api } from "./api.js";
import { PORT, HOST, ADMIN_ENABLED, ADMIN_KEY } from "./config.js";
import { db } from "./db.js";
import { startDiscovery } from "./discovery.js";
import { requestLogger } from "./middleware.js";
import { admin } from "./admin_web.js";

export function createApp() {
  const app = express();
  app.disable("x-powered-by");
  app.use(requestLogger);
  app.use(express.json({ limit: "1mb" }));

  // Mounted before the CORS middleware on purpose: the admin dashboard must
  // not be reachable from another origin, so it must not get the permissive
  // `Access-Control-Allow-Origin: *` header below.
  if (ADMIN_ENABLED) {
    app.use("/admin", admin);
  }

  // The game client is native, but a web export / browser test client benefits
  // from permissive CORS. No cookies are used (Bearer tokens only).
  app.use((req, res, next) => {
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
    res.set("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS");
    res.set("X-Content-Type-Options", "nosniff");
    if (req.method === "OPTIONS") return res.sendStatus(204);
    next();
  });

  app.use("/api", api);

  app.use((_req, res) => {
    res.status(404).json({ error: "Not found." });
  });

  // Express error handler: keep responses JSON even for parser failures.
  app.use((error, _req, res, _next) => {
    if (error?.type === "entity.too.large") {
      return res.status(413).json({ error: "Request body is too large." });
    }
    if (error instanceof SyntaxError && "body" in error) {
      return res.status(400).json({ error: "Malformed JSON body." });
    }
    console.error("[server] unhandled error:", error);
    return res.status(500).json({ error: "Internal server error." });
  });

  return app;
}

const isMain =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain) {
  const app = createApp();
  const server = app.listen(PORT, HOST, () => {
    console.log(`[server] Emberfall API listening on http://${HOST}:${PORT}/api`);
    if (ADMIN_ENABLED) {
      console.log(`[server] Admin dashboard:  http://127.0.0.1:${PORT}/admin`);
      console.log(`[server] Admin key:       ${ADMIN_KEY}`);
    }
  });

  // Lets phones and emulators find the server without typing an address.
  let discovery = null;
  try {
    discovery = startDiscovery();
  } catch (error) {
    console.warn("[server] discovery is not available:", error.message);
  }

  const shutdown = (signal) => {
    console.log(`[server] ${signal} received, shutting down.`);
    if (discovery) {
      try {
        discovery.close();
      } catch {
        // already closed
      }
    }
    server.close(() => {
      db.close();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 5000).unref();
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}
