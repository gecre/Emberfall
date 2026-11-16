import { verifyToken } from "./auth.js";
import { activeBan, findAccountById } from "./db.js";

/**
 * In-memory sliding-window rate limiter. Keys are scoped per route so a busy
 * save endpoint never locks a player out of login.
 */
const buckets = new Map();

export function rateLimit({ windowMs = 60_000, max = 60, name = "request" } = {}) {
  return (req, res, next) => {
    const identity = req.account?.id ? `acct:${req.account.id}` : `ip:${req.ip}`;
    const key = `${name}:${identity}`;
    const now = Date.now();
    let bucket = buckets.get(key);
    if (!bucket || now - bucket.start >= windowMs) {
      bucket = { start: now, count: 0 };
      buckets.set(key, bucket);
    }
    bucket.count += 1;
    if (bucket.count > max) {
      const retryAfter = Math.max(
        1,
        Math.ceil((bucket.start + windowMs - now) / 1000),
      );
      res.set("Retry-After", String(retryAfter));
      return res.status(429).json({ error: "Too many requests. Try again shortly." });
    }
    next();
  };
}

/** Reject requests without a valid Bearer token. */
export function requireAuth(req, res, next) {
  const header = req.get("authorization") || "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) {
    return res.status(401).json({ error: "Missing bearer token." });
  }
  const payload = verifyToken(match[1]);
  if (!payload || !payload.account_id) {
    return res.status(401).json({ error: "Invalid or expired session." });
  }
  const account = findAccountById(payload.account_id);
  if (!account) {
    return res.status(401).json({ error: "Account no longer exists." });
  }
  if (account.banned) {
    return res.status(403).json({
      error: account.ban_reason || "This account is banned.",
    });
  }
  const ban = activeBan(account.id);
  if (ban) {
    return res.status(403).json({ error: ban.reason || "This account is banned." });
  }
  req.account = account;
  next();
}

/** Emits one concise request line; quiet in tests. */
export function requestLogger(req, res, next) {
  if (process.env.EMBERFALL_QUIET === "1") return next();
  const started = Date.now();
  res.on("finish", () => {
    console.log(
      `${req.method} ${req.originalUrl} -> ${res.statusCode} (${Date.now() - started}ms)`,
    );
  });
  next();
}
