import {
  CLASSES,
  EQUIPMENT_SLOTS,
  GOLD_PER_SECOND,
  GOLD_WINDOW_SECONDS,
  MAX_GOLD_GAIN,
  MAX_INVENTORY,
  MAX_SAVE_BYTES,
} from "./config.js";
import { itemCatalog, skillCatalog } from "./db.js";

const USERNAME_RE = /^[A-Za-z0-9_]{3,20}$/;
const CHARACTER_NAME_RE = /^[A-Za-z0-9 _.-]{2,20}$/;

/** Checks a username on its own, without a password. */
export function validateUsername(username) {
  if (typeof username !== "string" || !USERNAME_RE.test(username.trim())) {
    return "Username must be 3-20 letters, numbers or underscores.";
  }
  return null;
}

export function validateCredentials(username, password) {
  const usernameProblem = validateUsername(username);
  if (usernameProblem) return usernameProblem;
  if (typeof password !== "string" || password.length < 6) {
    return "Password must be at least 6 characters.";
  }
  if (password.length > 72) {
    return "Password must be 72 characters or fewer.";
  }
  return null;
}

export function validateCharacterName(name) {
  if (typeof name !== "string" || !CHARACTER_NAME_RE.test(name.trim())) {
    return "Character name must be 2-20 letters, numbers, spaces, dots, dashes or underscores.";
  }
  return null;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * What one item is worth when it is sold, mirroring the client rule: the
 * wiki sell price when there is one, otherwise 35% of the shop price.
 */
function itemSellValue(name) {
  const item = itemCatalog.get(name);
  if (!item) return 0;
  const sell = Number(item.sell) || 0;
  if (sell > 0) return sell;
  return Math.max(1, Math.floor((Number(item.price) || 0) * 0.35));
}

/**
 * What the items that left the inventory since the previous save are worth.
 * Selling items is the only way to add a large amount of gold in one go, so
 * the gold-gain cap counts it as explained income.
 */
export function soldItemValue(previousInventory, nextInventory) {
  const after = new Map();
  for (const entry of Array.isArray(nextInventory) ? nextInventory : []) {
    if (!isPlainObject(entry)) continue;
    const name = String(entry.name ?? "");
    after.set(name, (after.get(name) || 0) + (Number(entry.qty) || 0));
  }
  let value = 0;
  for (const entry of Array.isArray(previousInventory) ? previousInventory : []) {
    if (!isPlainObject(entry)) continue;
    const name = String(entry.name ?? "");
    const left = (Number(entry.qty) || 0) - (after.get(name) || 0);
    if (left > 0) value += left * itemSellValue(name);
  }
  return value;
}

function isInt(value) {
  return typeof value === "number" && Number.isInteger(value);
}

function inRange(value, min, max) {
  return isInt(value) && value >= min && value <= max;
}

function validateInventory(inventory) {
  if (!Array.isArray(inventory)) return "inventory must be a list.";
  if (inventory.length > MAX_INVENTORY) {
    return `inventory may hold at most ${MAX_INVENTORY} entries.`;
  }
  let totalQty = 0;
  for (const entry of inventory) {
    if (!isPlainObject(entry)) return "inventory entries must be objects.";
    const name = entry.name;
    if (typeof name !== "string" || !itemCatalog.has(name)) {
      return `Unknown item in inventory: ${String(name)}`;
    }
    if (!inRange(entry.qty, 1, 9999)) return `Invalid quantity for ${name}.`;
    totalQty += entry.qty;
    if (entry.locked !== undefined && typeof entry.locked !== "boolean") {
      return `Invalid locked flag for ${name}.`;
    }
  }
  if (totalQty > 100_000) return "Inventory quantity is implausibly large.";
  return null;
}

function validateEquipment(equipment) {
  if (!isPlainObject(equipment)) return "equipment must be an object.";
  for (const [slot, item] of Object.entries(equipment)) {
    if (!EQUIPMENT_SLOTS.includes(slot)) {
      return `Unknown equipment slot: ${slot}`;
    }
    if (typeof item !== "string") return `Invalid item in ${slot}.`;
    if (item !== "" && !itemCatalog.has(item)) {
      return `Unknown equipped item in ${slot}: ${item}`;
    }
  }
  return null;
}

function validateAttributes(attributes) {
  if (!isPlainObject(attributes)) return "attributes must be an object.";
  for (const [key, value] of Object.entries(attributes)) {
    if (!inRange(value, 0, 1_000_000)) {
      return `Invalid attribute value for ${key}.`;
    }
  }
  return null;
}

function validateSkills(skills) {
  if (!isPlainObject(skills)) return "skills must be an object.";
  for (const [name, level] of Object.entries(skills)) {
    if (skillCatalog.size > 0 && !skillCatalog.has(name)) {
      return `Unknown skill: ${name}`;
    }
    if (!inRange(level, 0, 1000)) return `Invalid level for skill ${name}.`;
  }
  return null;
}

function validateQuests(quests) {
  if (!isPlainObject(quests)) return "quests must be an object.";
  return null;
}

/**
 * Validates a full GameState save payload and converts it into the
 * denormalized character row the database stores.
 *
 * @param {object} data raw save data from the client
 * @param {object} options
 * @param {number} [options.previousGold] gold currently stored on the server
 * @param {boolean} [options.isCreate] skip the gold-gain cap on first import
 * @param {Array} [options.previousInventory] inventory of the stored save
 * @param {number} [options.elapsedSeconds] seconds since the stored save
 * @returns {{error: string}|{summary: object}}
 */
export function validateCharacterData(
  data,
  {
    previousGold = 0,
    isCreate = false,
    previousInventory = [],
    elapsedSeconds = 0,
  } = {},
) {
  if (!isPlainObject(data)) return { error: "data must be an object." };

  let encoded;
  try {
    encoded = JSON.stringify(data);
  } catch {
    return { error: "data is not serializable." };
  }
  if (Buffer.byteLength(encoded, "utf8") > MAX_SAVE_BYTES) {
    return { error: "Save data is too large." };
  }

  const playerName = String(data.player_name ?? "");
  if (validateCharacterName(playerName)) {
    return { error: "data.player_name is invalid." };
  }
  const playerClass = String(data.player_class ?? "Warrior");
  if (!CLASSES.includes(playerClass)) {
    return { error: "data.player_class is invalid." };
  }

  if (!inRange(data.level, 1, 1000)) return { error: "Invalid level." };
  if (!inRange(data.xp, 0, 1_000_000_000_000)) return { error: "Invalid xp." };
  if (!inRange(data.gold, 0, 1_000_000_000_000)) return { error: "Invalid gold." };
  if (!inRange(data.current_stage, 1, 100_000)) {
    return { error: "Invalid current_stage." };
  }
  if (!inRange(data.unlocked_stage, 1, 100_000)) {
    return { error: "Invalid unlocked_stage." };
  }
  if (data.unlocked_stage < data.current_stage) {
    return { error: "unlocked_stage cannot trail current_stage." };
  }
  if (!inRange(data.skill_points, 0, 1_000_000)) {
    return { error: "Invalid skill_points." };
  }
  if (!inRange(data.special_skill_points, 0, 1_000_000)) {
    return { error: "Invalid special_skill_points." };
  }
  if (!inRange(data.current_hp, 0, 1_000_000_000)) {
    return { error: "Invalid current_hp." };
  }
  if (!inRange(data.current_mp, 0, 1_000_000_000)) {
    return { error: "Invalid current_mp." };
  }
  if (
    typeof data.play_time !== "number" ||
    !Number.isFinite(data.play_time) ||
    data.play_time < 0 ||
    data.play_time > 1_000_000_000
  ) {
    return { error: "Invalid play_time." };
  }

  for (const check of [
    validateInventory(data.inventory),
    validateEquipment(data.equipment),
    validateAttributes(data.attributes),
    validateSkills(data.skills),
    validateQuests(data.quests),
  ]) {
    if (check) return { error: check };
  }

  if (!isCreate) {
    // Gold is explained by the time that passed since the last save (monster
    // kills) plus the value of the items that were sold. A flat cap would
    // reject a normal save once the monsters are worth more than the cap.
    const sold = soldItemValue(previousInventory, data.inventory);
    const seconds = Math.min(
      Math.max(0, Number(elapsedSeconds) || 0),
      GOLD_WINDOW_SECONDS,
    );
    const allowance = Math.max(
      MAX_GOLD_GAIN,
      sold + seconds * GOLD_PER_SECOND,
    );
    const gain = data.gold - previousGold;
    if (gain > allowance) {
      return {
        error: `Gold gain of ${gain} exceeds the ${allowance} cap for one save.`,
      };
    }
  }

  return {
    summary: {
      name: playerName,
      class: playerClass,
      level: data.level,
      xp: data.xp,
      gold: data.gold,
      current_stage: data.current_stage,
      unlocked_stage: data.unlocked_stage,
      hp: data.current_hp,
      mp: data.current_mp,
      skill_points: data.skill_points,
      special_skill_points: data.special_skill_points,
      play_time: data.play_time,
      inventory: data.inventory,
      equipment: data.equipment,
      attributes: data.attributes,
      skills: data.skills,
      quests: data.quests,
      data,
    },
  };
}

/** Minimal fresh character used when a client creates one without a save. */
export function defaultCharacterData(name, playerClass) {
  return {
    version: 1,
    player_name: name,
    player_class: playerClass,
    level: 1,
    xp: 0,
    gold: 0,
    current_hp: 100,
    current_mp: 50,
    current_stage: 1,
    unlocked_stage: 1,
    bonus_hp: 0,
    bonus_mp: 0,
    skill_points: 3,
    special_skill_points: 1,
    camera_zoom: 1.0,
    show_fps: false,
    play_time: 0.0,
    inventory: [],
    equipment: Object.fromEntries(EQUIPMENT_SLOTS.map((slot) => [slot, ""])),
    attributes: {
      strength: 1,
      power: 1,
      range: 1,
      magic: 1,
      artillery: 1,
      defense: 1,
      dexterity: 1,
      luck: 1,
    },
    skills: {},
    quests: {},
  };
}
