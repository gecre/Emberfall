extends Node
## GameState
## Owns the player's persistent progression: level, XP, gold, inventory,
## equipment, attributes and the current stage.

signal stats_changed
signal inventory_changed
signal equipment_changed
signal gold_changed
signal leveled_up(new_level)
signal stage_changed(number)
signal player_died
signal message(text)
signal camera_zoom_changed(zoom)

const SAVE_PATH := "user://emberfall_save.json"
## Holds a cloud save that could not be delivered, so it can be replayed on
## the next successful login instead of being lost.
const PENDING_SAVE_PATH := "user://emberfall_pending_save.json"
const MAX_INVENTORY := 40
const XP_MULTIPLIER := 2.0
const GOLD_MULTIPLIER := 3.0
const DEATH_GOLD_LOSS := 0.5

const EQUIPMENT_SLOTS := ["weapon", "helmet", "armor", "legs", "boots", "shield", "accessory", "pet_helmet"]
const CLASSES := ["Warrior", "Archer", "Mage", "Cowboy"]
const ATTRIBUTE_NAMES := ["strength", "power", "range", "magic", "artillery", "defense", "dexterity", "luck"]

## Active save file. Tools/tests can point this elsewhere to avoid touching
## the player's real save.
var save_path := SAVE_PATH
## Where failed cloud saves are parked for a later retry.
var pending_save_path := PENDING_SAVE_PATH

## When true, saves are mirrored to the account server through `Api`.
## Local saves are still written so the game keeps working offline.
var online_mode := false
## Id of the character the current session plays on the server.
var online_character_id := 0

var _cloud_save_timer: Timer = null
var _pending_cloud_data: Dictionary = {}
var _in_flight_cloud_data: Dictionary = {}
var _cloud_save_warned := false

var player_name := "Hero"
var player_class := "Warrior"
var level := 1
var xp := 0
var gold := 0
var current_hp := 100
var current_mp := 50
var current_stage := 1
var unlocked_stage := 1
var entry_direction := 0  # -1 = arrived via a back portal, 1 = via a forward portal, 0 = stage start
var bonus_hp := 0
var bonus_mp := 0
var skill_points := 3
var special_skill_points := 1
var camera_zoom := 1.0
var show_fps := false

var inventory: Array = []
var equipment: Dictionary = {}
## Timestamp (ms) of the last "Inventory is full!" toast. Throttles repeated
## full-inventory warnings to one every ~2 seconds so the message never spams.
var _last_full_message_tick := 0
var attributes: Dictionary = {}
var skills: Dictionary = {}
## Tracks remaining cooldown seconds per skill name. Updated each frame.
var skill_cooldowns: Dictionary = {}
var active_skills: Dictionary = {}  # skill_name -> remaining_seconds (for timed buffs like Rage)
var play_time := 0.0

## Quest progress: quest_name -> {stage: int, completed: bool, ...}
var quests: Dictionary = {}


func _ready() -> void:
	_init_new()
	_cloud_save_timer = Timer.new()
	_cloud_save_timer.one_shot = true
	_cloud_save_timer.wait_time = 2.0
	_cloud_save_timer.timeout.connect(_flush_cloud_save)
	add_child(_cloud_save_timer)
	Api.character_saved.connect(_on_cloud_save_ok)
	Api.save_failed.connect(_on_cloud_save_failed)


func starter_weapon_for(cname: String) -> String:
	match cname:
		"Archer":
			return "Slingshot"
		"Mage":
			return "Basic Wand"
		"Cowboy":
			return "Airsoft Gun"
		_:
			return "Stick"


func _default_attributes() -> Dictionary:
	var result := {}
	for stat_name in ATTRIBUTE_NAMES:
		result[stat_name] = 1
	return result


func _init_new(chosen_class: String = "Warrior") -> void:
	player_name = "Hero"
	player_class = chosen_class if CLASSES.has(chosen_class) else "Warrior"
	level = 1
	xp = 0
	gold = 0
	current_stage = 1
	unlocked_stage = 1
	entry_direction = 0
	bonus_hp = 0
	bonus_mp = 0
	skill_points = 3
	special_skill_points = 1
	play_time = 0.0
	inventory = []
	equipment = {}
	for slot in EQUIPMENT_SLOTS:
		equipment[slot] = ""
	attributes = _default_attributes()
	skills = {}

	var starter_wep := starter_weapon_for(player_class)
	add_item(starter_wep, 1, true)
	add_item("Apple", 3, true)
	equip(starter_wep)

	var stats_now := stats()
	current_hp = stats_now["max_hp"]
	current_mp = stats_now["max_mp"]


