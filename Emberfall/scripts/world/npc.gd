extends Area2D
class_name NPC

## A friendly non-combat character. Depending on the wiki service field an NPC
## opens a shop, heals the player, or simply chats.

var npc_name := "Villager"
var data: Dictionary = {}
var service := ""
var mission := ""
var stage_name := ""
var quote := ""
var phase := 0.0
var facing := -1.0


func setup(name: String) -> void:
	npc_name = name
	data = GameData.npc(name)
	if data.is_empty():
		data = {"name": name, "service": "", "mission": "", "quote": ""}
	service = str(data.get("service", "")).strip_edges()
	mission = str(data.get("mission", "")).strip_edges()
	stage_name = str(data.get("stage_name", "")).strip_edges()
	quote = str(data.get("quote", "")).strip_edges()
	queue_redraw()


func _ready() -> void:
	add_to_group("npcs")
	phase = randf() * TAU
	queue_redraw()


func _process(delta: float) -> void:
	phase += delta * 1.6
	queue_redraw()


func _is_shop() -> bool:
	return service.to_lower().contains("shop")


func _is_healer() -> bool:
	var lower := service.to_lower()
	return lower.contains("heal")


func get_prompt() -> String:
	if _is_shop():
		return "Click to browse %s's shop" % npc_name
	if _is_healer():
		return "Click to be healed by %s" % npc_name
	return "Click to talk to %s" % npc_name


func interact(_player: Node) -> void:
	var hud := get_tree().get_first_node_in_group("hud")
	if _is_shop():
		if hud != null and hud.has_method("open_shop"):
			hud.open_shop(npc_name)
		return
	if _is_healer():
		var stats := GameState.stats()
		GameState.heal(int(stats["max_hp"]))
		GameState.restore_mp(int(stats["max_mp"]))
		GameState.message.emit("%s healed you to full health." % npc_name)
		return
	if hud != null and hud.has_method("show_dialogue"):
		hud.show_dialogue(npc_name, _dialogue_text())


func _dialogue_text() -> String:
	if quote != "":
		return quote
	if mission != "":
		return "I have a task for you: %s" % mission
	if stage_name != "":
		return "Welcome to %s, traveler. Stay sharp out there." % stage_name
	return "Welcome, traveler. Stay sharp out there."


func _draw() -> void:
	var bob := sin(phase) * 1.2
	var robe := Color(0.34, 0.42, 0.66)
	var trim := Color(0.86, 0.74, 0.38)
	if _is_shop():
		robe = Color(0.52, 0.34, 0.22)
		trim = Color(0.96, 0.82, 0.32)
	elif _is_healer():
		robe = Color(0.28, 0.52, 0.38)
		trim = Color(0.92, 0.96, 0.9)

	# Shadow
	draw_set_transform(Vector2(0, -1), 0.0, Vector2(1.0, 0.3))
	draw_circle(Vector2.ZERO, 22.0, Color(0.0, 0.0, 0.0, 0.24))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Legs / robe
	draw_rect(Rect2(-14, -20 + bob, 28, 20), robe.darkened(0.28))
	draw_colored_polygon(PackedVector2Array([
		Vector2(-17, -6 + bob), Vector2(17, -6 + bob),
		Vector2(12, -52 + bob), Vector2(-12, -52 + bob),
	]), robe)
	draw_rect(Rect2(-17, -8 + bob, 34, 5), trim.darkened(0.15))

	# Arms
	draw_rect(Rect2(-19, -46 + bob, 6, 24), robe.darkened(0.12))
	draw_rect(Rect2(13, -46 + bob, 6, 24), robe.darkened(0.12))

	# Head
	var skin := Color(0.95, 0.77, 0.61)
	draw_circle(Vector2(0, -60 + bob), 11.0, skin)
	draw_circle(Vector2(facing * 3.5, -61 + bob), 1.7, Color(0.08, 0.09, 0.12))
	draw_circle(Vector2(facing * -2.5, -61 + bob), 1.7, Color(0.08, 0.09, 0.12))

	# Hair / hat
	if _is_shop():
		draw_rect(Rect2(-12, -74 + bob, 24, 6), trim)
		draw_rect(Rect2(-8, -82 + bob, 16, 9), trim.darkened(0.1))
	else:
		draw_circle(Vector2(0, -65 + bob), 11.5, Color(0.36, 0.24, 0.16))
		draw_rect(Rect2(-11, -66 + bob, 22, 5), Color(0.36, 0.24, 0.16))

	# Service badge
	if _is_shop():
		draw_circle(Vector2(0, -34 + bob), 7.0, Color(0.98, 0.85, 0.3))
		draw_string(ThemeDB.fallback_font, Vector2(-4, -30 + bob), "$",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.25, 0.18, 0.05))
	elif _is_healer():
		draw_rect(Rect2(-2.5, -42 + bob, 5, 16), Color(0.95, 0.98, 0.95))
		draw_rect(Rect2(-8, -36 + bob, 16, 5), Color(0.95, 0.98, 0.95))

	# Name
	draw_string(ThemeDB.fallback_font, Vector2(-80, -94 + bob), npc_name,
		HORIZONTAL_ALIGNMENT_CENTER, 160, 12, Color(1, 1, 1, 0.94))
