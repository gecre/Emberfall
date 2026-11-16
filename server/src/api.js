import express from "express";
import { signToken, hashPassword, verifyPassword } from "./auth.js";
import { MAX_CHARACTERS, dbFingerprint } from "./config.js";
import {
  activeBan,
  characterFull,
  characterSummary,
  createAccount,
  deleteCharacter,
  findAccountByUsername,
  findCharacter,
  findCharacterByName,
  insertCharacter,
  itemCatalog,
  listCharacters,
  parseJson,
  touchLogin,
  updateCharacter,
} from "./db.js";
import { rateLimit, requireAuth } from "./middleware.js";
import {
  defaultCharacterData,
  validateCharacterData,
  validateCharacterName,
  validateCredentials,
} from "./validate.js";

export const api = express.Router();

/**
 * How many seconds passed since a stored timestamp. The database keeps UTC
 * timestamps in SQLite's "YYYY-MM-DD HH:MM:SS" format.
 */
function secondsSince(timestamp) {
  if (!timestamp) return 0;
  const parsed = Date.parse(`${String(timestamp).replace(" ", "T")}Z`);
  if (Number.isNaN(parsed)) return 0;
  return Math.max(0, (Date.now() - parsed) / 1000);
}

const publicAccount = (account) => ({
  id: account.id,
  username: account.username,
});

const loginLimiter = rateLimit({ name: "login", windowMs: 60_000, max: 5 });
const registerLimiter = rateLimit({ name: "register", windowMs: 60_000, max: 5 });
const saveLimiter = rateLimit({ name: "save", windowMs: 60_000, max: 90 });

api.get("/health", (_req, res) => {
  res.json({
    ok: true,
    service: "emberfall-server",
    items: itemCatalog.size,
    // Fingerprint of the database this server has open, so the admin CLI can
    // avoid restoring over a database that is still in use.
    db_id: dbFingerprint(),
  });
});

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

api.post("/register", registerLimiter, (req, res) => {
  const { username, password } = req.body ?? {};
  const problem = validateCredentials(username, password);
  if (problem) return res.status(400).json({ error: problem });

  const clean = username.trim();
  if (findAccountByUsername(clean)) {
    return res.status(409).json({ error: "That username is already taken." });
  }

  const account = createAccount(clean, hashPassword(password));
  return res.status(201).json({
    token: signToken(account),
    account: publicAccount(account),
    characters: [],
  });
});

api.post("/login", loginLimiter, (req, res) => {
  const { username, password } = req.body ?? {};
  if (typeof username !== "string" || typeof password !== "string") {
    return res.status(400).json({ error: "Username and password are required." });
  }

  const account = findAccountByUsername(username.trim());
  if (!account || !verifyPassword(password, account.password_hash)) {
    return res.status(401).json({ error: "Invalid username or password." });
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

  touchLogin(account.id);
  return res.json({
    token: signToken(account),
    account: publicAccount(account),
    characters: listCharacters(account.id).map(characterSummary),
  });
});

api.get("/me", requireAuth, (req, res) => {
  res.json({ account: publicAccount(req.account) });
});

// ---------------------------------------------------------------------------
// Characters (cloud saves)
// ---------------------------------------------------------------------------

api.get("/characters", requireAuth, (req, res) => {
  res.json({ characters: listCharacters(req.account.id).map(characterSummary) });
});

api.post("/characters", requireAuth, (req, res) => {
  const body = req.body ?? {};
  const name = typeof body.name === "string" ? body.name.trim() : "";
  const playerClass = typeof body.class === "string" ? body.class : "Warrior";

  const nameProblem = validateCharacterName(name);
  if (nameProblem) return res.status(400).json({ error: nameProblem });
  if (findCharacterByName(name)) {
    return res.status(409).json({ error: "That character name is already taken." });
  }
  if (listCharacters(req.account.id).length >= MAX_CHARACTERS) {
    return res.status(409).json({
      error: `An account may own at most ${MAX_CHARACTERS} characters.`,
    });
  }

  let data = body.data;
  if (data === undefined || data === null) {
    data = defaultCharacterData(name, playerClass);
  }
  if (typeof data !== "object" || Array.isArray(data)) {
    return res.status(400).json({ error: "data must be an object." });
  }
  // The request is authoritative for identity; keep the blob consistent.
  data.player_name = name;
  data.player_class = playerClass;

  const result = validateCharacterData(data, { isCreate: true });
  if (result.error) return res.status(400).json({ error: result.error });

  try {
    const row = insertCharacter(req.account.id, result.summary);
    return res.status(201).json({ character: characterFull(row) });
  } catch (error) {
    if (String(error.message).includes("UNIQUE")) {
      return res.status(409).json({ error: "That character name is already taken." });
    }
    throw error;
  }
});

api.get("/characters/:id", requireAuth, (req, res) => {
  const row = findCharacter(req.account.id, Number(req.params.id));
  if (!row) return res.status(404).json({ error: "Character not found." });
  return res.json({ character: characterFull(row) });
});

api.put("/characters/:id", requireAuth, saveLimiter, (req, res) => {
  const characterId = Number(req.params.id);
  const row = findCharacter(req.account.id, characterId);
  if (!row) return res.status(404).json({ error: "Character not found." });

  const data = req.body?.data;
  const stored = parseJson(row.data, {});
  const result = validateCharacterData(data, {
    previousGold: Number(row.gold) || 0,
    previousInventory: Array.isArray(stored.inventory) ? stored.inventory : [],
    elapsedSeconds: secondsSince(row.updated_at),
  });
  if (result.error) return res.status(400).json({ error: result.error });

  try {
    const updated = updateCharacter(req.account.id, characterId, result.summary);
    return res.json({
      character: characterSummary(updated),
      saved_at: updated.updated_at,
    });
  } catch (error) {
    if (String(error.message).includes("UNIQUE")) {
      return res.status(409).json({ error: "That character name is already taken." });
    }
    throw error;
  }
});

api.delete("/characters/:id", requireAuth, (req, res) => {
  const characterId = Number(req.params.id);
  const row = findCharacter(req.account.id, characterId);
  if (!row) return res.status(404).json({ error: "Character not found." });
  if (!deleteCharacter(req.account.id, characterId)) {
    return res.status(500).json({ error: "Could not delete that character." });
  }
  return res.json({ deleted: characterId });
});

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------
api.get("/items", (_req, res) => {
  const items = [...itemCatalog.entries()].map(([name, item]) => ({
    name,
    price: Number(item.price) || 0,
    sell: Number(item.sell) || 0,
    slot: String(item.slot || "none"),
    type: String(item.type || ""),
    level: Number(item.level) || 0,
  }));
  res.json({ count: items.length, items });
});
