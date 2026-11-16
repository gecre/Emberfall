extends Node
## GameData
## Loads the wiki-derived JSON database and exposes lookup helpers plus the
## combat balance formulas used by the recreation.

const DATA_DIR := "res://Emberfall/data/"

var items: Dictionary = {}
var monsters: Dictionary = {}
var stages: Array = []
var stages_by_number: Dictionary = {}
var npcs: Dictionary = {}
var skills: Array = []
var skills_by_name: Dictionary = {}
var crafting: Array = []
var meta: Dictionary = {}

var _ranked_monsters: Array = []


func _ready() -> void:
	items = _load_dict("items.json")
	monsters = _load_dict("monsters.json")
	npcs = _load_dict("npcs.json")
	stages = _load_array("stages.json")
	skills = _load_array("skills.json")
	crafting = _load_array("crafting.json")
	meta = _load_dict("meta.json")

	for s in skills:
		var sname := str(s.get("name", ""))
		if sname != "":
			skills_by_name[sname] = s

	for stage in stages:
		var number := int(stage.get("number", 0))
		if number > 0:
			stages_by_number[number] = stage

	_build_monster_ranking()


func _load_dict(file_name: String) -> Dictionary:
	var path := DATA_DIR + file_name
	if not FileAccess.file_exists(path):
		push_error("GameData: missing data file " + path)
		return {}
	var text := FileAccess.get_file_as_string(path).strip_edges()
	if text == "":
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GameData: invalid JSON in " + path)
		return {}
	return parsed


func _load_array(file_name: String) -> Array:
	var path := DATA_DIR + file_name
	if not FileAccess.file_exists(path):
		push_error("GameData: missing data file " + path)
		return []
	var text := FileAccess.get_file_as_string(path).strip_edges()
	if text == "":
		return []
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		push_error("GameData: invalid JSON in " + path)
		return []
	return parsed


func _build_monster_ranking() -> void:
	_ranked_monsters = monsters.keys()
	_ranked_monsters.sort_custom(func(a: String, b: String) -> bool:
		return float(monsters[a].get("health", 0)) < float(monsters[b].get("health", 0))
	)


# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------
func item(item_name: String) -> Dictionary:
	return items.get(item_name, {})


func monster(monster_name: String) -> Dictionary:
	return monsters.get(monster_name, {})


func stage(number: int) -> Dictionary:
	return stages_by_number.get(number, {})


func npc(npc_name: String) -> Dictionary:
	return npcs.get(npc_name, {})


func stage_list() -> Array:
	return stages


func monster_list() -> Array:
	return _ranked_monsters


func skill(skill_name: String) -> Dictionary:
	return skills_by_name.get(skill_name, {})


func skill_list() -> Array:
	return skills


func skill_class(skill_name: String) -> String:
	match skill_name:
		"Down Crush", "Power Attack", "Expert Warrior", "Multi-Attack Distance", "Air Power Slash", "Shield Mastery", "Multi-Attack", "Melee Knockback", "Spinning Cutter":
			return "Warrior"
		"Charged Arrow Barrage", "Arrow Knockback Bonus", "Expert Archer", "Triple Shot Attack", "Arrow Rain Attack", "Piercing Arrow Attack":
			return "Archer"
		"Magic Shots", "Expert Wizard", "Circular Magic Attack", "Light Beam", "Magic Distance Increase", "Thunder Attack", "Self Heal", "Guild/Pet Heal":
			return "Mage"
		"Grenade Attack", "Upward Shoot", "Expert Cowboy", "Bullet Distance Increase", "Shotgun Attack", "Bullet Knockback", "Jump Grenade":
			return "Cowboy"
		_:
			return "General"


func item_list() -> Array:
	return items.keys()


func items_for_shop(shop_name: String) -> Array:
	var result: Array = []
	for item_name in items.keys():
		var data: Dictionary = items[item_name]
		if str(data.get("shop", "")) == shop_name and int(data.get("price", 0)) > 0:
			result.append(item_name)
	result.sort_custom(func(a: String, b: String) -> bool:
		return int(items[a].get("level", 1)) < int(items[b].get("level", 1))
	)
	return result


## Picks the monsters that should appear in a stage. Uses the wiki's monster
## list when it has entries; otherwise falls back to a power band derived from
## the stage number so every stage still has something to fight.
func monsters_for_stage(stage_data: Dictionary) -> Array:
	var result: Array = []
	for monster_name in stage_data.get("monsters", []):
		if monsters.has(monster_name) and not result.has(monster_name):
			result.append(monster_name)

	if result.is_empty() and not _ranked_monsters.is_empty():
		var number := int(stage_data.get("number", 1))
		var count := _ranked_monsters.size()
		var center := int(round(float(number) / 145.0 * float(count - 1)))
		var start := maxi(0, center - 3)
		var finish := mini(count, center + 4)
		for i in range(start, finish):
			result.append(_ranked_monsters[i])

	return result


func monster_rank(monster_name: String) -> int:
	return _ranked_monsters.find(monster_name) + 1


# ---------------------------------------------------------------------------
# Balance
# ---------------------------------------------------------------------------
## Wiki health values range from 18 to 35,000,000. Square-rooting keeps early
## monsters killable while bosses still feel like bosses.
func balance_hp(monster_data: Dictionary) -> int:
	var raw := maxf(1.0, float(monster_data.get("health", 10)))
	return maxi(8, int(round(sqrt(raw) * 7.0)))


func balance_damage(monster_data: Dictionary) -> int:
	var raw := maxf(1.0, float(monster_data.get("power", 5)))
	return maxi(1, int(round(sqrt(raw) * 2.2)))


func balance_speed(monster_data: Dictionary) -> float:
	var raw := float(monster_data.get("speed", 4.0))
	return clampf(45.0 + raw * 9.0, 40.0, 170.0)


func stage_level(number: int) -> int:
	return maxi(1, int(round(float(number) * 1.25)))


func stage_name(number: int) -> String:
	var data := stage(number)
	if data.is_empty():
		return "Unknown Stage"
	return str(data.get("name", "Unknown Stage"))