# ---------------------------------------------------------------------------
# Derived stats
# ---------------------------------------------------------------------------
func stats() -> Dictionary:
	var str_val := float(attributes.get("strength", attributes.get("power", 1)))
	var pow_val := float(attributes.get("power", attributes.get("strength", 1)))
	var result := {
		"max_hp": 100 + (level - 1) * 12 + bonus_hp,
		"max_mp": 50 + (level - 1) * 6 + bonus_mp,
		"damage_min": 2.0,
		"damage_max": 4.0,
		"defense": float(attributes.get("defense", 1)),
		"power": pow_val,
		"magic": float(attributes.get("magic", 1)),
		"range": float(attributes.get("range", 1)),
		"artillery": float(attributes.get("artillery", 1)),
		"luck": float(attributes.get("luck", 1)),
		"strength": str_val,
		"dexterity": float(attributes.get("dexterity", 1)),
		"reach": 1.6,
		"crit_chance": 0.05,
		"rpm": 0.0,
		"two_handed": false,
		"weapon_name": "",
		"weapon_type": "melee",
		"player_class": player_class,
		"skill_points": skill_points,
		"special_skill_points": special_skill_points,
	}

	for slot in equipment.keys():
		var item_name := str(equipment[slot])
		if item_name == "":
			continue
		var data := GameData.item(item_name)
		if data.is_empty():
			continue
		var def_val := float(data.get("defense", 0))
		if slot == "shield":
			var shield_mastery := float(skills.get("Shield Mastery", 0))
			if shield_mastery > 0.0:
				def_val *= (1.0 + 0.02 * shield_mastery)
		result["defense"] += def_val
		result["power"] += float(data.get("power", 0))
		result["magic"] += float(data.get("magic", 0))
		result["range"] += float(data.get("range", 0))
		result["artillery"] += float(data.get("artillery", 0))
		result["luck"] += float(data.get("luck", 0))
		result["strength"] += float(data.get("strength", 0))
		result["dexterity"] += float(data.get("dexterity", 0))
		result["max_hp"] += int(data.get("health", 0))
		result["max_mp"] += int(data.get("mana", data.get("mp", 0)))
		result["speed_bonus"] = float(result.get("speed_bonus", 0.0)) + float(data.get("speed", 0.0))
		if slot == "weapon":
			result["damage_min"] = maxf(1.0, float(data.get("damage_min", 2.0)))
			result["damage_max"] = maxf(result["damage_min"], float(data.get("damage_max", 4.0)))
			result["reach"] = maxf(1.6, float(data.get("reach", 1.6)))
			result["rpm"] = float(data.get("rpm", 0))
			result["two_handed"] = bool(data.get("two_handed", false))
			result["weapon_name"] = item_name
			result["weapon_type"] = str(data.get("type", "melee"))
		else:
			result["damage_min"] += float(data.get("damage_min", 0.0))
			result["damage_max"] += float(data.get("damage_max", 0.0))
			result["reach"] += float(data.get("reach", 0.0))

	var stat_damage_bonus := 0.0
	match result["weapon_type"]:
		"ranged":
			stat_damage_bonus = result["range"] * 0.7 + result["dexterity"] * 0.4
		"magic":
			stat_damage_bonus = result["magic"] * 0.8
		"artillery":
			stat_damage_bonus = result["artillery"] * 0.75
		_:
			stat_damage_bonus = result["power"] * 0.6 + result["strength"] * 0.5

	result["damage_bonus"] = stat_damage_bonus
	result["damage_min"] += stat_damage_bonus
	result["damage_max"] += stat_damage_bonus

	var power_attack_lvl := float(skills.get("Power Attack", 0))
	if power_attack_lvl > 0.0:
		var p_mult := 1.0 + power_attack_lvl * 0.02
		result["damage_min"] *= p_mult
		result["damage_max"] *= p_mult

	match result["weapon_type"]:
		"magic":
			result["reach"] += float(skills.get("Magic Distance Increase", 0)) * 0.2
		"artillery":
			result["reach"] += float(skills.get("Bullet Distance Increase", 0)) * 0.2
		"ranged":
			result["reach"] += float(skills.get("Bullet Distance Increase", 0)) * 0.2
		_:
			result["reach"] += float(skills.get("Multi-Attack Distance", 0)) * 0.2

	var speed_dash_lvl := float(skills.get("Speed Dash", 0))
	result["speed"] = 230.0 + float(result["dexterity"]) * 0.8 + float(result.get("speed_bonus", 0.0)) + speed_dash_lvl * 14.0

	var jump_lvl := float(skills.get("Increased Jump Height", 0))
	result["jump_velocity"] = -560.0 - jump_lvl * 24.0

	var avoid_lvl := float(skills.get("Avoidance", 0))
	result["avoidance"] = clampf(avoid_lvl * 0.005, 0.0, 0.75)

	var block_lvl := float(skills.get("Block", 0))
	var block_reduction := 0.0
	if block_lvl > 0.0:
		block_reduction = clampf(0.51 + block_lvl * 0.01, 0.0, 0.80)
		if str(equipment.get("shield", "")) != "":
			block_reduction = min(block_reduction + 0.10, 0.90)
	result["block_reduction"] = block_reduction

	var knockback_bonus := 0.0
	match result["weapon_type"]:
		"ranged":
			knockback_bonus = float(skills.get("Arrow Knockback Bonus", 0)) * 0.05
		"artillery":
			knockback_bonus = float(skills.get("Bullet Knockback", 0)) * 0.05
		_:
			knockback_bonus = float(skills.get("Melee Knockback", 0)) * 0.05
	result["knockback_mult"] = 1.0 + knockback_bonus

	var crit_bonus: float = float(skills.get("Increased Critical Damage", 0)) * 0.12
	result["crit_mult"] = 1.75 + crit_bonus
	result["crit_chance"] = clampf(0.05 + float(result["luck"]) * 0.005 + float(result["dexterity"]) * 0.002, 0.0, 0.75)
	return result


