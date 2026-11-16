/**
 * Local admin dashboard.
 *
 * Served at /admin and only reachable from loopback. Every API call has to
 * present the admin key, which also stops a random web page from poking the
 * dashboard through the browser (a cross-origin request cannot set a custom
 * header, and this router sends no CORS headers at all).
 */
import express from "express";
import fs from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  createBackup,
  listBackups,
  pruneBackups,
  replaceDatabaseFile,
  verifyBackup,
} from "./backup.js";
import { ADMIN_HTML_PATH, ADMIN_KEY, BACKUP_DIR, DATA_DIR, DB_PATH, ITEMS_PATH, MONSTERS_PATH } from "./config.js";
import { db, reopenDatabase, itemCatalog } from "./db.js";

export const admin = express.Router();

const ALLOW_REMOTE = process.env.EMBERFALL_ADMIN_REMOTE !== "0";

/** True when the request came from this machine. */
function isLoopback(req) {
  const address = req.socket.remoteAddress || "";
  return (
    address === "127.0.0.1" ||
    address === "::1" ||
    address === "::ffff:127.0.0.1" ||
    address === "::ffff:0:0:0:0:0:0:1"
  );
}

/** Rejects unallowed remote access if remote admin is explicitly turned off. */
admin.use((req, res, next) => {
  if (!isLoopback(req) && !ALLOW_REMOTE) {
    return res
      .status(403)
      .json({ error: "The admin dashboard is only available from localhost." });
  }
  next();
});

