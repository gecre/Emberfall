extends Node2D
class_name Stage

## Builds a complete playable stage procedurally from the wiki data: backdrop,
## ground, platforms, NPCs, portals, monsters, loot and floating combat text.

const PLAYER_SCENE := preload("res://Emberfall/scenes/player/player.tscn")
const MONSTER_SCENE := preload("res://Emberfall/scenes/entities/monster.tscn")
const LOOT_SCENE := preload("res://Emberfall/scenes/entities/loot.tscn")
const NPC_SCENE := preload("res://Emberfall/scenes/world/npc.tscn")
const PORTAL_SCENE := preload("res://Emberfall/scenes/world/portal.tscn")
const TRADE_PANEL_SCRIPT := preload("res://Emberfall/scripts/ui/trade_panel.gd")
const STALL_PANEL_SCRIPT := preload("res://Emberfall/scripts/ui/stall_panel.gd")

const GROUND_Y := 480.0
const SPAWN_X := 200.0
const PORTAL_ELEVATION := 115.0

# Map zones (world x ranges)
const TOWN_RIGHT := 700.0      # safe town area ends here
const TRANSITION_END := 1100.0 # ramp up completes here
const ENEMY_ZONE_Y := GROUND_Y - 60.0  # elevated enemy ground

# Jump-safe platform spacing (JUMP_VELOCITY=560, GRAVITY=1550 => ~101px max height)
const MAX_PLATFORM_RISE := 80.0   # max vertical step between platforms/ground
const MAX_PLATFORM_GAP := 110.0   # max horizontal gap the player can jump
const ENEMY_MIN_SPACING := 50.0   # min distance between enemy spawns
const ENEMY_ZONE_RIGHT := 3200.0  # cap enemy spawns so they don't spread thin across huge maps
const PORTAL_SPAWN_DIST := 220.0  # never spawn monsters this close to a portal
const NPC_SPAWN_DIST := 220.0     # never spawn monsters this close to an NPC
const HOTBAR_Y := 560.0           # keep important content above this (screen bottom UI)

var stage_number := 1
var stage_data: Dictionary = {}
var player: Player = null
var hud = null
var world_width := 4200.0
var spawn_point := Vector2(SPAWN_X, GROUND_Y - 4.0)
## Container for networked remote player nodes.
var remote_players_container: Node2D = null
var trade_panel = null
var stall_panel = null

var _platform_rects: Array[Rect2] = []
var _ramp_polys: Array = []
var _ground_pts: Array[Vector2] = []
var _enemy_spawns: Array[Vector2] = []
var _portal_positions: Array[Vector2] = []
var _npc_positions: Array[Vector2] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group("stage")
	stage_number = maxi(1, GameState.current_stage)
	stage_data = GameData.stage(stage_number)
	if stage_data.is_empty():
		stage_data = {"number": stage_number, "name": "Unknown Stage", "npcs": [], "monsters": []}

	world_width = 3800.0 + float(mini(stage_number, 120)) * 25.0
	_rng.seed = stage_number * 104729

	_build_bounds()
	_build_platforms()
	_spawn_portals()
	_spawn_player()
	_spawn_npcs()
	_spawn_monsters()

	hud = get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("bind"):
		hud.bind(self, player)

	_remote_players_setup()

	queue_redraw()


# ---------------------------------------------------------------------------
# World geometry
# ---------------------------------------------------------------------------
func _add_static_rect(rect: Rect2, one_way: bool = false) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = rect.position + rect.size * 0.5
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	collision.shape = shape
	if one_way:
		collision.one_way_collision = true
		collision.one_way_collision_margin = 8.0
	body.add_child(collision)
	add_child(body)
	return body


# Adds a walkable sloped ramp (hill) from the ground up to a platform top.
# The slope stays shallow enough (<= ~40 deg) to be climbable by the player.
func _add_ramp(start_x: float, end_x: float, top_y: float) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector2.ZERO
	var poly := CollisionPolygon2D.new()
	var pts := PackedVector2Array([
		Vector2(start_x, GROUND_Y),
		Vector2(end_x, GROUND_Y),
		Vector2(end_x, top_y),
	])
	poly.polygon = pts
	body.add_child(poly)
	add_child(body)
	_ramp_polys.append(pts)


func _build_bounds() -> void:
	# Side walls
	_add_static_rect(Rect2(-70.0, GROUND_Y - 2200.0, 50.0, 2200.0))
	_add_static_rect(Rect2(world_width + 20.0, GROUND_Y - 2200.0, 50.0, 2200.0))

	# Zone-based ground: flat town, smooth ramp up, flat elevated enemy area.
	# Kept clear of the hotbar zone (content stays above HOTBAR_Y on screen).
	var pts := PackedVector2Array()
	_ground_pts = []
	var seg := 40.0
	var x := -500.0
	while x < world_width + 600.0:
		var y: float
		if x <= TOWN_RIGHT:
			y = GROUND_Y  # safe town flat
		elif x <= TRANSITION_END:
			# Smooth ramp from town up to enemy zone.
			var t := (x - TOWN_RIGHT) / (TRANSITION_END - TOWN_RIGHT)
			y = lerpf(GROUND_Y, ENEMY_ZONE_Y, t)
		else:
			y = ENEMY_ZONE_Y  # elevated enemy area flat
		pts.append(Vector2(x, y))
		_ground_pts.append(Vector2(x, y))
		x += seg
	pts.append(Vector2(world_width + 600.0, GROUND_Y + 500.0))
	pts.append(Vector2(-500.0, GROUND_Y + 500.0))

	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector2.ZERO
	var poly := CollisionPolygon2D.new()
	poly.polygon = pts
	body.add_child(poly)
	add_child(body)