func xp_to_next() -> int:
	return int(round(60.0 * pow(float(level), 1.55)))


func xp_progress() -> float:
	var needed := xp_to_next()
	if needed <= 0:
		return 0.0
	return clampf(float(xp) / float(needed), 0.0, 1.0)


# ---------------------------------------------------------------------------
# Progression
# ---------------------------------------------------------------------------
func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	xp += amount
	var guard := 0
	while xp >= xp_to_next() and guard < 200:
		xp -= xp_to_next()
		level += 1
		skill_points += 3
		special_skill_points += 1
		for stat_name in ATTRIBUTE_NAMES:
			attributes[stat_name] = int(attributes.get(stat_name, 1)) + 1
		guard += 1
		current_hp = stats()["max_hp"]
		current_mp = stats()["max_mp"]
		leveled_up.emit(level)
	stats_changed.emit()
	save_game()


func set_class(new_class: String) -> void:
	if not CLASSES.has(new_class):
		return
	player_class = new_class
	var current_wep := str(equipment.get("weapon", ""))
	if current_wep == "" or current_wep in ["Stick", "Slingshot", "Basic Wand", "Airsoft Gun"]:
		var starter := starter_weapon_for(player_class)
		equipment["weapon"] = ""
		add_item(starter, 1, true)
		equip(starter)
	stats_changed.emit()
	message.emit("Class changed to %s!" % player_class)


func upgrade_skill(skill_name: String) -> bool:
	var sdata := GameData.skill(skill_name)
	if sdata.is_empty():
		return false
	var cost := int(sdata.get("points_required", 1))
	if special_skill_points < cost:
		message.emit("Need %d special skill points!" % cost)
		return false
	var max_lvl_str := str(sdata.get("max_level", "Infinite"))
	var cur_lvl := int(skills.get(skill_name, 0))
	if max_lvl_str != "Infinite" and cur_lvl >= max_lvl_str.to_int():
		message.emit("Skill is already at max level!")
		return false
	special_skill_points -= cost
	skills[skill_name] = cur_lvl + 1
	match skill_name:
		"Expert Warrior":
			attributes["power"] = int(attributes.get("power", 1)) + 1
			attributes["strength"] = int(attributes.get("strength", 1)) + 1
		"Expert Archer":
			attributes["range"] = int(attributes.get("range", 1)) + 1
		"Expert Wizard":
			attributes["magic"] = int(attributes.get("magic", 1)) + 1
		"Expert Cowboy":
			attributes["artillery"] = int(attributes.get("artillery", 1)) + 1
		"Rigorous Training":
			attributes["strength"] = int(attributes.get("strength", 1)) + 1
			attributes["power"] = int(attributes.get("power", 1)) + 1
			attributes["range"] = int(attributes.get("range", 1)) + 1
			attributes["magic"] = int(attributes.get("magic", 1)) + 1
			attributes["dexterity"] = int(attributes.get("dexterity", 1)) + 1
			bonus_hp += 10
			bonus_mp += 10
			current_hp += 10
			current_mp += 10
	stats_changed.emit()
	save_game()
	message.emit("%s upgraded to Lv %d!" % [skill_name, skills[skill_name]])
	return true


## Returns the mana cost of a skill from its data (0 for passive skills).
func get_skill_mana_cost(skill_name: String) -> int:
	var sdata := GameData.skill(skill_name)
	return int(sdata.get("mana_cost", 0))


## Returns the cooldown duration in seconds for a skill from its data.
func get_skill_cooldown(skill_name: String) -> float:
	var sdata := GameData.skill(skill_name)
	return float(sdata.get("cooldown", 0))