/** Requires the admin key on every data route. */
function requireKey(req, res, next) {
  const provided = req.get("x-admin-key") || req.query.key;
  if (!provided || provided !== ADMIN_KEY) {
    return res.status(401).json({ error: "Bad or missing admin key." });
  }
  next();
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

admin.get("/", (req, res) => {
  if (!fs.existsSync(ADMIN_HTML_PATH)) {
    return res
      .status(404)
      .send("The admin dashboard page is missing from server/public/admin.html");
  }
  const canEmbed = isLoopback(req) || (req.query.key && req.query.key === ADMIN_KEY);
  const html = fs
    .readFileSync(ADMIN_HTML_PATH, "utf8")
    .replace("__ADMIN_KEY__", canEmbed ? ADMIN_KEY : "");
  res.type("html").send(html);
});

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

/** Runs a read-only statement and returns the rows. */
function runReadOnly(sql, target = DB_PATH) {
  const statement = String(sql || "")
    .trim()
    .replace(/;+\s*$/, "");
  if (!/^(select|with|pragma|explain)\b/i.test(statement)) {
    throw new Error("Only read-only statements are allowed here.");
  }
  if (!fs.existsSync(target)) {
    throw new Error(`Database not found: ${target}`);
  }
  const handle = new DatabaseSync(target, { readOnly: true });
  try {
    return handle.prepare(statement).all();
  } finally {
    handle.close();
  }
}

function fileSize(file) {
  try {
    return fs.statSync(file).size;
  } catch {
    return 0;
  }
}

admin.get("/api/overview", requireKey, (_req, res) => {
  const count = (table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
  res.json({
    db_path: DB_PATH,
    db_size: fileSize(DB_PATH),
    wal_size: fileSize(`${DB_PATH}-wal`),
    journal_mode: db.prepare("PRAGMA journal_mode").get().journal_mode,
    accounts: count("accounts"),
    characters: count("characters"),
    items: count("items"),
    bans: count("bans"),
    mutes: count("mutes"),
    user_version: db.prepare("PRAGMA user_version").get().user_version,
  });
});

admin.get("/api/accounts", requireKey, (_req, res) => {
  const rows = db
    .prepare(
      `SELECT a.id, a.username, a.banned, a.ban_reason, a.muted, a.mute_reason,
              a.created_at, a.last_login,
              (SELECT COUNT(*) FROM characters c WHERE c.account_id = a.id) AS characters
       FROM accounts a ORDER BY a.id`,
    )
    .all();
  res.json({ accounts: rows });
});

admin.get("/api/characters", requireKey, (_req, res) => {
  const rows = db
    .prepare(
      `SELECT c.id, c.account_id, c.name, c.class, c.level, c.xp, c.gold,
              c.current_stage, c.unlocked_stage, c.play_time, c.updated_at,
              a.username AS owner
       FROM characters c
       JOIN accounts a ON a.id = c.account_id
       ORDER BY c.id`,
    )
    .all();
  res.json({ characters: rows });
});

admin.get("/api/items", requireKey, (req, res) => {
  const search = String(req.query.q || "").trim();
  const rows = search
    ? db
        .prepare(
          `SELECT name, price, sell, slot, type, level FROM items
           WHERE name LIKE ? OR type LIKE ? ORDER BY name`,
        )
        .all(`%${search}%`, `%${search}%`)
    : db
        .prepare(`SELECT name, price, sell, slot, type, level FROM items ORDER BY name`)
        .all();

  const enriched = rows.map((r) => {
    const extra = itemCatalog.get(r.name) || {};
    return {
      ...r,
      damage_min: extra.damage_min ?? "-",
      damage_max: extra.damage_max ?? "-",
      defense: extra.defense ?? "-",
      reach: extra.reach ?? "-",
      rpm: extra.rpm ?? "-",
    };
  });
  res.json({ items: enriched });
});

admin.get("/api/item-names", requireKey, (_req, res) => {
  const rows = db.prepare("SELECT name FROM items ORDER BY name").all();
  res.json({ names: rows.map((r) => r.name) });
});

admin.get("/api/items/:name", requireKey, (req, res) => {
  const name = String(req.params.name || "").trim();
  let item = null;
  if (fs.existsSync(ITEMS_PATH)) {
    try {
      const allItems = JSON.parse(fs.readFileSync(ITEMS_PATH, "utf8"));
      item = allItems[name];
    } catch {}
  }
  if (!item) {
    item = itemCatalog.get(name);
  }
  if (!item) {
    const row = db.prepare("SELECT * FROM items WHERE name = ?").get(name);
    if (!row) return res.status(404).json({ error: "Item not found." });
    item = row;
  }
  res.json({ item });
});

// Edit item price, sell, stats, level, etc.
admin.patch("/api/items/:name", requireKey, (req, res) => {
  const name = String(req.params.name || "").trim();
  const row = db.prepare("SELECT * FROM items WHERE name = ?").get(name);
  if (!row) return res.status(404).json({ error: "Item not found." });

  const price = req.body?.price !== undefined ? Math.max(0, Math.floor(Number(req.body.price))) : row.price;
  const sell = req.body?.sell !== undefined ? Math.max(0, Math.floor(Number(req.body.sell))) : row.sell;
  const level = req.body?.level !== undefined ? Math.max(0, Math.floor(Number(req.body.level))) : row.level;
  const slot = req.body?.slot !== undefined ? String(req.body.slot).trim() : row.slot;
  const type = req.body?.type !== undefined ? String(req.body.type).trim() : row.type;

  db.prepare("UPDATE items SET price = ?, sell = ?, level = ?, slot = ?, type = ? WHERE name = ?").run(
    price,
    sell,
    level,
    slot,
    type,
    name,
  );

  let updatedItem = null;
  if (fs.existsSync(ITEMS_PATH)) {
    try {
      const allItems = JSON.parse(fs.readFileSync(ITEMS_PATH, "utf8"));
      if (allItems[name]) {
        const item = allItems[name];
        item.price = price;
        item.sell = sell;
        item.level = level;
        item.slot = slot;
        item.type = type;

        const numFields = [
          "damage_min",
          "damage_max",
          "defense",
          "power",
          "magic",
          "range",
          "luck",
          "strength",
          "dexterity",
          "health",
          "reach",
          "rpm",
        ];
        for (const f of numFields) {
          if (req.body?.[f] !== undefined) {
            item[f] = Number(req.body[f]) || 0;
          }
        }
        if (req.body?.two_handed !== undefined) {
          item.two_handed = Boolean(req.body.two_handed);
        }

        updatedItem = item;
        fs.writeFileSync(ITEMS_PATH, JSON.stringify(allItems, null, "\t"), "utf8");
      }
    } catch (err) {
      console.error("[admin] Failed to write items.json:", err);
    }
  }

  const cat = itemCatalog.get(name);
  if (cat && updatedItem) {
    Object.assign(cat, updatedItem);
  } else if (cat) {
    cat.price = price;
    cat.sell = sell;
    cat.level = level;
    cat.slot = slot;
    cat.type = type;
  }

  res.json({ ok: true, item: updatedItem || { name, price, sell, level, slot, type } });
});

// --- Monsters ---
function readMonstersJson() {
  if (!fs.existsSync(MONSTERS_PATH)) return {};
  try {
    return JSON.parse(fs.readFileSync(MONSTERS_PATH, "utf8"));
  } catch {
    return {};
  }
}

admin.get("/api/monsters", requireKey, (req, res) => {
  const all = readMonstersJson();
  const search = String(req.query.q || "").toLowerCase().trim();
  const filterBoss = req.query.boss;
  let list = Object.values(all);
  if (search) {
    list = list.filter((m) => String(m.name || "").toLowerCase().includes(search));
  }
  if (filterBoss === "1") {
    list = list.filter((m) => !!m.boss);
  } else if (filterBoss === "0") {
    list = list.filter((m) => !m.boss);
  }
  res.json({ count: list.length, monsters: list });
});

admin.get("/api/monsters/:name", requireKey, (req, res) => {
  const all = readMonstersJson();
  const monster = all[req.params.name];
  if (!monster) return res.status(404).json({ error: "Monster not found." });
  res.json({ monster });
});

admin.patch("/api/monsters/:name", requireKey, (req, res) => {
  const name = String(req.params.name || "").trim();
  const all = readMonstersJson();
  const monster = all[name];
  if (!monster) return res.status(404).json({ error: "Monster not found." });

  if (req.body?.health !== undefined) {
    monster.health = Math.max(1, Math.floor(Number(req.body.health)));
  }
  if (req.body?.defense !== undefined) {
    monster.defense = Math.max(0, Math.floor(Number(req.body.defense)));
  }
  if (req.body?.xp !== undefined) {
    monster.xp = Math.max(0, Math.floor(Number(req.body.xp)));
  }
  if (req.body?.worth !== undefined) {
    monster.worth = Math.max(0, Math.floor(Number(req.body.worth)));
  }
  if (req.body?.drops !== undefined && Array.isArray(req.body.drops)) {
    monster.drops = req.body.drops.map((d) => String(d).trim()).filter(Boolean);
  }

  try {
    fs.writeFileSync(MONSTERS_PATH, JSON.stringify(all, null, "\t"), "utf8");
    res.json({ ok: true, monster });
  } catch (err) {
    res.status(500).json({ error: "Failed to write monsters.json: " + err.message });
  }
});

admin.get("/api/character/:id", requireKey, (req, res) => {
  const row = db
    .prepare("SELECT * FROM characters WHERE id = ?")
    .get(Number(req.params.id));
  if (!row) return res.status(404).json({ error: "Character not found." });
  res.json({
    character: {
      ...row,
      inventory: JSON.parse(row.inventory || "[]"),
      equipment: JSON.parse(row.equipment || "{}"),
      attributes: JSON.parse(row.attributes || "{}"),
      skills: JSON.parse(row.skills || "{}"),
      quests: JSON.parse(row.quests || "{}"),
      data: JSON.parse(row.data || "{}"),
    },
  });
});

admin.post("/api/query", requireKey, (req, res) => {
  try {
    const rows = runReadOnly(req.body?.sql);
    res.json({ rows });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

// ---------------------------------------------------------------------------
// Account actions
// ---------------------------------------------------------------------------

function findAccount(id) {
  return db.prepare("SELECT * FROM accounts WHERE id = ?").get(Number(id));
}

admin.post("/api/accounts/:id/ban", requireKey, (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  const reason = String(req.body?.reason || "Banned by an administrator.");
  db.prepare("UPDATE accounts SET banned = 1, ban_reason = ? WHERE id = ?").run(
    reason,
    account.id,
  );
  db.prepare(
    `INSERT INTO bans (account_id, reason, created_by) VALUES (?, ?, 'dashboard')`,
  ).run(account.id, reason);
  res.json({ ok: true, account: findAccount(req.params.id) });
});

admin.post("/api/accounts/:id/unban", requireKey, (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  db.prepare("UPDATE accounts SET banned = 0, ban_reason = NULL WHERE id = ?").run(
    account.id,
  );
  db.prepare("DELETE FROM bans WHERE account_id = ?").run(account.id);
  res.json({ ok: true, account: findAccount(req.params.id) });
});

admin.post("/api/accounts/:id/mute", requireKey, (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  const reason = String(req.body?.reason || "Muted by an administrator.");
  db.prepare("UPDATE accounts SET muted = 1, mute_reason = ? WHERE id = ?").run(
    reason,
    account.id,
  );
  db.prepare(
    `INSERT INTO mutes (account_id, reason, created_by) VALUES (?, ?, 'dashboard')`,
  ).run(account.id, reason);
  res.json({ ok: true, account: findAccount(req.params.id) });
});

admin.post("/api/accounts/:id/unmute", requireKey, (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  db.prepare("UPDATE accounts SET muted = 0, mute_reason = NULL WHERE id = ?").run(
    account.id,
  );
  db.prepare("DELETE FROM mutes WHERE account_id = ?").run(account.id);
  res.json({ ok: true, account: findAccount(req.params.id) });
});

admin.post("/api/accounts/:id/password", requireKey, async (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  const password = String(req.body?.password || "");
  if (password.length < 6) {
    return res.status(400).json({ error: "The password must be at least 6 characters." });
  }
  if (password.length > 72) {
    return res.status(400).json({ error: "The password must be 72 characters or fewer." });
  }
  const { hashPassword } = await import("./auth.js");
  db.prepare("UPDATE accounts SET password_hash = ? WHERE id = ?").run(
    hashPassword(password),
    account.id,
  );
  res.json({ ok: true });
});

admin.delete("/api/accounts/:id", requireKey, (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  const characters = db
    .prepare("SELECT COUNT(*) AS n FROM characters WHERE account_id = ?")
    .get(account.id).n;
  db.prepare("DELETE FROM accounts WHERE id = ?").run(account.id);
  res.json({ ok: true, deleted: account.username, characters });
});

admin.delete("/api/characters/:id", requireKey, (req, res) => {
  const character = db
    .prepare("SELECT id, name FROM characters WHERE id = ?")
    .get(Number(req.params.id));
  if (!character) return res.status(404).json({ error: "Character not found." });
  db.prepare("DELETE FROM characters WHERE id = ?").run(character.id);
  res.json({ ok: true, deleted: character.name });
});

admin.post("/api/characters/:id/rename", requireKey, (req, res) => {
  const id = Number(req.params.id);
  const newName = String(req.body?.name || "").trim();
  if (!newName) {
    return res.status(400).json({ error: "New character name is required." });
  }
  const character = db.prepare("SELECT id, name, data FROM characters WHERE id = ?").get(id);
  if (!character) {
    return res.status(404).json({ error: "Character not found." });
  }
  const existing = db
    .prepare("SELECT id FROM characters WHERE name = ? COLLATE NOCASE AND id != ?")
    .get(newName, id);
  if (existing) {
    return res.status(409).json({ error: "A character with that name already exists." });
  }

  db.prepare("UPDATE characters SET name = ? WHERE id = ?").run(newName, id);

  try {
    const dataObj = JSON.parse(character.data || "{}");
    dataObj.player_name = newName;
    db.prepare("UPDATE characters SET data = ? WHERE id = ?").run(JSON.stringify(dataObj), id);
  } catch {}

  res.json({ ok: true, id, oldName: character.name, name: newName });
});

// Edit a character's gold, level, current_stage, and/or unlocked_stage.
admin.patch("/api/character/:id", requireKey, (req, res) => {
  const id = Number(req.params.id);
  const row = db.prepare("SELECT * FROM characters WHERE id = ?").get(id);
  if (!row) return res.status(404).json({ error: "Character not found." });
  const gold = req.body?.gold !== undefined ? Math.max(0, Math.floor(Number(req.body.gold))) : null;
  const level = req.body?.level !== undefined ? Math.max(1, Math.min(9999, Math.floor(Number(req.body.level)))) : null;
  const current_stage = req.body?.current_stage !== undefined ? Math.max(1, Math.floor(Number(req.body.current_stage))) : null;
  const unlocked_stage = req.body?.unlocked_stage !== undefined ? Math.max(1, Math.floor(Number(req.body.unlocked_stage))) : null;
  if (gold === null && level === null && current_stage === null && unlocked_stage === null) {
    return res.status(400).json({ error: "Nothing to update." });
  }
  const data = JSON.parse(row.data || "{}");
  if (gold !== null) { row.gold = gold; data.gold = gold; }
  if (level !== null) { row.level = level; data.level = level; }
  if (current_stage !== null) { row.current_stage = current_stage; data.current_stage = current_stage; }
  if (unlocked_stage !== null) { row.unlocked_stage = unlocked_stage; data.unlocked_stage = unlocked_stage; }

  db.prepare(
    "UPDATE characters SET gold = ?, level = ?, current_stage = ?, unlocked_stage = ?, data = ?, updated_at = datetime('now') WHERE id = ?"
  ).run(row.gold, row.level, row.current_stage, row.unlocked_stage, JSON.stringify(data), id);
  res.json({ ok: true });
});

// Give a character gold or add an item to their inventory.
admin.post("/api/character/:id/give", requireKey, (req, res) => {
  const id = Number(req.params.id);
  const row = db.prepare("SELECT * FROM characters WHERE id = ?").get(id);
  if (!row) return res.status(404).json({ error: "Character not found." });
  const { gold, item, qty } = req.body || {};
  if (gold !== undefined) {
    const amount = Math.floor(Number(gold));
    if (!Number.isFinite(amount)) return res.status(400).json({ error: "Invalid gold amount." });
    db.prepare("UPDATE characters SET gold = MAX(0, gold + ?), updated_at = datetime('now') WHERE id = ?").run(amount, id);
    return res.json({ ok: true });
  }
  if (item) {
    const quantity = Math.max(1, Math.floor(Number(qty) || 1));
    const inventory = JSON.parse(row.inventory || "[]");
    const existing = inventory.find((e) => e.name === item);
    if (existing) { existing.qty = (existing.qty || 1) + quantity; }
    else { inventory.push({ name: item, qty: quantity, locked: false }); }
    db.prepare("UPDATE characters SET inventory = ?, updated_at = datetime('now') WHERE id = ?").run(JSON.stringify(inventory), id);
    return res.json({ ok: true });
  }
  res.status(400).json({ error: "Provide gold or item." });
});

// Rename a character.
admin.post("/api/character/:id/rename", requireKey, (req, res) => {
  const id = Number(req.params.id);
  const row = db.prepare("SELECT * FROM characters WHERE id = ?").get(id);
  if (!row) return res.status(404).json({ error: "Character not found." });
  const name = String(req.body?.name || "").trim();
  if (!name || name.length < 2 || name.length > 24) return res.status(400).json({ error: "Name must be 2–24 characters." });
  const taken = db.prepare("SELECT id FROM characters WHERE name = ? COLLATE NOCASE AND id != ?").get(name, id);
  if (taken) return res.status(409).json({ error: "That name is already taken." });
  const data = JSON.parse(row.data || "{}");
  if (data && typeof data === "object") data.player_name = name;
  db.prepare("UPDATE characters SET name = ?, data = ?, updated_at = datetime('now') WHERE id = ?").run(name, JSON.stringify(data), id);
  res.json({ ok: true });
});

// Rename an account username.
admin.post("/api/accounts/:id/rename", requireKey, (req, res) => {
  const account = findAccount(req.params.id);
  if (!account) return res.status(404).json({ error: "Account not found." });
  const name = String(req.body?.username || "").trim();
  if (!name || name.length < 2 || name.length > 24) return res.status(400).json({ error: "Username must be 2–24 characters." });
  const taken = db.prepare("SELECT id FROM accounts WHERE username = ? COLLATE NOCASE AND id != ?").get(name, account.id);
  if (taken) return res.status(409).json({ error: "That username is already taken." });
  db.prepare("UPDATE accounts SET username = ? WHERE id = ?").run(name, account.id);
  res.json({ ok: true });
});

// ---------------------------------------------------------------------------
// Backups
// ---------------------------------------------------------------------------

admin.get("/api/backups", requireKey, (_req, res) => {
  res.json({ backups: listBackups(BACKUP_DIR) });
});

admin.post("/api/backups", requireKey, (req, res) => {
  try {
    const file = createBackup({ tag: String(req.body?.tag || "") });
    pruneBackups({});
    res.json({ ok: true, file, backups: listBackups(BACKUP_DIR) });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

admin.get("/api/backups/verify", requireKey, (req, res) => {
  try {
    res.json({ ok: true, report: verifyBackup(String(req.query.file || "")) });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

admin.get("/api/backups/query", requireKey, (req, res) => {
  try {
    const rows = runReadOnly(req.query.sql, String(req.query.file || ""));
    res.json({ rows });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

/**
 * Restores a snapshot while the server is running.
 *
 * The handle this process holds on the database is closed first, the file is
 * swapped, and the database is reopened against the restored file. Everything
 * is synchronous, so no request can interleave with the swap.
 */
admin.post("/api/backups/restore", requireKey, (req, res) => {
  const file = String(req.body?.file || "");
  if (!file) return res.status(400).json({ error: "No snapshot given." });
  try {
    verifyBackup(file);
    const safety = createBackup({ tag: "prerestore" });
    db.close();
    try {
      replaceDatabaseFile(file);
    } finally {
      reopenDatabase();
    }
    res.json({
      ok: true,
      safety,
      accounts: db.prepare("SELECT COUNT(*) AS n FROM accounts").get().n,
      characters: db.prepare("SELECT COUNT(*) AS n FROM characters").get().n,
    });
  } catch (error) {
    // Make sure the database is usable again even if the swap failed.
    try {
      reopenDatabase();
    } catch {
      // reported by the next request
    }
    res.status(400).json({ error: error.message });
  }
});

/** Where the data directory lives, so the dashboard can show it. */
export const adminDataDir = DATA_DIR;

/** Absolute path of the admin page, for the startup banner. */
export const adminPagePath = path.resolve(ADMIN_HTML_PATH);
