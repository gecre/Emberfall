import express from "express";
import fs from "node:fs";
import path from "node:path";
import { signToken, hashPassword, verifyPassword } from "./auth.js";
import { isAccountOnline, isCharacterOnline } from "./ws_relay.js";
import { MAX_CHARACTERS, dbFingerprint } from "./config.js";
import {
  db,
  activeBan,
  characterFull,
  characterSummary,
  createAccount,
  deleteCharacter,
  findAccountById,
  findAccountByUsername,
  findCharacter,
  findCharacterByName,
  insertCharacter,
  itemCatalog,
  listCharacters,
  parseJson,
  touchLogin,
  updateCharacter,
  sendFriendRequest,
  respondFriendRequest,
  listFriends,
  listPendingRequests,
  listSentRequests,
  removeFriend,
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

api.get("/version", (_req, res) => {
  const versionFile = path.resolve("public/version.json");
  if (fs.existsSync(versionFile)) {
    try {
      const data = JSON.parse(fs.readFileSync(versionFile, "utf-8"));
      return res.json(data);
    } catch {
      // fallback
    }
  }
  res.json({
    version: "1.0.0",
    pck_url: "/api/updates/patch.pck",
    notes: "Latest release",
  });
});

api.get("/updates/patch.pck", (_req, res) => {
  const pckPath = path.resolve("public/patch.pck");
  if (fs.existsSync(pckPath)) {
    return res.download(pckPath, "patch.pck");
  }
  res.status(404).json({ error: "No patch file found on server." });
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

  if (isAccountOnline(account.username)) {
    return res.status(409).json({
      error: "This account is already logged in on another device.",
    });
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
  if (isCharacterOnline(row.name)) {
    return res.status(409).json({
      error: "This character is already playing on another device.",
    });
  }
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

// ---------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------

// GET /api/friends  — my accepted friends
api.get("/friends", requireAuth, (req, res) => {
  const friends = listFriends(req.account.id);
  res.json({ friends });
});

// GET /api/friends/requests  — pending incoming requests
api.get("/friends/requests", requireAuth, (req, res) => {
  const requests = listPendingRequests(req.account.id);
  const sent = listSentRequests(req.account.id);
  res.json({ requests, sent });
});

// POST /api/friends/request  — send a friend request by username or character name
api.post("/friends/request", requireAuth, (req, res) => {
  const { username } = req.body ?? {};
  if (typeof username !== "string" || !username.trim()) {
    return res.status(400).json({ error: "Username or character name is required." });
  }
  const cleanName = username.trim();
  let target = findAccountByUsername(cleanName);
  let resolvedName = target ? target.username : "";
  if (!target) {
    const char = findCharacterByName(cleanName);
    if (char) {
      target = findAccountById(char.account_id);
      if (target) {
        resolvedName = char.name;
      }
    }
  }
  if (!target) {
    return res.status(404).json({ error: "Player not found." });
  }
  if (target.id === req.account.id) {
    return res.status(400).json({ error: "You cannot add yourself as a friend." });
  }
  // Check if already friends or pending
  const existing = db.prepare(
    `SELECT * FROM friends WHERE (requester_id = ? AND addressee_id = ?) OR (requester_id = ? AND addressee_id = ?)`
  ).get(req.account.id, target.id, target.id, req.account.id);
  if (existing) {
    if (existing.status === "accepted") return res.status(409).json({ error: "Already friends." });
    if (existing.status === "pending") return res.status(409).json({ error: "Friend request already pending." });
    // If not accepted and not pending (e.g. was declined or cancelled previously), remove old row
    db.prepare(`DELETE FROM friends WHERE id = ?`).run(existing.id);
  }
  sendFriendRequest(req.account.id, target.id);
  res.json({ ok: true, to: resolvedName || target.username, account_username: target.username });
});

// POST /api/friends/respond  — accept or decline an incoming request
api.post("/friends/respond", requireAuth, (req, res) => {
  const { requester_id, accept } = req.body ?? {};
  if (typeof requester_id !== "number" && typeof requester_id !== "string") {
    return res.status(400).json({ error: "requester_id is required." });
  }
  const rid = Number(requester_id);
  const row = db.prepare(
    `SELECT * FROM friends WHERE requester_id = ? AND addressee_id = ? AND status = 'pending'`
  ).get(rid, req.account.id);
  if (!row) return res.status(404).json({ error: "Friend request not found." });
  respondFriendRequest(rid, req.account.id, Boolean(accept));
  res.json({ ok: true });
});

// DELETE /api/friends/:id  — remove a friend (account id of the other person)
api.delete("/friends/:id", requireAuth, (req, res) => {
  const otherId = Number(req.params.id);
  removeFriend(req.account.id, otherId);
  res.json({ ok: true });
});