## Returns true if the skill can be activated right now (enough MP and not on cooldown).
func can_activate_skill(skill_name: String) -> bool:
	var sdata := GameData.skill(skill_name)
	if sdata.is_empty():
		return false
	var cur_lvl := int(skills.get(skill_name, 0))
	if cur_lvl <= 0:
		return false
	var cost := get_skill_mana_cost(skill_name)
	if current_mp < cost:
		return false
	var remaining := float(skill_cooldowns.get(skill_name, 0))
	if remaining > 0.0:
		return false
	return true


## Activates a skill: deducts mana and starts its cooldown. Returns true on success.
func activate_skill(skill_name: String) -> bool:
	if not can_activate_skill(skill_name):
		return false
	var cost := get_skill_mana_cost(skill_name)
	var cooldown := get_skill_cooldown(skill_name)
	GameState.current_mp = maxi(0, GameState.current_mp - cost)
	skill_cooldowns[skill_name] = cooldown
	stats_changed.emit()
	message.emit("Used %s (-%d MP)." % [skill_name, cost])
	return true


## Decrements all active skill cooldowns by delta. Call once per frame.
## Does not emit stats_changed; the HUD polls cooldowns directly each frame.
func update_skill_cooldowns(delta: float) -> void:
	if skill_cooldowns.is_empty():
		return
	var to_erase: Array = []
	for key in skill_cooldowns.keys():
		var remaining := float(skill_cooldowns[key]) - delta
		if remaining <= 0.0:
			to_erase.append(key)
		else:
			skill_cooldowns[key] = remaining
	for key in to_erase:
		skill_cooldowns.erase(key)


## Sets a timed active skill (e.g. Rage) with its remaining duration in seconds.
func set_active_skill(skill_name: String, duration: float) -> void:
	if duration <= 0.0:
		active_skills.erase(skill_name)
	else:
		active_skills[skill_name] = duration


## Returns a copy of active skills with remaining seconds (expired ones removed).
func get_active_skills() -> Dictionary:
	var result: Dictionary = {}
	var to_erase: Array = []
	for key in active_skills.keys():
		var remaining := float(active_skills[key])
		if remaining > 0.0:
			result[key] = remaining
		else:
			to_erase.append(key)
	for key in to_erase:
		active_skills.erase(key)
	return result


## Decrements all active skill durations by delta. Call once per frame.
func update_active_skills(delta: float) -> void:
	if active_skills.is_empty():
		return
	var to_erase: Array = []
	for key in active_skills.keys():
		var remaining := float(active_skills[key]) - delta
		if remaining <= 0.0:
			to_erase.append(key)
		else:
			active_skills[key] = remaining
	for key in to_erase:
		active_skills.erase(key)


## Inserts comma thousands separators into an integer, e.g. 1000000 -> "1,000,000".
func format_number(value: int) -> String:
	var digits := str(absi(value))
	var formatted := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		formatted = digits[i] + formatted
		count += 1
		if count % 3 == 0 and i > 0:
			formatted = "," + formatted
	return ("-" if value < 0 else "") + formatted


func add_gold(amount: int) -> void:
	if amount == 0:
		return
	gold = maxi(0, gold + amount)
	gold_changed.emit()
	stats_changed.emit()


func spend_gold(amount: int) -> bool:
	if amount < 0 or gold < amount:
		return false
	gold -= amount
	gold_changed.emit()
	stats_changed.emit()
	return true


func damage(amount: int) -> int:
	if amount <= 0:
		return 0
	current_hp = clampi(current_hp - amount, 0, stats()["max_hp"])
	stats_changed.emit()
	if current_hp <= 0:
		player_died.emit()
	return amount


func heal(amount: int) -> void:
	current_hp = clampi(current_hp + amount, 0, stats()["max_hp"])
	stats_changed.emit()


func restore_mp(amount: int) -> void:
	current_mp = clampi(current_mp + amount, 0, stats()["max_mp"])
	stats_changed.emit()


func set_stage(number: int, arrival_direction: int = 0) -> void:
	current_stage = maxi(1, number)
	entry_direction = clampi(arrival_direction, -1, 1)
	unlocked_stage = maxi(unlocked_stage, current_stage)
	stage_changed.emit(current_stage)
	save_game()


func set_camera_zoom(val: float) -> void:
	camera_zoom = clampf(val, 0.5, 2.0)
	camera_zoom_changed.emit(camera_zoom)


func allocate_stat(stat_name: String) -> bool:
	if skill_points <= 0:
		message.emit("No stat points to spend.")
		return false
	if not attributes.has(stat_name):
		if stat_name == "power":
			attributes["power"] = int(attributes.get("strength", 1))
		elif stat_name == "strength":
			attributes["strength"] = int(attributes.get("power", 1))
		else:
			attributes[stat_name] = 1
	skill_points -= 1
	attributes[stat_name] = int(attributes.get(stat_name, 1)) + 1
	if stat_name == "power":
		attributes["strength"] = attributes["power"]
	elif stat_name == "strength":
		attributes["power"] = attributes["strength"]
	stats_changed.emit()
	save_game()
	return true