func _ground_y_at(x: float) -> float:
	if _ground_pts.is_empty():
		return GROUND_Y
	var size := _ground_pts.size()
	if x <= _ground_pts[0].x:
		return _ground_pts[0].y
	if x >= _ground_pts[size - 1].x:
		return _ground_pts[size - 1].y
	# Linearly interpolate between the two sample points bracketing x so the
	# monster sits exactly on the (linear) collision surface, not embedded in it.
	var i := 0
	while i < size - 1 and _ground_pts[i + 1].x < x:
		i += 1
	var p0 := _ground_pts[i]
	var p1 := _ground_pts[i + 1]
	var t := (x - p0.x) / (p1.x - p0.x)
	return lerpf(p0.y, p1.y, t)


# Finds the flattest ground spot within `range` of `x` (smallest slope between
# adjacent sample points) so NPCs and portals sit straight on level ground.
func _find_flat_ground_near(x: float, search_range: float = 200.0) -> float:
	var size := _ground_pts.size()
	if size < 3:
		return _ground_y_at(x)
	var start_i := 0
	while start_i < size - 1 and _ground_pts[start_i].x < x - search_range:
		start_i += 1
	var end_i := size - 1
	while end_i > 0 and _ground_pts[end_i].x > x + search_range:
		end_i -= 1
	var best_x := clampf(x, _ground_pts[0].x, _ground_pts[size - 1].x)
	var best_slope := 1.0e20
	for i in range(start_i, end_i):
		var p0 := _ground_pts[i]
		var p1 := _ground_pts[i + 1]
		var slope := absf((p1.y - p0.y) / (p1.x - p0.x))
		if slope < best_slope:
			best_slope = slope
			best_x = (p0.x + p1.x) * 0.5
	return best_x


func _build_platforms() -> void:
	# Scattered floating platforms across the enemy zone: spread far up into the
	# sky, with occasional big platforms large enough for monsters to spawn on.
	# Each gap stays within jump reach and each rise is climbable (max step 60px
	# < MAX_PLATFORM_RISE 80px, max gap 65px < MAX_PLATFORM_GAP 110px). Kept out
	# of the town zone.
	var plat_x := TRANSITION_END + 40.0
	var plat_y := ENEMY_ZONE_Y - 60.0
	while plat_x < world_width - 200.0:
		# Occasionally place a big platform (monster spawn target).
		var is_big := _rng.randf() < 0.18
		var width := _rng.randf_range(260.0, 420.0) if is_big else _rng.randf_range(100.0, 160.0)
		var rect := Rect2(plat_x, plat_y, width, 22.0)
		if rect.end.x < world_width - 40.0:
			_platform_rects.append(rect)
			_add_static_rect(rect, true)
		plat_x += width + _rng.randf_range(35.0, 65.0)
		plat_y += _rng.randf_range(-60.0, 60.0)
		plat_y = clampf(plat_y, ENEMY_ZONE_Y - 900.0, ENEMY_ZONE_Y - 50.0)


# ---------------------------------------------------------------------------
# Spawning
# ---------------------------------------------------------------------------
func _spawn_player() -> void:
	var arrival := GameState.entry_direction
	GameState.entry_direction = 0
	var at := Vector2(SPAWN_X, _ground_y_at(SPAWN_X) - 4.0)
	if arrival > 0:
		# Walked through a forward portal: appear at this stage's back portal.
		at = Vector2(100.0, _ground_y_at(100.0) - 4.0)
	elif arrival < 0:
		# Walked through a back portal: appear at this stage's forward portal.
		at = Vector2(world_width - 120.0, _ground_y_at(world_width - 120.0) - 4.0)
	player = PLAYER_SCENE.instantiate()
	player.position = at
	player.set_multiplayer_authority(multiplayer.get_unique_id())
	add_child(player)
	player.damaged.connect(_on_player_damaged)
	player.died.connect(_on_player_died)
	if player.camera != null:
		player.camera.limit_left = 0
		player.camera.limit_right = int(world_width)
		player.camera.limit_top = -1800
		player.camera.limit_bottom = int(ENEMY_ZONE_Y + 160.0)


## Sets up networked remote players when a multiplayer session is active.
func _remote_players_setup() -> void:
	remote_players_container = Node2D.new()
	remote_players_container.name = "RemotePlayers"
	add_child(remote_players_container)

	trade_panel = TRADE_PANEL_SCRIPT.new()
	add_child(trade_panel)

	stall_panel = STALL_PANEL_SCRIPT.new()
	add_child(stall_panel)

	if Network.online_mode:
		Network.stage_players_received.connect(_on_stage_players_received)
		Network.remote_player_joined.connect(_on_remote_player_joined)
		Network.remote_player_moved.connect(_on_remote_player_moved)
		Network.remote_player_left.connect(_on_remote_player_left)
		Network.player_stall_changed.connect(_on_player_stall_changed)
		Network.trade_requested.connect(_on_incoming_trade_request)
		Network.trade_responded.connect(_on_trade_responded)
		Network.chat_message_received.connect(_on_chat_message_received)
		Network.join_stage(stage_number, spawn_point)
		_setup_stall_hud_button()

	if multiplayer.multiplayer_peer != null and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.peer_connected.connect(_spawn_remote_player)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		for pid in Network.connected_peers:
			_spawn_remote_player(pid)


