import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

export const SERVER_ROOT = path.resolve(here, "..");
export const PROJECT_ROOT = path.resolve(SERVER_ROOT, "..");

export const DATA_DIR =
  process.env.EMBERFALL_DATA_DIR || path.join(SERVER_ROOT, "data");
export const DB_PATH =
  process.env.EMBERFALL_DB || path.join(DATA_DIR, "emberfall.sqlite");
export const GAME_DATA_DIR = path.join(SERVER_ROOT, "game_data");

export const ITEMS_PATH =
  process.env.EMBERFALL_ITEMS ||
  path.join(GAME_DATA_DIR, "items.json");
export const MONSTERS_PATH =
  process.env.EMBERFALL_MONSTERS ||
  path.join(GAME_DATA_DIR, "monsters.json");
export const SKILLS_PATH =
  process.env.EMBERFALL_SKILLS ||
  path.join(GAME_DATA_DIR, "skills.json");

/** Directory that database snapshots are written to. */
export const BACKUP_DIR =
  process.env.EMBERFALL_BACKUP_DIR || path.join(DATA_DIR, "backups");

/** How many snapshots to keep when pruning. */
export const BACKUP_KEEP = Number.parseInt(
  process.env.EMBERFALL_BACKUP_KEEP || "10",
  10,
);

/**
 * Stable fingerprint of the database file path.
 *
 * The health endpoint reports this so the admin CLI can tell whether a running
 * server is using the same database file it is about to replace, without
 * disclosing the path itself.
 */
export function dbFingerprint() {
  return crypto
    .createHash("sha256")
    .update(path.resolve(DB_PATH))
    .digest("hex")
    .slice(0, 16);
}

export const HOST = process.env.HOST || "0.0.0.0";
export const PORT = Number.parseInt(process.env.PORT || "7575", 10);

/**
 * Port the server listens on for discovery requests, so a phone or an
 * emulator can find it without an address being typed in.
 */
export const DISCOVERY_PORT = Number.parseInt(
  process.env.EMBERFALL_DISCOVERY_PORT || "7576",
  10,
);
export const TOKEN_TTL = process.env.EMBERFALL_TOKEN_TTL || "7d";

/** A single save may not add more than this much gold (anti-cheat). */
export const MAX_GOLD_GAIN = Number.parseInt(
  process.env.EMBERFALL_MAX_GOLD_GAIN || "100000",
  10,
);

/**
 * Gold a player may earn per second of play (anti-cheat allowance).
 * The most valuable monsters are worth 20,000, which is 60,000 gold after
 * the multiplier, so this allows a few kills per second.
 */
export const GOLD_PER_SECOND = Number.parseInt(
  process.env.EMBERFALL_GOLD_PER_SECOND || "250000",
  10,
);

/**
 * How many seconds between two saves count towards the gold allowance.
 * Without this a save an hour after the last one would be allowed to add an
 * hour worth of gold, which no cheat needs.
 */
export const GOLD_WINDOW_SECONDS = Number.parseInt(
  process.env.EMBERFALL_GOLD_WINDOW_SECONDS || "600",
  10,
);

export const MAX_SAVE_BYTES = 512 * 1024;
export const MAX_INVENTORY = 40;

/** Maximum number of characters a single account may own. */
export const MAX_CHARACTERS = Number.parseInt(
  process.env.EMBERFALL_MAX_CHARACTERS || "10",
  10,
);

export const EQUIPMENT_SLOTS = [
  "weapon",
  "helmet",
  "armor",
  "legs",
  "boots",
  "shield",
  "accessory",
  "pet_helmet",
];

export const CLASSES = ["Warrior", "Archer", "Mage", "Cowboy"];

/**
 * JWT secret: use the env var when available, otherwise generate one once and
 * keep it in the data directory so sessions survive server restarts.
 */
export function loadJwtSecret() {
  if (process.env.EMBERFALL_JWT_SECRET) {
    return process.env.EMBERFALL_JWT_SECRET;
  }
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const secretPath = path.join(DATA_DIR, "jwt_secret.txt");
  if (fs.existsSync(secretPath)) {
    return fs.readFileSync(secretPath, "utf8").trim();
  }
  const secret = crypto.randomBytes(48).toString("hex");
  fs.writeFileSync(secretPath, secret, { mode: 0o600 });
  return secret;
}

/**
 * Key for the local admin dashboard. Generated once and kept next to the JWT
 * secret so it survives restarts.
 */
export function loadAdminKey() {
  if (process.env.EMBERFALL_ADMIN_KEY) {
    return process.env.EMBERFALL_ADMIN_KEY;
  }
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const keyPath = path.join(DATA_DIR, "admin_key.txt");
  if (fs.existsSync(keyPath)) {
    return fs.readFileSync(keyPath, "utf8").trim();
  }
  const key = crypto.randomBytes(16).toString("hex");
  fs.writeFileSync(keyPath, key, { mode: 0o600 });
  return key;
}

/** The admin dashboard is served unless this is turned off. */
export const ADMIN_ENABLED = process.env.EMBERFALL_ADMIN !== "0";

/** The admin key the dashboard has to present. */
export const ADMIN_KEY = loadAdminKey();

/** Location of the admin dashboard page. */
export const ADMIN_HTML_PATH = path.join(SERVER_ROOT, "public", "admin.html");