func lose_gold_on_death() -> int:
	var lost := int(floor(float(gold) * DEATH_GOLD_LOSS))
	add_gold(-lost)
	return lost


# ---------------------------------------------------------------------------
# Quests
# ---------------------------------------------------------------------------

## Sets quest progress. Called via RPC to sync across peers.
func quest_set(quest_name: String, progress: Variant) -> void:
	quests[quest_name] = progress
	stats_changed.emit()


## Returns quest progress, or null if the quest is not tracked.
func quest_get(quest_name: String) -> Variant:
	return quests.get(quest_name, null)


## Returns true if the quest is marked completed.
func quest_is_completed(quest_name: String) -> bool:
	var q: Variant = quests.get(quest_name, {})
	if q is Dictionary:
		return bool(q.get("completed", false))
	return bool(q)


## Advances a quest stage.
func quest_advance(quest_name: String, stage: int) -> void:
	var q: Variant = quests.get(quest_name, {})
	if not (q is Dictionary):
		q = {}
	q["stage"] = stage
	quests[quest_name] = q
	stats_changed.emit()


## Marks a quest completed.
func quest_complete(quest_name: String) -> void:
	var q: Variant = quests.get(quest_name, {})
	if not (q is Dictionary):
		q = {}
	q["completed"] = true
	quests[quest_name] = q
	stats_changed.emit()
	message.emit("Quest completed: %s!" % quest_name)


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
func _stacks(item_name: String) -> bool:
	var data := GameData.item(item_name)
	var slot := str(data.get("slot", "none"))
	var item_type := str(data.get("type", ""))
	return slot == "consumable" or slot == "material" or item_type in ["fish", "log", "seed"]


func add_item(item_name: String, qty: int = 1, silent: bool = false) -> bool:
	var data := GameData.item(item_name)
	if data.is_empty() or qty <= 0:
		return false

	if _stacks(item_name):
		for entry in inventory:
			if str(entry["name"]) == item_name:
				entry["qty"] = int(entry["qty"]) + qty
				if not silent:
					inventory_changed.emit()
				return true

	if inventory.size() >= MAX_INVENTORY:
		if not silent:
			var now := Time.get_ticks_msec()
			if now - _last_full_message_tick >= 2000:
				_last_full_message_tick = now
				message.emit("Inventory is full!")
		return false

	inventory.append({"name": item_name, "qty": qty, "locked": false})
	if not silent:
		inventory_changed.emit()
	return true


func remove_item(item_name: String, qty: int = 1) -> bool:
	var removed := 0
	for i in range(inventory.size() - 1, -1, -1):
		var entry: Dictionary = inventory[i]
		if str(entry["name"]) != item_name:
			continue
		var take := mini(qty - removed, int(entry["qty"]))
		entry["qty"] = int(entry["qty"]) - take
		removed += take
		if int(entry["qty"]) <= 0:
			inventory.remove_at(i)
		if removed >= qty:
			inventory_changed.emit()
			return true
	return false


func count_item(item_name: String) -> int:
	var total := 0
	for entry in inventory:
		if str(entry["name"]) == item_name:
			total += int(entry["qty"])
	return total


func equipment_slot_for(item_name: String) -> String:
	var data := GameData.item(item_name)
	return str(data.get("slot", "none"))


func equip(item_name: String) -> bool:
	var data := GameData.item(item_name)
	if data.is_empty():
		return false
	var slot := str(data.get("slot", "none"))
	if not EQUIPMENT_SLOTS.has(slot):
		return false
	if count_item(item_name) <= 0:
		return false
	if not remove_item(item_name, 1):
		return false

	var previous := str(equipment.get(slot, ""))
	equipment[slot] = item_name
	if previous != "":
		add_item(previous, 1, true)
	equipment_changed.emit()
	stats_changed.emit()
	return true


func unequip(slot: String) -> bool:
	if not equipment.has(slot):
		return false
	var item_name := str(equipment[slot])
	if item_name == "":
		return false
	if not add_item(item_name, 1, true):
		return false
	equipment[slot] = ""
	equipment_changed.emit()
	stats_changed.emit()
	return true


func use_item(item_name: String) -> void:
	var data := GameData.item(item_name)
	if data.is_empty():
		return
	var slot := str(data.get("slot", "none"))
	if EQUIPMENT_SLOTS.has(slot):
		equip(item_name)
		return
	if slot != "consumable":
		message.emit("You can't use that.")
		return
	if count_item(item_name) <= 0:
		return
	_apply_effect(str(data.get("effect", "")))
	remove_item(item_name, 1)
	message.emit("Used %s" % item_name)