func _on_stage_players_received(stage: int, players: Array) -> void:
	if stage != stage_number:
		return
	for pdata in players:
		_spawn_remote_ws_player(pdata)


func _on_remote_player_joined(pdata: Dictionary) -> void:
	_spawn_remote_ws_player(pdata)


func _spawn_remote_ws_player(pdata: Dictionary) -> void:
	var id: int = int(pdata.get("id", 0))
	if id <= 0 or id == Network.our_id:
		return
	var existing := remote_players_container.get_node_or_null("RemotePlayer_%d" % id)
	if is_instance_valid(existing):
		return
	var rplayer: Player = PLAYER_SCENE.instantiate()
	rplayer.name = "RemotePlayer_%d" % id
	rplayer.remote_data = pdata
	rplayer.add_to_group("remote_players")
	var pos_arr: Array = pdata.get("pos", [spawn_point.x, spawn_point.y])
	rplayer.position = Vector2(float(pos_arr[0]), float(pos_arr[1]))
	remote_players_container.add_child(rplayer)


func _on_remote_player_moved(id: int, pos: Vector2, vel: Vector2, facing: float, swing: bool) -> void:
	var rplayer := remote_players_container.get_node_or_null("RemotePlayer_%d" % id)
	if is_instance_valid(rplayer) and rplayer.has_method("apply_remote_move"):
		rplayer.apply_remote_move(pos, vel, facing, swing)


func _on_remote_player_left(id: int) -> void:
	var node := remote_players_container.get_node_or_null("RemotePlayer_%d" % id)
	if is_instance_valid(node):
		node.queue_free()


func _on_player_stall_changed(pid: int, stall: Variant) -> void:
	var rplayer := remote_players_container.get_node_or_null("RemotePlayer_%d" % pid)
	if is_instance_valid(rplayer):
		rplayer.remote_data["stall"] = stall
		rplayer.queue_redraw()


func _setup_stall_hud_button() -> void:
	var cl := CanvasLayer.new()
	cl.layer = 80
	add_child(cl)

	var btn := Button.new()
	btn.text = "🏪 Setup Shop"
	btn.custom_minimum_size = Vector2(130, 36)
	btn.position = Vector2(20, 165)
	btn.add_theme_font_size_override("font_size", 12)
	btn.pressed.connect(func():
		if is_instance_valid(stall_panel):
			stall_panel.open_for_setup()
	)
	cl.add_child(btn)


func _on_chat_message_received(channel: String, sender: String, _whisper_to: String, text: String) -> void:
	# Show overhead speech bubbles for players currently in this stage
	if channel == "stage" or channel == "global":
		if player != null and is_instance_valid(player) and sender.to_lower() == GameState.player_name.to_lower():
			player.show_speech_bubble(text)
		elif remote_players_container != null:
			for r in remote_players_container.get_children():
				if r is Player and str(r.remote_data.get("name", "")).to_lower() == sender.to_lower():
					r.show_speech_bubble(text)
					break


func interact_with_remote_player(rplayer: Player) -> void:
	var pid: int = int(rplayer.remote_data.get("id", 0))
	var rname: String = str(rplayer.remote_data.get("name", "Player"))
	var stall: Variant = rplayer.remote_data.get("stall")
	if stall != null and typeof(stall) == TYPE_DICTIONARY:
		if is_instance_valid(stall_panel):
			stall_panel.open_for_browsing(pid, rname, stall)
	else:
		_show_player_interaction_menu(rplayer)


