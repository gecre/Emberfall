import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { DATA_DIR, DB_PATH, ITEMS_PATH, SKILLS_PATH } from "./config.js";

fs.mkdirSync(DATA_DIR, { recursive: true });

/**
 * The open database handle.
 *
 * This is a `let` export on purpose: ES module live bindings mean every
 * importer sees the new value after `reopenDatabase()` swaps it, which is how
 * the admin dashboard restores a snapshot without a server restart.
 */
export let db = null;

/** Opens the database and makes sure the schema exists. */
function openDatabase() {
  const handle = new DatabaseSync(DB_PATH);
  handle.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;

    CREATE TABLE IF NOT EXISTS accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE COLLATE NOCASE,
      password_hash TEXT NOT NULL,
      banned INTEGER NOT NULL DEFAULT 0,
      ban_reason TEXT,
      muted INTEGER NOT NULL DEFAULT 0,
      mute_reason TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_login TEXT
    );

    CREATE TABLE IF NOT EXISTS characters (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      name TEXT NOT NULL UNIQUE COLLATE NOCASE,
      class TEXT NOT NULL DEFAULT 'Warrior',
      level INTEGER NOT NULL DEFAULT 1,
      xp INTEGER NOT NULL DEFAULT 0,
      gold INTEGER NOT NULL DEFAULT 0,
      current_stage INTEGER NOT NULL DEFAULT 1,
      unlocked_stage INTEGER NOT NULL DEFAULT 1,
      hp INTEGER NOT NULL DEFAULT 100,
      mp INTEGER NOT NULL DEFAULT 50,
      skill_points INTEGER NOT NULL DEFAULT 3,
      special_skill_points INTEGER NOT NULL DEFAULT 1,
      play_time REAL NOT NULL DEFAULT 0,
      inventory TEXT NOT NULL DEFAULT '[]',
      equipment TEXT NOT NULL DEFAULT '{}',
      attributes TEXT NOT NULL DEFAULT '{}',
      skills TEXT NOT NULL DEFAULT '{}',
      quests TEXT NOT NULL DEFAULT '{}',
      data TEXT NOT NULL DEFAULT '{}',
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE INDEX IF NOT EXISTS idx_characters_account
      ON characters (account_id);

    CREATE TABLE IF NOT EXISTS items (
      name TEXT PRIMARY KEY,
      price INTEGER NOT NULL DEFAULT 0,
      sell INTEGER NOT NULL DEFAULT 0,
      slot TEXT NOT NULL DEFAULT 'none',
      type TEXT NOT NULL DEFAULT '',
      level INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS bans (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      reason TEXT NOT NULL,
      expires_at TEXT,
      created_by TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS mutes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      reason TEXT NOT NULL,
      expires_at TEXT,
      created_by TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS friends (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      requester_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      addressee_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(requester_id, addressee_id)
    );
    CREATE INDEX IF NOT EXISTS idx_friends_addressee ON friends (addressee_id);
  `);
  return handle;
}

/** name -> wiki item data. Used for anti-cheat inventory validation. */
export const itemCatalog = new Map();
/** Known skill names from the wiki data. */
export const skillCatalog = new Set();

function loadItemCatalog(handle) {
  if (!fs.existsSync(ITEMS_PATH)) {
    console.warn(`[db] item data not found at ${ITEMS_PATH}`);
    return;
  }
  const raw = JSON.parse(fs.readFileSync(ITEMS_PATH, "utf8"));
  const insert = handle.prepare(
    `INSERT INTO items (name, price, sell, slot, type, level)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(name) DO UPDATE SET
       price = excluded.price,
       sell = excluded.sell,
       slot = excluded.slot,
       type = excluded.type,
       level = excluded.level`,
  );
  const entries = Array.isArray(raw)
    ? raw.map((item) => [item.name, item])
    : Object.entries(raw);
  handle.exec("BEGIN");
  try {
    for (const [fallbackName, item] of entries) {
      if (!item || typeof item !== "object") continue;
      const name = String(item.name || fallbackName);
      itemCatalog.set(name, item);
      insert.run(
        name,
        Number(item.price) || 0,
        Number(item.sell) || 0,
        String(item.slot || "none"),
        String(item.type || ""),
        Number(item.level) || 0,
      );
    }
    handle.exec("COMMIT");
  } catch (error) {
    handle.exec("ROLLBACK");
    throw error;
  }
  console.log(`[db] loaded ${itemCatalog.size} items`);
}

function loadSkillCatalog() {
  if (!fs.existsSync(SKILLS_PATH)) return;
  const raw = JSON.parse(fs.readFileSync(SKILLS_PATH, "utf8"));
  const entries = Array.isArray(raw) ? raw : Object.values(raw);
  for (const skill of entries) {
    if (skill && typeof skill === "object" && skill.name) {
      skillCatalog.add(String(skill.name));
    }
  }
  console.log(`[db] loaded ${skillCatalog.size} skills`);
}

/**
 * Closes the database and opens it again. Used after the database file has
 * been replaced by a restore.
 */
export function reopenDatabase() {
  const previous = db;
  // Close first: the file may have been replaced under us, and SQLite
  // checkpoints the WAL when the last connection closes.
  if (previous) {
    try {
      previous.close();
    } catch {
      // already closed
    }
  }
  db = openDatabase();
  itemCatalog.clear();
  loadItemCatalog(db);
  loadSkillCatalog();
  return db;
}

db = openDatabase();
loadItemCatalog(db);
loadSkillCatalog();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

export function parseJson(text, fallback) {
  if (!text) return fallback;
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

export function findAccountByUsername(username) {
  return db
    .prepare("SELECT * FROM accounts WHERE username = ? COLLATE NOCASE")
    .get(username);
}

export function findAccountById(id) {
  return db.prepare("SELECT * FROM accounts WHERE id = ?").get(id);
}

export function createAccount(username, passwordHash) {
  const result = db
    .prepare("INSERT INTO accounts (username, password_hash) VALUES (?, ?)")
    .run(username, passwordHash);
  return findAccountById(Number(result.lastInsertRowid));
}

export function touchLogin(accountId) {
  db.prepare("UPDATE accounts SET last_login = datetime('now') WHERE id = ?").run(
    accountId,
  );
}

export function activeBan(accountId) {
  return db
    .prepare(
      `SELECT * FROM bans
       WHERE account_id = ?
         AND (expires_at IS NULL OR expires_at > datetime('now'))
       ORDER BY id DESC LIMIT 1`,
    )
    .get(accountId);
}

export function characterSummary(row) {
  return {
    id: row.id,
    name: row.name,
    class: row.class,
    level: row.level,
    xp: row.xp,
    gold: row.gold,
    current_stage: row.current_stage,
    unlocked_stage: row.unlocked_stage,
    play_time: row.play_time,
    updated_at: row.updated_at,
  };
}

export function characterFull(row) {
  return {
    ...characterSummary(row),
    hp: row.hp,
    mp: row.mp,
    skill_points: row.skill_points,
    special_skill_points: row.special_skill_points,
    inventory: parseJson(row.inventory, []),
    equipment: parseJson(row.equipment, {}),
    attributes: parseJson(row.attributes, {}),
    skills: parseJson(row.skills, {}),
    quests: parseJson(row.quests, {}),
    data: parseJson(row.data, {}),
  };
}

export function listCharacters(accountId) {
  return db
    .prepare("SELECT * FROM characters WHERE account_id = ? ORDER BY id")
    .all(accountId);
}

export function findCharacter(accountId, characterId) {
  return db
    .prepare("SELECT * FROM characters WHERE id = ? AND account_id = ?")
    .get(characterId, accountId);
}

export function findCharacterByName(name) {
  return db
    .prepare("SELECT * FROM characters WHERE name = ? COLLATE NOCASE")
    .get(name);
}

export function insertCharacter(accountId, summary) {
  const result = db
    .prepare(
      `INSERT INTO characters
        (account_id, name, class, level, xp, gold, current_stage,
         unlocked_stage, hp, mp, skill_points, special_skill_points,
         play_time, inventory, equipment, attributes, skills, quests, data)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      accountId,
      summary.name,
      summary.class,
      summary.level,
      summary.xp,
      summary.gold,
      summary.current_stage,
      summary.unlocked_stage,
      summary.hp,
      summary.mp,
      summary.skill_points,
      summary.special_skill_points,
      summary.play_time,
      JSON.stringify(summary.inventory || []),
      JSON.stringify(summary.equipment || {}),
      JSON.stringify(summary.attributes || {}),
      JSON.stringify(summary.skills || {}),
      JSON.stringify(summary.quests || {}),
      JSON.stringify(summary.data || {}),
    );
  return findCharacter(accountId, Number(result.lastInsertRowid));
}

/**
 * Removes a character that belongs to the account.
 * @returns {boolean} true when a row was deleted
 */
export function deleteCharacter(accountId, characterId) {
  const result = db
    .prepare("DELETE FROM characters WHERE id = ? AND account_id = ?")
    .run(characterId, accountId);
  return Number(result.changes) > 0;
}

export function updateCharacter(accountId, characterId, summary) {
  db.prepare(
    `UPDATE characters SET
       name = ?, class = ?, level = ?, xp = ?, gold = ?,
       current_stage = ?, unlocked_stage = ?, hp = ?, mp = ?,
       skill_points = ?, special_skill_points = ?, play_time = ?,
       inventory = ?, equipment = ?, attributes = ?, skills = ?,
       quests = ?, data = ?, updated_at = datetime('now')
     WHERE id = ? AND account_id = ?`,
  ).run(
    summary.name,
    summary.class,
    summary.level,
    summary.xp,
    summary.gold,
    summary.current_stage,
    summary.unlocked_stage,
    summary.hp,
    summary.mp,
    summary.skill_points,
    summary.special_skill_points,
    summary.play_time,
    JSON.stringify(summary.inventory || []),
    JSON.stringify(summary.equipment || {}),
    JSON.stringify(summary.attributes || {}),
    JSON.stringify(summary.skills || {}),
    JSON.stringify(summary.quests || {}),
    JSON.stringify(summary.data || {}),
    characterId,
    accountId,
  );
  return findCharacter(accountId, characterId);
}

// ---------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------

export function sendFriendRequest(requesterId, addresseeId) {
  db.prepare(`
    INSERT INTO friends (requester_id, addressee_id, status, created_at, updated_at)
    VALUES (?, ?, 'pending', datetime('now'), datetime('now'))
    ON CONFLICT(requester_id, addressee_id) DO UPDATE SET status = 'pending', updated_at = datetime('now')
  `).run(requesterId, addresseeId);
  return db.prepare(`SELECT * FROM friends WHERE requester_id = ? AND addressee_id = ?`).get(requesterId, addresseeId);
}

export function respondFriendRequest(requesterId, addresseeId, accept) {
  if (accept) {
    db.prepare(
      `UPDATE friends SET status = 'accepted', updated_at = datetime('now') WHERE requester_id = ? AND addressee_id = ?`
    ).run(requesterId, addresseeId);
    return db.prepare(`SELECT * FROM friends WHERE requester_id = ? AND addressee_id = ?`).get(requesterId, addresseeId);
  } else {
    db.prepare(
      `DELETE FROM friends WHERE requester_id = ? AND addressee_id = ?`
    ).run(requesterId, addresseeId);
    return null;
  }
}

export function listFriends(accountId) {
  return db.prepare(`
    SELECT a.id, a.username,
      (SELECT name FROM characters WHERE account_id = a.id ORDER BY updated_at DESC, id DESC LIMIT 1) as character_name,
      CASE WHEN f.requester_id = ? THEN 'sent' ELSE 'received' END as direction,
      f.status
    FROM friends f
    JOIN accounts a ON a.id = CASE WHEN f.requester_id = ? THEN f.addressee_id ELSE f.requester_id END
    WHERE (f.requester_id = ? OR f.addressee_id = ?) AND f.status = 'accepted'
  `).all(accountId, accountId, accountId, accountId);
}

export function listPendingRequests(accountId) {
  return db.prepare(`
    SELECT a.id, a.username,
      (SELECT name FROM characters WHERE account_id = a.id ORDER BY updated_at DESC, id DESC LIMIT 1) as character_name,
      f.created_at
    FROM friends f
    JOIN accounts a ON a.id = f.requester_id
    WHERE f.addressee_id = ? AND f.status = 'pending'
  `).all(accountId);
}

export function listSentRequests(accountId) {
  return db.prepare(`
    SELECT a.id, a.username,
      (SELECT name FROM characters WHERE account_id = a.id ORDER BY updated_at DESC, id DESC LIMIT 1) as character_name,
      f.created_at
    FROM friends f
    JOIN accounts a ON a.id = f.addressee_id
    WHERE f.requester_id = ? AND f.status = 'pending'
  `).all(accountId);
}

export function removeFriend(accountId, otherAccountId) {
  db.prepare(`
    DELETE FROM friends 
    WHERE (requester_id = ? AND addressee_id = ?) OR (requester_id = ? AND addressee_id = ?)
  `).run(accountId, otherAccountId, otherAccountId, accountId);
}