func _apply_effect(effect: String) -> void:
	var hp_regex := RegEx.new()
	hp_regex.compile("(?i)(?:restores?|heals?)\\s*(\\d+)\\s*hp")
	var match_hp := hp_regex.search(effect)
	if match_hp:
		heal(int(match_hp.get_string(1)))

	var mp_regex := RegEx.new()
	mp_regex.compile("(?i)(?:restores?|heals?)\\s*(\\d+)\\s*mp")
	var match_mp := mp_regex.search(effect)
	if match_mp:
		restore_mp(int(match_mp.get_string(1)))

	var attr_regex := RegEx.new()
	attr_regex.compile("(?i)add\\s+(\\d+)\\s+to\\s+(strength|range|magic|artillery|defense|dexterity|luck|health|hp|mp)")
	var match_attr := attr_regex.search(effect)
	if match_attr:
		var amount := int(match_attr.get_string(1))
		var what := match_attr.get_string(2).to_lower()
		match what:
			"health", "hp":
				bonus_hp += amount
				heal(amount)
			"mp":
				bonus_mp += amount
				restore_mp(amount)
			_:
				attributes[what] = int(attributes.get(what, 0)) + amount

	if effect.to_lower().contains("skill point"):
		skill_points += 1
	stats_changed.emit()


# ---------------------------------------------------------------------------
# Shops
# ---------------------------------------------------------------------------
func sell_price(item_name: String) -> int:
	var data := GameData.item(item_name)
	if data.is_empty():
		return 0
	var sell := int(data.get("sell", 0))
	if sell > 0:
		return sell
	return maxi(1, int(float(data.get("price", 0)) * 0.35))


func buy(item_name: String) -> bool:
	var data := GameData.item(item_name)
	if data.is_empty():
		return false
	var price := int(data.get("price", 0))
	if price <= 0:
		message.emit("That item is not for sale.")
		return false
	if gold < price:
		message.emit("Not enough gold (need %s)." % format_number(price))
		return false
	if not add_item(item_name, 1):
		return false
	spend_gold(price)
	message.emit("Bought %s for %s gold." % [item_name, format_number(price)])
	return true


## Removes the item from inventory (1 qty) without giving gold.
## Returns true on success. The caller is responsible for spawning a loot drop.
func drop_item(item_name: String) -> bool:
	if count_item(item_name) <= 0:
		return false
	# Cannot drop currently-equipped items from the inventory list;
	# those live in the equipment dict, not inventory.
	# Locked items cannot be dropped.
	var has_unlocked := false
	for entry in inventory:
		if str(entry["name"]) == item_name and not bool(entry.get("locked", false)):
			has_unlocked = true
			break
	if not has_unlocked:
		message.emit("%s is locked and cannot be dropped." % item_name)
		return false
	var target_idx := -1
	for i in range(inventory.size()):
		var entry: Dictionary = inventory[i]
		if str(entry["name"]) == item_name and not bool(entry.get("locked", false)):
			target_idx = i
			break
	if target_idx < 0:
		return false
	var entry := inventory[target_idx] as Dictionary
	entry["qty"] = int(entry["qty"]) - 1
	if int(entry["qty"]) <= 0:
		inventory.remove_at(target_idx)
	inventory_changed.emit()
	message.emit("Dropped %s" % item_name)
	return true


func sell(item_name: String, qty: int = 1) -> bool:
	if qty <= 0:
		return false
	var total := count_item(item_name)
	var available := 0
	for entry in inventory:
		if str(entry["name"]) == item_name and not bool(entry.get("locked", false)):
			available += int(entry["qty"])
	if total > 0 and available <= 0:
		message.emit("%s is locked and cannot be sold." % item_name)
		return false
	if available <= 0:
		return false
	qty = mini(qty, available)
	var price := sell_price(item_name) * qty
	var removed := 0
	for i in range(inventory.size() - 1, -1, -1):
		var entry: Dictionary = inventory[i]
		if str(entry["name"]) != item_name or bool(entry.get("locked", false)):
			continue
		var take := mini(qty - removed, int(entry["qty"]))
		entry["qty"] = int(entry["qty"]) - take
		removed += take
		if int(entry["qty"]) <= 0:
			inventory.remove_at(i)
		if removed >= qty:
			break
	if removed > 0:
		inventory_changed.emit()
	add_gold(price)
	message.emit("Sold %s x%d for %s gold." % [item_name, removed, format_number(price)])
	return true