func _show_player_interaction_menu(rplayer: Player) -> void:
	var pid: int = int(rplayer.remote_data.get("id", 0))
	var rname: String = str(rplayer.remote_data.get("name", "Player"))
	var rclass: String = str(rplayer.remote_data.get("class", "Warrior"))
	var rlevel: int = int(rplayer.remote_data.get("level", 1))
	var req: Dictionary = rplayer.remote_data.get("equipment", {})

	var canvas := CanvasLayer.new()
	canvas.layer = 90
	add_child(canvas)

	# Full-screen backdrop to block clicks from reaching the game world
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(backdrop)
	# Click outside the popup to dismiss
	backdrop.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			canvas.queue_free()
		elif ev is InputEventScreenTouch and ev.pressed:
			canvas.queue_free()
	)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(center)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(340, 260)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.13, 0.19, 0.98)
	style.set_corner_radius_all(10)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.85, 0.65, 0.25)
	frame.add_theme_stylebox_override("panel", style)
	center.add_child(frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	# Name & Level Header
	var name_lbl := Label.new()
	name_lbl.text = rname
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	vbox.add_child(name_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s • Level %d" % [rclass, rlevel]
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_lbl.add_theme_font_size_override("font_size", 13)
	sub_lbl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	vbox.add_child(sub_lbl)

	# Equipment overview
	var eq_box := PanelContainer.new()
	var eq_style := StyleBoxFlat.new()
	eq_style.bg_color = Color(0.16, 0.18, 0.26, 0.9)
	eq_style.set_corner_radius_all(6)
	eq_box.add_theme_stylebox_override("panel", eq_style)
	vbox.add_child(eq_box)

	var eq_vbox := VBoxContainer.new()
	eq_vbox.add_theme_constant_override("separation", 3)
	eq_box.add_child(eq_vbox)

	var weapon_name := str(req.get("weapon", "None"))
	var armor_name := str(req.get("armor", "None"))
	var helmet_name := str(req.get("helmet", "None"))
	var shield_name := str(req.get("shield", "None"))

	var w_lbl := Label.new()
	w_lbl.text = " ⚔ Weapon: %s" % (weapon_name if weapon_name != "" else "None")
	w_lbl.add_theme_font_size_override("font_size", 11)
	eq_vbox.add_child(w_lbl)

	var a_lbl := Label.new()
	a_lbl.text = " 🛡 Armor: %s" % (armor_name if armor_name != "" else "None")
	a_lbl.add_theme_font_size_override("font_size", 11)
	eq_vbox.add_child(a_lbl)

	var h_lbl := Label.new()
	h_lbl.text = " 🪖 Helmet: %s" % (helmet_name if helmet_name != "" else "None")
	h_lbl.add_theme_font_size_override("font_size", 11)
	eq_vbox.add_child(h_lbl)

	if shield_name != "":
		var s_lbl := Label.new()
		s_lbl.text = " 🔰 Shield: %s" % shield_name
		s_lbl.add_theme_font_size_override("font_size", 11)
		eq_vbox.add_child(s_lbl)

	# Action Buttons Row
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 10)
	vbox.add_child(actions)

	# 1. Trade Button
	var trade_btn := Button.new()
	trade_btn.text = "TRADE"
	trade_btn.custom_minimum_size = Vector2(90, 42)
	trade_btn.pressed.connect(func():
		canvas.queue_free()
		Network.request_trade(pid)
		GameState.message.emit("Sent trade request to %s..." % rname)
	)
	actions.add_child(trade_btn)

	# 2. Add Friend Button
	var friend_btn := Button.new()
	friend_btn.text = "ADD FRIEND"
	friend_btn.custom_minimum_size = Vector2(105, 42)
	friend_btn.pressed.connect(func():
		canvas.queue_free()
		var friends: Array = GameState.quests.get("_friends", [])
		if not friends.has(rname):
			friends.append(rname)
			GameState.quests["_friends"] = friends
			GameState.save_game()
			GameState.message.emit("%s added to your friends list!" % rname)
		else:
			GameState.message.emit("%s is already in your friends list." % rname)
	)
	actions.add_child(friend_btn)

	# 3. Stats Button
	var stats_btn := Button.new()
	stats_btn.text = "STATS"
	stats_btn.custom_minimum_size = Vector2(85, 42)
	stats_btn.pressed.connect(func():
		canvas.queue_free()
		_show_player_stats_inspection(rplayer)
	)
	actions.add_child(stats_btn)

	# Close Button
	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.custom_minimum_size = Vector2(120, 36)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.pressed.connect(func(): canvas.queue_free())
	vbox.add_child(close_btn)


func _show_player_stats_inspection(rplayer: Player) -> void:
	var rname: String = str(rplayer.remote_data.get("name", "Player"))
	var rclass: String = str(rplayer.remote_data.get("class", "Warrior"))
	var rlevel: int = int(rplayer.remote_data.get("level", 1))
	var req: Dictionary = rplayer.remote_data.get("equipment", {})

	var canvas := CanvasLayer.new()
	canvas.layer = 92
	add_child(canvas)

	# Full-screen backdrop to block clicks from reaching the game world
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(backdrop)
	backdrop.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			canvas.queue_free()
		elif ev is InputEventScreenTouch and ev.pressed:
			canvas.queue_free()
	)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(center)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(380, 320)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.12, 0.17, 0.98)
	style.set_corner_radius_all(10)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.35, 0.55, 0.85)
	frame.add_theme_stylebox_override("panel", style)
	center.add_child(frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	var title := Label.new()
	title.text = "%s's Profile" % rname
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	vbox.add_child(title)

	var info := Label.new()
	info.text = "Class: %s  |  Level: %d" % [rclass, rlevel]
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(info)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 180)
	vbox.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)

	for slot in ["weapon", "helmet", "armor", "legs", "boots", "shield", "accessory", "pet_helmet"]:
		var iname := str(req.get(slot, ""))
		if iname != "":
			var idata := GameData.item(iname)
			var ilvl := int(idata.get("level", 1))
			var row := Label.new()
			row.text = "• %s: %s (Lv. %d)" % [slot.capitalize(), iname, ilvl]
			row.add_theme_font_size_override("font_size", 12)
			list.add_child(row)

	var close_btn := Button.new()
	close_btn.text = "BACK"
	close_btn.custom_minimum_size = Vector2(100, 38)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.pressed.connect(func(): canvas.queue_free())
	vbox.add_child(close_btn)


func _on_incoming_trade_request(from_id: int, from_name: String) -> void:
	var banner := PanelContainer.new()
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.custom_minimum_size = Vector2(0, 56)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.15, 0.22, 0.96)
	style.border_width_bottom = 2
	style.border_color = Color(1.0, 0.75, 0.3)
	banner.add_theme_stylebox_override("panel", style)
	add_child(banner)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 16)
	banner.add_child(hbox)

	var lbl := Label.new()
	lbl.text = "%s wants to trade with you!" % from_name
	lbl.add_theme_font_size_override("font_size", 14)
	hbox.add_child(lbl)

	var accept_btn := Button.new()
	accept_btn.text = "ACCEPT"
	accept_btn.custom_minimum_size = Vector2(100, 40)
	accept_btn.pressed.connect(func():
		banner.queue_free()
		Network.respond_trade(from_id, true)
		if is_instance_valid(trade_panel):
			trade_panel.open(from_id, from_name)
	)
	hbox.add_child(accept_btn)

	var decline_btn := Button.new()
	decline_btn.text = "DECLINE"
	decline_btn.custom_minimum_size = Vector2(100, 40)
	decline_btn.pressed.connect(func():
		banner.queue_free()
		Network.respond_trade(from_id, false)
	)
	hbox.add_child(decline_btn)

	get_tree().create_timer(15.0).timeout.connect(func():
		if is_instance_valid(banner):
			banner.queue_free()
	)


func _on_trade_responded(from_id: int, from_name: String, accepted: bool) -> void:
	if accepted:
		if is_instance_valid(trade_panel):
			trade_panel.open(from_id, from_name)
	else:
		GameState.message.emit("%s declined your trade request." % from_name)


## Spawns a player representation for a connected remote peer.
func _spawn_remote_player(peer_id: int) -> void:
	var player := PLAYER_SCENE.instantiate()
	player.name = "RemotePlayer_%d" % peer_id
	player.position = spawn_point + Vector2(peer_id * 40.0, 0.0)
	player.set_multiplayer_authority(peer_id)
	remote_players_container.add_child(player)


## Removes a remote player when its peer disconnects.
func _on_peer_disconnected(peer_id: int) -> void:
	var node := get_node_or_null("RemotePlayers/RemotePlayer_%d" % peer_id)
	if is_instance_valid(node):
		node.queue_free()





## Broadcasts the local player's position to all peers each frame.
func _process(_delta: float) -> void:
	pass


func _spawn_npcs() -> void:
	# Town NPCs only, in the safe town area on flat ground, spaced apart so
	# name labels don't overlap. Kept out of the hotbar zone. NPCs come from
	# the stage's wiki data (stage_data.npcs), not a hardcoded list, so each
	# NPC only appears on its correct stage.
	var npc_names: Array = stage_data.get("npcs", [])
	var x := 300.0
	for npc_name in npc_names:
		if x > TOWN_RIGHT - 60.0:
			break
		var npc: NPC = NPC_SCENE.instantiate()
		var nx := _find_flat_ground_near(x, 60.0)
		npc.position = Vector2(nx, _ground_y_at(nx))
		add_child(npc)
		_npc_positions.append(npc.position)
		npc.setup(str(npc_name))
		x += 140.0


func _spawn_portals() -> void:
	# Back portal at the left edge (previous stage). Stage 1 has no previous.
	var previous: Variant = stage_data.get("previous", null)
	if typeof(previous) == TYPE_DICTIONARY:
		var previous_number := int(previous.get("number", 0))
		if previous_number > 0 and not GameData.stage(previous_number).is_empty():
			var back_portal: Portal = PORTAL_SCENE.instantiate()
			var bx := _find_flat_ground_near(120.0, 60.0)
			back_portal.position = Vector2(bx, _ground_y_at(bx))
			add_child(back_portal)
			back_portal.setup(previous_number, -1)
			_portal_positions.append(Vector2(bx, _ground_y_at(bx)))

	# Forward portal at the right edge (next stage). The last stage has none.
	var next: Variant = stage_data.get("next", null)
	if typeof(next) == TYPE_DICTIONARY and next != null:
		var next_number := int(next.get("number", 0))
		if next_number > 0 and not GameData.stage(next_number).is_empty():
			var next_portal: Portal = PORTAL_SCENE.instantiate()
			var nx2 := _find_flat_ground_near(world_width - 120.0)
			next_portal.position = Vector2(nx2, _ground_y_at(nx2))
			add_child(next_portal)
			next_portal.setup(next_number, 1)
			_portal_positions.append(Vector2(nx2, _ground_y_at(nx2)))


func _is_near_portal(x: float, y: float) -> bool:
	for p in _portal_positions:
		if Vector2(x, y).distance_to(p) < PORTAL_SPAWN_DIST:
			return true
	return false


func _is_near_npc(x: float, y: float) -> bool:
	for p in _npc_positions:
		if Vector2(x, y).distance_to(p) < NPC_SPAWN_DIST:
			return true
	return false