# ---------------------------------------------------------------------------
# Save / load
# ---------------------------------------------------------------------------
## Serializes the current character exactly as it is written to disk.
func export_save_data() -> Dictionary:
	return {
		"version": 1,
		"player_name": player_name,
		"player_class": player_class,
		"level": level,
		"xp": xp,
		"gold": gold,
		"current_hp": current_hp,
		"current_mp": current_mp,
		"current_stage": current_stage,
		"unlocked_stage": unlocked_stage,
		"bonus_hp": bonus_hp,
		"bonus_mp": bonus_mp,
		"skill_points": skill_points,
		"special_skill_points": special_skill_points,
		"camera_zoom": camera_zoom,
		"show_fps": show_fps,
		"play_time": play_time,
		"inventory": inventory,
		"equipment": equipment,
		"attributes": attributes,
		"skills": skills,
		"quests": quests,
	}


func save_game() -> void:
	var data := export_save_data()
	_write_local_save(data)
	if online_mode:
		_queue_cloud_save(data)


## Builds the save blob for a brand new character without touching the state
## of the character that is currently loaded.
func default_save_data(character_name: String, character_class: String) -> Dictionary:
	var chosen := character_class if CLASSES.has(character_class) else "Warrior"
	var gear := {}
	for slot in EQUIPMENT_SLOTS:
		gear[slot] = ""
	var starter := starter_weapon_for(chosen)
	gear["weapon"] = starter
	return {
		"version": 1,
		"player_name": character_name,
		"player_class": chosen,
		"level": 1,
		"xp": 0,
		"gold": 0,
		"current_hp": 100,
		"current_mp": 50,
		"current_stage": 1,
		"unlocked_stage": 1,
		"bonus_hp": 0,
		"bonus_mp": 0,
		"skill_points": 3,
		"special_skill_points": 1,
		"camera_zoom": 1.0,
		"show_fps": false,
		"play_time": 0.0,
		"inventory": [
			{"name": starter, "qty": 1, "locked": false},
			{"name": "Apple", "qty": 3, "locked": false},
		],
		"equipment": gear,
		"attributes": _default_attributes(),
		"skills": {},
		"quests": {},
	}


func _write_local_save(data: Dictionary) -> void:
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_error("GameState: could not write save file")
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


## Debounces cloud writes: the first save starts a short timer and later saves
## only replace the pending snapshot, so bursts of XP/gold become one request.
func _queue_cloud_save(data: Dictionary) -> void:
	_pending_cloud_data = data
	if _cloud_save_timer != null and _cloud_save_timer.is_stopped():
		_cloud_save_timer.start()


func _flush_cloud_save() -> void:
	if _pending_cloud_data.is_empty():
		return
	_in_flight_cloud_data = _pending_cloud_data
	_pending_cloud_data = {}
	Api.save_character(_in_flight_cloud_data)


## Pushes any pending snapshot immediately (menu/stage transitions, logout).
func flush_cloud_save() -> void:
	if _cloud_save_timer != null:
		_cloud_save_timer.stop()
	_flush_cloud_save()


func _on_cloud_save_ok(_saved_at: String) -> void:
	_in_flight_cloud_data = {}
	_cloud_save_warned = false
	clear_pending_cloud_save()


func _on_cloud_save_failed(error: String) -> void:
	if not online_mode:
		return
	if not _cloud_save_warned:
		_cloud_save_warned = true
		message.emit("Cloud save failed: %s" % error)
	# Keep the failed snapshot and retry after the network settles.
	if _pending_cloud_data.is_empty() and not _in_flight_cloud_data.is_empty():
		_pending_cloud_data = _in_flight_cloud_data
	# Park the snapshot on disk too: if the game is closed before the retry
	# succeeds the progress is not lost.
	write_pending_cloud_save(_pending_cloud_data)
	_in_flight_cloud_data = {}
	if _cloud_save_timer != null:
		_cloud_save_timer.start(10.0)