func _spawn_monsters() -> void:
	var pool := GameData.monsters_for_stage(stage_data)
	if pool.is_empty():
		return

	var regular = []
	var bosses = []
	for monster_key in pool:
		var data := GameData.monster(str(monster_key))
		if bool(data.get("boss", false)):
			bosses.append(str(monster_key))
		else:
			regular.append(str(monster_key))
	if regular.is_empty():
		regular = pool

	# Fixed enemy spawn positions spread across the whole enemy zone (full map
	# width, not just one area), spaced apart so name labels don't overlap, each
	# on reachable ground or a reachable platform. Kept clear of portals and NPCs.
	# More enemies on larger maps.
	_enemy_spawns = []
	var spawn_x := TRANSITION_END + 120.0
	var placed := 0
	var max_enemies := clampi(10 + int(world_width / 250.0), 10, 400)
	var spawn_limit := world_width - 180.0
	# Split spawns between ground and platforms so monsters use the full stage
	# height, not just the ground. Roughly half land on platforms.
	var platform_cap := maxi(2, max_enemies >> 1)
	var ground_cap := max_enemies - platform_cap
	while spawn_x < spawn_limit and placed < ground_cap:
		var sx := spawn_x
		spawn_x += ENEMY_MIN_SPACING + _rng.randf_range(0.0, 40.0)
		if _is_near_portal(sx, ENEMY_ZONE_Y) or _is_near_npc(sx, ENEMY_ZONE_Y):
			continue
		_enemy_spawns.append(Vector2(sx, ENEMY_ZONE_Y))
		placed += 1

	# Spawn the remaining monsters on platforms (widest first), one per platform,
	# clear of portals (teleports) and NPCs.
	var platform_candidates: Array[Rect2] = _platform_rects.duplicate()
	platform_candidates.sort_custom(func(a, b): return a.size.x > b.size.x)
	while placed < max_enemies and not platform_candidates.is_empty():
		var plat: Rect2 = platform_candidates.pop_front()
		var plat_pos := Vector2(plat.position.x + plat.size.x * 0.5, plat.position.y)
		var too_close := false
		for s in _enemy_spawns:
			if s.distance_to(plat_pos) < ENEMY_MIN_SPACING:
				too_close = true
				break
		if too_close or _is_near_portal(plat_pos.x, plat_pos.y) or _is_near_npc(plat_pos.x, plat_pos.y):
			continue
		_enemy_spawns.append(plat_pos)
		placed += 1

	# Assign monster keys (bosses last, fixed positions).
	var all_keys := bosses.duplicate()
	for k in regular:
		if all_keys.size() < _enemy_spawns.size():
			all_keys.append(str(k))
	for i in range(_enemy_spawns.size()):
		var key: String = all_keys[i] if i < all_keys.size() else str(regular[_rng.randi_range(0, regular.size() - 1)])
		_spawn_monster(str(key), _enemy_spawns[i])


func _spawn_monster(monster_key: String, at_position: Vector2) -> void:
	var monster: Monster = MONSTER_SCENE.instantiate()
	monster.position = at_position
	add_child(monster)
	monster.setup(monster_key, stage_number)
	monster.left_bound = 70.0
	monster.right_bound = world_width - 70.0
	monster.died.connect(_on_monster_died)
	monster.damage_dealt.connect(_on_monster_damage_dealt)


# ---------------------------------------------------------------------------
# Combat feedback and loot
# ---------------------------------------------------------------------------
func _on_monster_damage_dealt(amount: int, critical: bool, world_position: Vector2) -> void:
	var color := Color(1.0, 0.95, 0.55)
	var text := str(amount)
	if critical:
		color = Color(1.0, 0.62, 0.2)
		text += "!"
	spawn_floating_text(text, world_position, color)


func _on_player_damaged(amount: int, world_position: Vector2) -> void:
	var text := "Dodged!" if amount == 0 else "-%d" % amount
	spawn_floating_text(text, world_position, Color(1.0, 0.38, 0.34))


func spawn_floating_text(text: String, world_position: Vector2, color: Color,
		font_size: int = 20, rise: float = 58.0, duration: float = 0.85) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("outline_size", 4)
	label.z_index = 60
	label.position = world_position + Vector2(_rng.randf_range(-14.0, 14.0), -10.0)
	add_child(label)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - rise, duration)
	tween.tween_property(label, "modulate:a", 0.0, duration)
	tween.chain().tween_callback(label.queue_free)


func _on_monster_died(monster: Monster) -> void:
	var gold := maxi(1, monster.gold_reward) * int(GameState.GOLD_MULTIPLIER)
	_spawn_loot(monster.global_position, gold, "", 0)

	var drop_chance := 0.6 if monster.is_boss else 0.14
	var dropped: Array[String] = []
	for item_name in monster.drops:
		if dropped.size() >= 3:
			break
		if not GameData.item(str(item_name)).is_empty() and _rng.randf() < drop_chance:
			_spawn_loot(monster.global_position + Vector2(_rng.randf_range(-24.0, 24.0), 0.0), 0, str(item_name), 1)
			dropped.append(str(item_name))



	var xp_gain := int(monster.xp_reward * GameState.XP_MULTIPLIER)
	GameState.add_xp(xp_gain)
	get_tree().create_timer(5.0).timeout.connect(func() -> void:
		if is_instance_valid(self):
			_respawn_stage_monster()
	)

	# Show EXP reward as floating text above the player when the monster dies.
	if xp_gain > 0:
		var reward_origin := player.global_position + Vector2(0.0, -90.0)
		spawn_floating_text("+%s EXP" % GameState.format_number(xp_gain),
			reward_origin, Color(0.55, 0.85, 1.0), 19, 46.0, 1.05)


func _respawn_stage_monster() -> void:
	var pool := GameData.monsters_for_stage(stage_data)
	if pool.is_empty():
		return
	var regular: Array[String] = []
	for key in pool:
		var d := GameData.monster(str(key))
		if not bool(d.get("boss", false)):
			regular.append(str(key))
	if regular.is_empty():
		for key in pool:
			regular.append(str(key))
	var chosen: String = str(regular[_rng.randi() % regular.size()])
	# Respawn on a fixed enemy spawn (reachable, spaced, portal-clear) or elevated
	# enemy ground within the capped spawn region.
	var at_pos := Vector2.ZERO
	if not _enemy_spawns.is_empty():
		at_pos = _enemy_spawns[_rng.randi_range(0, _enemy_spawns.size() - 1)]
	else:
		var spawn_limit := world_width - 180.0
		var x := _rng.randf_range(TRANSITION_END + 120.0, spawn_limit)
		at_pos = Vector2(x, ENEMY_ZONE_Y)
		# Keep retrying until the random respawn spot is clear of portals and NPCs.
		var guard := 0
		while (_is_near_portal(at_pos.x, at_pos.y) or _is_near_npc(at_pos.x, at_pos.y)) and guard < 20:
			x = _rng.randf_range(TRANSITION_END + 120.0, spawn_limit)
			at_pos = Vector2(x, ENEMY_ZONE_Y)
			guard += 1
	_spawn_monster(chosen, at_pos)


func _spawn_loot(at_position: Vector2, gold: int, item_name: String, quantity: int) -> void:
	var loot: LootPickup = LOOT_SCENE.instantiate()
	if item_name == "":
		loot.setup_gold(gold)
	else:
		loot.setup_item(item_name, quantity)
	loot.position = at_position
	add_child(loot)


## Public entry-point used by the HUD "Drop" action to spawn a loot pickup
## at the player's current position.
func spawn_item_drop(item_name: String, quantity: int = 1) -> void:
	var drop_pos := Vector2(200.0, GROUND_Y)  # safe fallback
	if player != null and is_instance_valid(player):
		drop_pos = player.global_position + Vector2(randf_range(-24.0, 24.0), 0.0)
	_spawn_loot(drop_pos, 0, item_name, quantity)


func _on_player_died() -> void:
	var lost := GameState.lose_gold_on_death()
	if hud != null and hud.has_method("show_death"):
		hud.show_death(lost)


# ---------------------------------------------------------------------------
# Stage flow
# ---------------------------------------------------------------------------
func respawn_player() -> void:
	if player == null or not is_instance_valid(player):
		return
	player.respawn(spawn_point)


func go_to_stage(number: int, direction: int = 0) -> void:
	GameState.set_stage(number, direction)
	get_tree().paused = false
	get_tree().reload_current_scene()


# ---------------------------------------------------------------------------
# Backdrop
# ---------------------------------------------------------------------------
func _palette() -> Dictionary:
	var palettes: Array = [
		{ "sky": Color(0.52, 0.76, 0.94), "far": Color(0.58, 0.72, 0.86), "near": Color(0.34, 0.58, 0.42),
			"ground": Color(0.40, 0.30, 0.20), "top": Color(0.36, 0.62, 0.28), "plat": Color(0.46, 0.36, 0.24) },
		{ "sky": Color(0.96, 0.78, 0.52), "far": Color(0.82, 0.66, 0.48), "near": Color(0.68, 0.48, 0.30),
			"ground": Color(0.62, 0.45, 0.26), "top": Color(0.82, 0.68, 0.36), "plat": Color(0.72, 0.54, 0.32) },
		{ "sky": Color(0.30, 0.34, 0.52), "far": Color(0.34, 0.36, 0.52), "near": Color(0.24, 0.26, 0.38),
			"ground": Color(0.22, 0.22, 0.28), "top": Color(0.32, 0.36, 0.44), "plat": Color(0.30, 0.30, 0.38) },
		{ "sky": Color(0.66, 0.86, 0.86), "far": Color(0.56, 0.78, 0.80), "near": Color(0.30, 0.62, 0.66),
			"ground": Color(0.30, 0.46, 0.46), "top": Color(0.56, 0.82, 0.70), "plat": Color(0.38, 0.58, 0.56) },
		{ "sky": Color(0.86, 0.62, 0.58), "far": Color(0.70, 0.50, 0.52), "near": Color(0.48, 0.32, 0.38),
			"ground": Color(0.34, 0.24, 0.26), "top": Color(0.62, 0.38, 0.36), "plat": Color(0.46, 0.30, 0.30) },
		{ "sky": Color(0.58, 0.70, 0.92), "far": Color(0.62, 0.66, 0.82), "near": Color(0.40, 0.46, 0.62),
			"ground": Color(0.36, 0.34, 0.38), "top": Color(0.62, 0.66, 0.74), "plat": Color(0.48, 0.46, 0.52) },
	]
	return palettes[(stage_number - 1) % palettes.size()]