## Stores a snapshot that could not be uploaded.
func write_pending_cloud_save(data: Dictionary) -> void:
	if data.is_empty():
		return
	var payload := {
		"character_id": online_character_id if online_character_id > 0 else Api.character_id,
		"username": Api.username,
		"saved_at": Time.get_datetime_string_from_system(),
		"data": data,
	}
	var file := FileAccess.open(pending_save_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()


## Removes the parked snapshot after a successful upload.
func clear_pending_cloud_save() -> void:
	if FileAccess.file_exists(pending_save_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(pending_save_path))


## Returns the parked snapshot, or an empty dictionary when there is none.
func read_pending_cloud_save() -> Dictionary:
	if not FileAccess.file_exists(pending_save_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(pending_save_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


## Sends the parked snapshot again, e.g. after logging back in. The snapshot
## only applies to the character it was taken from.
func replay_pending_cloud_save(character_id: int) -> bool:
	var pending := read_pending_cloud_save()
	if pending.is_empty():
		return false
	var data: Variant = pending.get("data", {})
	if typeof(data) != TYPE_DICTIONARY:
		clear_pending_cloud_save()
		return false
	var owner_id := int(pending.get("character_id", 0))
	if owner_id > 0 and character_id > 0 and owner_id != character_id:
		return false
	if character_id > 0:
		# Make sure the upload targets the character the snapshot came from.
		Api.character_id = character_id
	_in_flight_cloud_data = data as Dictionary
	_pending_cloud_data = {}
	Api.save_character(_in_flight_cloud_data)
	return true


func has_save() -> bool:
	return FileAccess.file_exists(save_path)


func load_game() -> bool:
	if not has_save():
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GameState: invalid save file")
		return false
	return apply_save_data(parsed as Dictionary)


## Applies a save dictionary from either the local file or the cloud.
func apply_save_data(data: Dictionary) -> bool:
	player_name = str(data.get("player_name", "Hero"))
	player_class = str(data.get("player_class", "Warrior"))
	level = maxi(1, int(data.get("level", 1)))
	xp = maxi(0, int(data.get("xp", 0)))
	gold = maxi(0, int(data.get("gold", 0)))
	current_stage = maxi(1, int(data.get("current_stage", 1)))
	unlocked_stage = maxi(current_stage, int(data.get("unlocked_stage", current_stage)))
	entry_direction = 0
	bonus_hp = maxi(0, int(data.get("bonus_hp", 0)))
	bonus_mp = maxi(0, int(data.get("bonus_mp", 0)))
	skill_points = maxi(0, int(data.get("skill_points", 0)))
	special_skill_points = maxi(0, int(data.get("special_skill_points", 0)))
	camera_zoom = clampf(float(data.get("camera_zoom", 1.0)), 0.5, 2.0)
	show_fps = bool(data.get("show_fps", false))
	play_time = float(data.get("play_time", 0.0))
	skills = data.get("skills", {})
	quests = data.get("quests", {})

	inventory = []
	for entry in data.get("inventory", []):
		if typeof(entry) == TYPE_DICTIONARY and entry.has("name"):
			inventory.append({"name": str(entry["name"]), "qty": maxi(1, int(entry.get("qty", 1))), "locked": bool(entry.get("locked", false))})

	equipment = {}
	for slot in EQUIPMENT_SLOTS:
		equipment[slot] = ""
	for slot in data.get("equipment", {}).keys():
		if EQUIPMENT_SLOTS.has(str(slot)):
			equipment[str(slot)] = str(data["equipment"][slot])

	var saved_attributes: Variant = data.get("attributes", {})
	var saved_attrs: Dictionary = saved_attributes if typeof(saved_attributes) == TYPE_DICTIONARY else {}
	attributes = _default_attributes()
	for stat_name in ATTRIBUTE_NAMES:
		attributes[stat_name] = maxi(1, int(saved_attrs.get(stat_name, 1)))
	# Older saves predate the "power" attribute. Mirror strength so existing
	# characters keep the melee power they had before the upgrade.
	if not saved_attrs.has("power") and saved_attrs.has("strength"):
		attributes["power"] = attributes["strength"]
	if not saved_attrs.has("strength") and saved_attrs.has("power"):
		attributes["strength"] = attributes["power"]
	# Preserve any additional attributes stored by future versions.
	for key in saved_attrs.keys():
		var attr_key := str(key)
		if not attributes.has(attr_key):
			attributes[attr_key] = int(saved_attrs[key])

	var stats_now := stats()
	current_hp = clampi(int(data.get("current_hp", stats_now["max_hp"])), 1, stats_now["max_hp"])
	current_mp = clampi(int(data.get("current_mp", stats_now["max_mp"])), 0, stats_now["max_mp"])

	stats_changed.emit()
	inventory_changed.emit()
	equipment_changed.emit()
	gold_changed.emit()
	stage_changed.emit(current_stage)
	return true


## Loads a character returned by the API. Characters with no save blob yet get
## the normal starter inventory.
func apply_character(character: Dictionary) -> bool:
	var data: Variant = character.get("data", {})
	var saved_name := str(character.get("name", "")).strip_edges()
	var character_id := int(character.get("id", 0))
	if typeof(data) != TYPE_DICTIONARY or (data as Dictionary).is_empty():
		reset_progress(false)
		if not saved_name.is_empty():
			player_name = saved_name
		stats_changed.emit()
		if online_mode:
			online_character_id = character_id
			_write_local_save(export_save_data())
		return true
	var ok := apply_save_data(data as Dictionary)
	if ok and not saved_name.is_empty():
		player_name = saved_name
	if ok and online_mode:
		online_character_id = character_id
		_write_local_save(export_save_data())
		# A snapshot that failed to upload earlier is pushed again now that
		# the server connection is confirmed.
		replay_pending_cloud_save(character_id)
	return ok


## Resets all progression in memory. Pass `save` to immediately persist the
## fresh character (the new-game flow also saves via set_stage/set_class).
func reset_progress(save: bool = false) -> void:
	_init_new()
	if save:
		save_game()