func _draw() -> void:
	var palette := _palette()
	var sky: Color = palette["sky"]
	var far: Color = palette["far"]
	var near: Color = palette["near"]
	var ground: Color = palette["ground"]
	var top: Color = palette["top"]
	var plat: Color = palette["plat"]

	# Sky
	draw_rect(Rect2(-600.0, -2200.0, world_width + 1200.0, 3000.0), sky)

	# Sun / moon
	draw_circle(Vector2(world_width * 0.72, -260.0), 68.0, Color(1.0, 0.96, 0.78, 0.75))
	draw_circle(Vector2(world_width * 0.72, -260.0), 96.0, Color(1.0, 0.96, 0.78, 0.16))

	# Distant mountains
	var mountain_rng := RandomNumberGenerator.new()
	mountain_rng.seed = stage_number * 7919
	var x := -200.0
	while x < world_width + 400.0:
		var peak := mountain_rng.randf_range(180.0, 360.0)
		var width := mountain_rng.randf_range(260.0, 420.0)
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, GROUND_Y), Vector2(x + width * 0.5, GROUND_Y - peak), Vector2(x + width, GROUND_Y),
		]), far)
		x += width * 0.72

	# Near hills
	var hill_rng := RandomNumberGenerator.new()
	hill_rng.seed = stage_number * 31337
	x = -160.0
	while x < world_width + 300.0:
		var radius := hill_rng.randf_range(120.0, 230.0)
		draw_circle(Vector2(x, GROUND_Y + radius * 0.35), radius, near)
		x += radius * 1.35

	# Clouds
	var cloud_rng := RandomNumberGenerator.new()
	cloud_rng.seed = stage_number * 57
	for i in range(16):
		var cloud_pos := Vector2(cloud_rng.randf_range(0.0, world_width), cloud_rng.randf_range(-620.0, -140.0))
		var cloud_scale := cloud_rng.randf_range(0.7, 1.5)
		var cloud_color := Color(1.0, 1.0, 1.0, 0.55)
		draw_circle(cloud_pos, 32.0 * cloud_scale, cloud_color)
		draw_circle(cloud_pos + Vector2(34.0, 6.0) * cloud_scale, 26.0 * cloud_scale, cloud_color)
		draw_circle(cloud_pos + Vector2(-32.0, 8.0) * cloud_scale, 24.0 * cloud_scale, cloud_color)

	# Hilly ground
	var ground_poly := PackedVector2Array(_ground_pts)
	ground_poly.append(Vector2(world_width + 600.0, GROUND_Y + 500.0))
	ground_poly.append(Vector2(-500.0, GROUND_Y + 500.0))
	draw_colored_polygon(ground_poly, ground)
	# Ground top edge (ridge line)
	for i in range(_ground_pts.size() - 1):
		draw_line(_ground_pts[i], _ground_pts[i + 1], top.lightened(0.1), 2.0)

	# Platforms
	for rect in _platform_rects:
		var r: Rect2 = rect
		draw_rect(r, plat)
		draw_rect(Rect2(r.position, Vector2(r.size.x, 7.0)), top.lightened(0.08))
		draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - 5.0), Vector2(r.size.x, 5.0)), plat.darkened(0.3))

	# Ramps / hills
	for pts in _ramp_polys:
		draw_colored_polygon(pts, plat)
		draw_line(pts[2], pts[1], top.lightened(0.12), 2.0)

	# Ground decoration: trees, rocks and bushes (snapped to ground, clear of
	# the town NPC area and the hotbar bottom zone).
	var deco_rng := RandomNumberGenerator.new()
	deco_rng.seed = stage_number * 99991
	var deco_count := maxi(24, int(world_width / 140.0))
	for i in range(deco_count):
		var deco_x := deco_rng.randf_range(40.0, world_width - 40.0)
		# Skip the town NPC/sign area so decorations don't crowd it.
		if deco_x < TOWN_RIGHT - 60.0:
			continue
		var deco_y := _ground_y_at(deco_x)
		# Keep decorations above the hotbar zone on screen.
		if deco_y > HOTBAR_Y - 40.0:
			continue
		var kind := i % 3
		if kind == 0:
			draw_rect(Rect2(deco_x - 5.0, deco_y - 54.0, 10.0, 54.0), Color(0.34, 0.24, 0.15))
			draw_circle(Vector2(deco_x, deco_y - 74.0), 28.0, top.darkened(0.18))
			draw_circle(Vector2(deco_x - 18.0, deco_y - 62.0), 20.0, top.darkened(0.1))
			draw_circle(Vector2(deco_x + 18.0, deco_y - 62.0), 20.0, top.darkened(0.12))
		elif kind == 1:
			draw_circle(Vector2(deco_x, deco_y - 12.0), 18.0, Color(0.52, 0.52, 0.56))
			draw_circle(Vector2(deco_x - 12.0, deco_y - 8.0), 12.0, Color(0.46, 0.46, 0.5))
		else:
			draw_circle(Vector2(deco_x, deco_y - 10.0), 16.0, top.darkened(0.05))
			draw_circle(Vector2(deco_x + 14.0, deco_y - 8.0), 12.0, top.darkened(0.1))

	# Stage sign near the spawn point
	var sign_x := 240.0
	draw_rect(Rect2(sign_x - 3.0, GROUND_Y - 70.0, 6.0, 70.0), Color(0.38, 0.26, 0.16))
	draw_rect(Rect2(sign_x - 62.0, GROUND_Y - 106.0, 124.0, 40.0), Color(0.52, 0.36, 0.20))
	draw_string(ThemeDB.fallback_font, Vector2(sign_x - 60.0, GROUND_Y - 80.0),
		"#%d %s" % [stage_number, str(stage_data.get("name", "Stage"))],
		HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(0.98, 0.94, 0.82))
