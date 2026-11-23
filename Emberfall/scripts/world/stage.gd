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
var _pillar_rects: Array[Rect2] = []
var _underground_rects: Array[Rect2] = []
var _underground_ceiling_rects: Array[Rect2] = []
var _ground_pts: Array[Vector2] = []
var _enemy_spawns: Array[Vector2] = []
var _portal_positions: Array[Vector2] = []
var _npc_positions: Array[Vector2] = []
var _rng := RandomNumberGenerator.new()

# Procedural dungeon layout & chamber state
var _layout_archetype := 0
var _chamber_count := 4
var _chambers: Array[Dictionary] = []
var _torch_positions: Array[Vector2] = []
var _ug_entrance_x := 0.0
var _ug_entrance_w := 150.0
var _ug_exit_x := 0.0
var _ug_exit_w := 150.0
var _ug_floor1_y := 0.0
var _ug_floor2_y := 0.0
var _ug_floor3_y := 0.0
var _ug_floor_y := 0.0
var _summit_x := 0.0
var _summit_y := 0.0
var _summit_w := 240.0
var _forward_portal_pos := Vector2()


func _ready() -> void:
	add_to_group("stage")
	stage_number = maxi(1, GameState.current_stage)
	stage_data = GameData.stage(stage_number)
	if stage_data.is_empty():
		stage_data = {"number": stage_number, "name": "Unknown Stage", "npcs": [], "monsters": []}

	world_width = 3800.0 + float(mini(stage_number, 120)) * 25.0
	_rng.seed = stage_number * 104729 + 17

	_init_layout_params()
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


func _init_layout_params() -> void:
	# 4 distinct layout archetypes that cycle per stage
	_layout_archetype = (stage_number - 1) % 4
	# Chamber count varies (3, 4, or 5 chambers)
	_chamber_count = 3 + ((stage_number * 3 + 1) % 3)

	var start_x := TRANSITION_END + 40.0
	var playable_width := world_width - start_x - 300.0

	_summit_w = 240.0
	_summit_x = world_width - 320.0
	# Summit elevation varies per stage
	_summit_y = ENEMY_ZONE_Y - 170.0 - float((stage_number % 3) * 35)
	_forward_portal_pos = Vector2(_summit_x + 120.0, _summit_y)

	_ug_entrance_w = 150.0
	_ug_exit_w = 150.0

	# 3 subterranean levels for an expansive, multi-tier underground dungeon network:
	# Level 1: Upper Crypt / Mezzanine Walkways (generous 114px headroom below roof)
	# Level 2: Mid Catacomb Vaults (generous 170px headroom below Level 1)
	# Level 3: Deep Sunken Abyss / Bottom Cavern (generous 170-190px headroom below Level 2)
	_ug_floor1_y = ENEMY_ZONE_Y + 150.0
	_ug_floor2_y = ENEMY_ZONE_Y + 320.0
	_ug_floor3_y = ENEMY_ZONE_Y + 490.0

	match _layout_archetype:
		0:
			# Archetype 0: "The Catacomb Network" — Deep, expansive underground cavern network
			_ug_entrance_x = start_x + 90.0
			_ug_exit_x = _summit_x - 240.0
			_ug_floor3_y = ENEMY_ZONE_Y + 520.0
		1:
			# Archetype 1: "The Grand Colonnade" — Central sunken crypt beneath grand pillars
			_ug_entrance_x = start_x + playable_width * 0.26
			_ug_exit_x = start_x + playable_width * 0.74
			_ug_floor3_y = ENEMY_ZONE_Y + 480.0
		2:
			# Archetype 2: "The Ruined High Spire" — Left deep well with steep vertical ascent
			_ug_entrance_x = start_x + 120.0
			_ug_exit_x = start_x + playable_width * 0.55
			_ug_floor3_y = ENEMY_ZONE_Y + 540.0
		_:
			# Archetype 3: "The Fortress Bastion" — Gatehouse fortress with fortified subterranean crypt
			_ug_entrance_x = start_x + playable_width * 0.18
			_ug_exit_x = _summit_x - 200.0
			_ug_floor3_y = ENEMY_ZONE_Y + 500.0

	_ug_floor_y = _ug_floor3_y


func _build_bounds() -> void:
	# Side walls extending down to accommodate deep subterranean levels
	_add_static_rect(Rect2(-70.0, GROUND_Y - 2200.0, 50.0, 4200.0))
	_add_static_rect(Rect2(world_width + 20.0, GROUND_Y - 2200.0, 50.0, 4200.0))

	# Continuous surface ridge line for sample points and town area
	var seg := 40.0
	var x := -500.0
	_ground_pts = []
	while x < world_width + 600.0:
		var y: float
		if x <= TOWN_RIGHT:
			y = GROUND_Y  # safe town flat
		elif x <= TRANSITION_END:
			var t := (x - TOWN_RIGHT) / (TRANSITION_END - TOWN_RIGHT)
			y = lerpf(GROUND_Y, ENEMY_ZONE_Y, t)
		else:
			y = ENEMY_ZONE_Y  # elevated enemy area flat
		_ground_pts.append(Vector2(x, y))
		x += seg

	# Segmented ground collision with physical shaft gaps for underground access:
	# Segment A: Town flat and ramp up to entrance shaft
	var poly_a := PackedVector2Array()
	for pt in _ground_pts:
		if pt.x <= _ug_entrance_x:
			poly_a.append(pt)
	poly_a.append(Vector2(_ug_entrance_x, GROUND_Y + 1200.0))
	poly_a.append(Vector2(-500.0, GROUND_Y + 1200.0))
	var body_a := StaticBody2D.new()
	body_a.collision_layer = 1
	body_a.collision_mask = 0
	var col_a := CollisionPolygon2D.new()
	col_a.polygon = poly_a
	body_a.add_child(col_a)
	add_child(body_a)

	# Segment B: Surface roof between entrance and exit shafts (walkable stone roof)
	var poly_b := PackedVector2Array()
	var roof_start := _ug_entrance_x + _ug_entrance_w
	var roof_end := _ug_exit_x
	poly_b.append(Vector2(roof_start, ENEMY_ZONE_Y))
	poly_b.append(Vector2(roof_end, ENEMY_ZONE_Y))
	poly_b.append(Vector2(roof_end, ENEMY_ZONE_Y + 36.0))
	poly_b.append(Vector2(roof_start, ENEMY_ZONE_Y + 36.0))
	var body_b := StaticBody2D.new()
	body_b.collision_layer = 1
	body_b.collision_mask = 0
	var col_b := CollisionPolygon2D.new()
	col_b.polygon = poly_b
	body_b.add_child(col_b)
	add_child(body_b)

	# Segment C: Right ground after exit shaft leading up to summit
	var poly_c := PackedVector2Array()
	var exit_end := _ug_exit_x + _ug_exit_w
	for pt in _ground_pts:
		if pt.x >= exit_end:
			poly_c.append(pt)
	poly_c.append(Vector2(world_width + 600.0, GROUND_Y + 1200.0))
	poly_c.append(Vector2(exit_end, GROUND_Y + 1200.0))
	var body_c := StaticBody2D.new()
	body_c.collision_layer = 1
	body_c.collision_mask = 0
	var col_c := CollisionPolygon2D.new()
	col_c.polygon = poly_c
	body_c.add_child(col_c)
	add_child(body_c)


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
	_platform_rects.clear()
	_pillar_rects.clear()
	_underground_rects.clear()
	_underground_ceiling_rects.clear()
	_chambers.clear()
	_torch_positions.clear()

	var start_x := TRANSITION_END + 40.0
	var playable_width := world_width - start_x - 300.0
	var chamber_w := playable_width / float(_chamber_count)

	# Thematic chamber names cycling by archetype
	var chamber_names: Array = []
	match _layout_archetype:
		0:
			chamber_names = ["Outer Courtyard", "Sunken Lair", "Tomb of Shadows", "Chamber of Relics", "Sanctuary"]
		1:
			chamber_names = ["Pillar Colonnade", "Grand Hall", "High Gallery", "The Bastion", "Portal Arch"]
		2:
			chamber_names = ["Lower Ruins", "Stepped Ascent", "Belfry Ascent", "High Spire", "Sky Sanctuary"]
		_:
			chamber_names = ["Outer Gatehouse", "Fortress Moat", "The Armory", "Inner Keep", "Portal Spire"]

	# 1. Define chambers and place solid partition pillars between them
	for i in range(_chamber_count):
		var c_start := start_x + float(i) * chamber_w
		var c_end := start_x + float(i + 1) * chamber_w
		var c_name: String = chamber_names[i % chamber_names.size()]
		_chambers.append({
			"index": i,
			"start_x": c_start,
			"end_x": c_end,
			"name": "Chamber %d: %s" % [i + 1, c_name]
		})

		# Partition pillar between chamber i and i+1
		if i > 0:
			var pillar_x := c_start - 30.0
			var pillar_w := 60.0
			var pillar_h := _rng.randf_range(280.0, 390.0)
			var pillar_y := ENEMY_ZONE_Y - pillar_h

			# Leave an open 80px archway at ground level so players and monsters walk freely between chambers
			var p_rect := Rect2(pillar_x, pillar_y, pillar_w, pillar_h - 80.0)
			_pillar_rects.append(p_rect)
			_add_static_rect(p_rect, false) # Solid arch above, walk-through below

			# Stepping stone platforms on and around the partition pillar
			var step_up := Rect2(pillar_x - 110.0, ENEMY_ZONE_Y - 80.0, 85.0, 20.0)
			_platform_rects.append(step_up)
			_add_static_rect(step_up, true)

			var step_mid := Rect2(pillar_x - 70.0, ENEMY_ZONE_Y - 160.0, 85.0, 20.0)
			_platform_rects.append(step_mid)
			_add_static_rect(step_mid, true)

			var step_top := Rect2(pillar_x - 14.0, pillar_y - 20.0, pillar_w + 28.0, 20.0)
			_platform_rects.append(step_top)
			_add_static_rect(step_top, true)

			var step_down_mid := Rect2(pillar_x + pillar_w - 15.0, ENEMY_ZONE_Y - 160.0, 85.0, 20.0)
			_platform_rects.append(step_down_mid)
			_add_static_rect(step_down_mid, true)

			var step_down := Rect2(pillar_x + pillar_w + 25.0, ENEMY_ZONE_Y - 80.0, 85.0, 20.0)
			_platform_rects.append(step_down)
			_add_static_rect(step_down, true)

			# Wall sconces mounted on partition pillar
			_torch_positions.append(Vector2(pillar_x + pillar_w * 0.5, pillar_y + 90.0))

	# 2. Chamber interior: Small obstacle pillars & platform tiers
	for c_idx in range(_chambers.size()):
		var ch: Dictionary = _chambers[c_idx]
		var c_start: float = ch["start_x"] + 60.0
		var c_end: float = ch["end_x"] - 60.0

		# Small decorative obelisk pillars within this chamber with jumpable platform caps
		var small_count := 1 + (_rng.randi() % 2)
		for sp in range(small_count):
			var sp_x := c_start + float(sp + 1) * ((c_end - c_start) / float(small_count + 1)) - 15.0
			# Don't place small pillars right inside entrance or exit shaft openings
			if (sp_x >= _ug_entrance_x - 20.0 and sp_x <= _ug_entrance_x + _ug_entrance_w + 20.0) or \
			   (sp_x >= _ug_exit_x - 20.0 and sp_x <= _ug_exit_x + _ug_exit_w + 20.0):
				continue
			var sp_w := _rng.randf_range(28.0, 38.0)
			var sp_h := _rng.randf_range(70.0, 110.0)
			var sp_rect := Rect2(sp_x, ENEMY_ZONE_Y - sp_h, sp_w, sp_h)
			_pillar_rects.append(sp_rect)
			# Only add jumpable top cap, not solid body, so monsters/players never get stuck on ground
			var sp_cap := Rect2(sp_x - 4.0, ENEMY_ZONE_Y - sp_h - 10.0, sp_w + 8.0, 14.0)
			_platform_rects.append(sp_cap)
			_add_static_rect(sp_cap, true)

			# Small torch on the pillar
			_torch_positions.append(Vector2(sp_x + sp_w * 0.5, ENEMY_ZONE_Y - sp_h * 0.5))

		# Multi-tier vertical platform levels reaching high up into the sky
		# 5 distinct elevation tiers per chamber, each with multiple staggered platforms
		var tier_elevations: Array[float] = [
			ENEMY_ZONE_Y - 80.0,   # Tier 1: Low walkways, easily jumpable from ground
			ENEMY_ZONE_Y - 165.0,  # Tier 2: Mid-low platforms
			ENEMY_ZONE_Y - 250.0,  # Tier 3: Central battlements
			ENEMY_ZONE_Y - 335.0,  # Tier 4: High ramparts
			ENEMY_ZONE_Y - 420.0   # Tier 5: Sky bridges / Spire tops
		]
		if _layout_archetype == 2:
			# High Spire: Steeper vertical ascent reaching up to ENEMY_ZONE_Y - 465
			var rise := float(c_idx) * 40.0
			tier_elevations = [
				ENEMY_ZONE_Y - 85.0 - rise,
				ENEMY_ZONE_Y - 170.0 - rise,
				ENEMY_ZONE_Y - 255.0 - rise,
				ENEMY_ZONE_Y - 340.0 - rise,
				ENEMY_ZONE_Y - 425.0 - rise
			]

		for t_idx in range(tier_elevations.size()):
			var t_y: float = tier_elevations[t_idx]
			if t_y < ENEMY_ZONE_Y - 500.0:
				continue

			# Stagger each tier horizontally so platforms create natural jumping paths
			var t_start: float = c_start + 20.0 + float((t_idx * 75) % 150)
			var cur_x := t_start
			while cur_x < c_end - 50.0:
				var p_w := _rng.randf_range(160.0, 260.0)
				if cur_x + p_w > c_end - 15.0:
					p_w = (c_end - 15.0) - cur_x
				if p_w < 80.0:
					break

				# Keep entrance and exit shafts unobstructed from directly above
				var overlaps_entrance := (cur_x + p_w >= _ug_entrance_x - 15.0 and cur_x <= _ug_entrance_x + _ug_entrance_w + 15.0)
				var overlaps_exit := (cur_x + p_w >= _ug_exit_x - 15.0 and cur_x <= _ug_exit_x + _ug_exit_w + 15.0)

				if overlaps_entrance:
					cur_x = _ug_entrance_x + _ug_entrance_w + 25.0
					continue
				if overlaps_exit:
					cur_x = _ug_exit_x + _ug_exit_w + 25.0
					continue

				var p_rect := Rect2(cur_x, t_y, p_w, 22.0)
				_platform_rects.append(p_rect)
				_add_static_rect(p_rect, true)

				# Intermediate stepping stone platform connecting to the tier above
				if t_idx < tier_elevations.size() - 1 and _rng.randf() < 0.6:
					var step_x := cur_x + p_w + 12.0
					var next_y: float = tier_elevations[t_idx + 1]
					var step_y := (t_y + next_y) * 0.5
					var step_w := _rng.randf_range(65.0, 85.0)
					if step_x + step_w < c_end - 25.0 and \
					   not (step_x + step_w >= _ug_entrance_x - 15.0 and step_x <= _ug_entrance_x + _ug_entrance_w + 15.0) and \
					   not (step_x + step_w >= _ug_exit_x - 15.0 and step_x <= _ug_exit_x + _ug_exit_w + 15.0):
						var step_r := Rect2(step_x, step_y, step_w, 18.0)
						_platform_rects.append(step_r)
						_add_static_rect(step_r, true)

				cur_x += p_w + _rng.randf_range(65.0, 120.0)

	# 3. Final Summit Platform for the Forward Portal
	var summit_rect := Rect2(_summit_x, _summit_y, _summit_w, 26.0)
	_platform_rects.append(summit_rect)
	_add_static_rect(summit_rect, true)

	# Stepping stone platforms leading up to the summit
	var step_app1 := Rect2(_summit_x - 120.0, _summit_y + 80.0, 90.0, 20.0)
	var step_app2 := Rect2(_summit_x - 220.0, _summit_y + 150.0, 80.0, 20.0)
	_platform_rects.append(step_app1)
	_platform_rects.append(step_app2)
	_add_static_rect(step_app1, true)
	_add_static_rect(step_app2, true)

	# 4. Multi-Level Underground Cavern Dungeon Network (Level 1, Level 2, Level 3)
	# Solid Deep Bottom Cavern Floor (Level 3)
	var ug_floor := Rect2(_ug_entrance_x, _ug_floor3_y, (_ug_exit_x + _ug_exit_w) - _ug_entrance_x, 36.0)
	_underground_rects.append(ug_floor)
	_add_static_rect(ug_floor, false) # Solid bottom floor

	# Surface Entrance Shaft steps: Descend smoothly from surface (420) into Level 1 (_ug_floor1_y)
	var e_step1 := Rect2(_ug_entrance_x + 15.0, ENEMY_ZONE_Y + 52.0, 90.0, 18.0)
	var e_step2 := Rect2(_ug_entrance_x + 45.0, ENEMY_ZONE_Y + 105.0, 90.0, 18.0)
	_platform_rects.append(e_step1)
	_platform_rects.append(e_step2)
	_add_static_rect(e_step1, true)
	_add_static_rect(e_step2, true)

	# Surface Exit Shaft steps: Ascend smoothly from subterranean levels out to surface
	var x_step1 := Rect2(_ug_exit_x - 10.0, _ug_floor2_y + 65.0, 90.0, 18.0)
	var x_step2 := Rect2(_ug_exit_x + 15.0, _ug_floor2_y, 90.0, 18.0)
	var x_step3 := Rect2(_ug_exit_x + 15.0, _ug_floor1_y + 75.0, 90.0, 18.0)
	var x_step4 := Rect2(_ug_exit_x + 35.0, _ug_floor1_y, 90.0, 18.0)
	var x_step5 := Rect2(_ug_exit_x + 55.0, ENEMY_ZONE_Y + 70.0, 90.0, 18.0)
	_platform_rects.append(x_step1)
	_platform_rects.append(x_step2)
	_platform_rects.append(x_step3)
	_platform_rects.append(x_step4)
	_platform_rects.append(x_step5)
	_add_static_rect(x_step1, true)
	_add_static_rect(x_step2, true)
	_add_static_rect(x_step3, true)
	_add_static_rect(x_step4, true)
	_add_static_rect(x_step5, true)

	# --- LEVEL 1: Upper Crypt Catwalks (y = _ug_floor1_y) ---
	# Open catwalks spanning across the upper subterranean level with NO solid pillars
	var l1_x := _ug_entrance_x + _ug_entrance_w + 10.0
	while l1_x < _ug_exit_x - 60.0:
		var l1_w := _rng.randf_range(180.0, 280.0)
		if l1_x + l1_w > _ug_exit_x - 20.0:
			l1_w = (_ug_exit_x - 20.0) - l1_x
		if l1_w >= 80.0:
			var l1_plat := Rect2(l1_x, _ug_floor1_y, l1_w, 20.0)
			_platform_rects.append(l1_plat)
			_add_static_rect(l1_plat, true)

			# Wall torch mounted on background cavern wall (NO solid blocking body!)
			_torch_positions.append(Vector2(l1_x + l1_w * 0.5, _ug_floor1_y - 30.0))

		# Descending stone steps connecting Level 1 -> Level 2
		var s1 := Rect2(l1_x + l1_w + 15.0, _ug_floor1_y + 55.0, 85.0, 18.0)
		var s2 := Rect2(l1_x + l1_w + 55.0, _ug_floor1_y + 115.0, 85.0, 18.0)
		_platform_rects.append(s1)
		_platform_rects.append(s2)
		_add_static_rect(s1, true)
		_add_static_rect(s2, true)

		l1_x += l1_w + 130.0

	# --- LEVEL 2: Mid Catacombs Platforms & Chambers (y = _ug_floor2_y) ---
	# Spacious middle platforms spanning across catacombs with NO solid pillars
	var l2_x := _ug_entrance_x + _ug_entrance_w + 40.0
	while l2_x < _ug_exit_x - 60.0:
		var l2_w := _rng.randf_range(190.0, 290.0)
		if l2_x + l2_w > _ug_exit_x - 20.0:
			l2_w = (_ug_exit_x - 20.0) - l2_x
		if l2_w >= 80.0:
			var l2_plat := Rect2(l2_x, _ug_floor2_y, l2_w, 20.0)
			_platform_rects.append(l2_plat)
			_add_static_rect(l2_plat, true)

			# Wall torch mounted on background cavern wall (NO solid blocking body!)
			_torch_positions.append(Vector2(l2_x + l2_w * 0.5, _ug_floor2_y - 30.0))

		# Descending stone steps connecting Level 2 -> Level 3
		var s2_1 := Rect2(l2_x + l2_w + 15.0, _ug_floor2_y + 60.0, 85.0, 18.0)
		var s2_2 := Rect2(l2_x + l2_w + 55.0, _ug_floor2_y + 120.0, 85.0, 18.0)
		_platform_rects.append(s2_1)
		_platform_rects.append(s2_2)
		_add_static_rect(s2_1, true)
		_add_static_rect(s2_2, true)

		l2_x += l2_w + 130.0

	# --- LEVEL 3: Deep Sunken Abyss Interior Platforms & Ledges ---
	# Raised platforms within the bottom cavern floor
	var l3_x := _ug_entrance_x + _ug_entrance_w + 20.0
	while l3_x < _ug_exit_x - 80.0:
		var l3_w := _rng.randf_range(140.0, 220.0)
		var l3_elev := _ug_floor3_y - _rng.randf_range(60.0, 85.0)
		var l3_plat := Rect2(l3_x, l3_elev, l3_w, 20.0)
		_platform_rects.append(l3_plat)
		_add_static_rect(l3_plat, true)

		# Deep abyss wall torch
		_torch_positions.append(Vector2(l3_x + l3_w * 0.5, l3_elev - 35.0))

		l3_x += l3_w + _rng.randf_range(110.0, 170.0)


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
		at = Vector2(_forward_portal_pos.x, _forward_portal_pos.y - 4.0)
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
		player.camera.limit_bottom = int(_ug_floor3_y + 180.0)


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
	backdrop.color = Color(0, 0, 0, 0.6)
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
	frame.custom_minimum_size = Vector2(370, 290)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.11, 0.17, 0.98)
	style.set_corner_radius_all(14)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(1.0, 0.78, 0.3)
	style.shadow_color = Color(0, 0, 0, 0.8)
	style.shadow_size = 22
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	frame.add_theme_stylebox_override("panel", style)
	center.add_child(frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	frame.add_child(vbox)

	# Header: Avatar + Name + Class/Level + Close 'X'
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	vbox.add_child(header)

	var avatar := PanelContainer.new()
	avatar.custom_minimum_size = Vector2(44, 44)
	var av_style := StyleBoxFlat.new()
	av_style.bg_color = Color(0.15, 0.25, 0.45, 0.9)
	av_style.set_corner_radius_all(10)
	av_style.set_border_width_all(1)
	av_style.border_color = Color(0.4, 0.7, 1.0, 0.7)
	avatar.add_theme_stylebox_override("panel", av_style)
	header.add_child(avatar)

	var av_lbl := Label.new()
	match rclass.to_lower():
		"mage": av_lbl.text = "🧙"
		"archer": av_lbl.text = "🏹"
		"warrior": av_lbl.text = "⚔"
		"paladin": av_lbl.text = "🛡"
		_: av_lbl.text = "👤"
	av_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	av_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	av_lbl.add_theme_font_size_override("font_size", 20)
	avatar.add_child(av_lbl)

	var name_box := VBoxContainer.new()
	name_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_box.add_theme_constant_override("separation", 2)
	header.add_child(name_box)

	var name_lbl := Label.new()
	name_lbl.text = rname
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	name_box.add_child(name_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = "%s  •  Level %d" % [rclass, rlevel]
	sub_lbl.add_theme_font_size_override("font_size", 12)
	sub_lbl.add_theme_color_override("font_color", Color(0.65, 0.8, 0.95))
	name_box.add_child(sub_lbl)

	var x_btn := Button.new()
	x_btn.text = "✕"
	x_btn.custom_minimum_size = Vector2(28, 28)
	x_btn.flat = true
	x_btn.add_theme_font_size_override("font_size", 13)
	x_btn.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	x_btn.pressed.connect(func(): canvas.queue_free())
	header.add_child(x_btn)

	# Equipment overview card
	var eq_box := PanelContainer.new()
	var eq_style := StyleBoxFlat.new()
	eq_style.bg_color = Color(0.05, 0.08, 0.13, 0.85)
	eq_style.set_corner_radius_all(10)
	eq_style.set_border_width_all(1)
	eq_style.border_color = Color(0.2, 0.3, 0.45, 0.4)
	eq_style.content_margin_left = 12
	eq_style.content_margin_right = 12
	eq_style.content_margin_top = 8
	eq_style.content_margin_bottom = 8
	eq_box.add_theme_stylebox_override("panel", eq_style)
	vbox.add_child(eq_box)

	var eq_vbox := VBoxContainer.new()
	eq_vbox.add_theme_constant_override("separation", 5)
	eq_box.add_child(eq_vbox)

	var weapon_name := str(req.get("weapon", "None"))
	var armor_name := str(req.get("armor", "None"))
	var helmet_name := str(req.get("helmet", "None"))
	var shield_name := str(req.get("shield", "None"))

	var gear_list: Array = [
		{"icon": "⚔", "slot": "Weapon", "item": weapon_name},
		{"icon": "🛡", "slot": "Armor", "item": armor_name},
		{"icon": "🪖", "slot": "Helmet", "item": helmet_name},
	]
	if shield_name != "" and shield_name != "None":
		gear_list.append({"icon": "🔰", "slot": "Shield", "item": shield_name})

	for g in gear_list:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		eq_vbox.add_child(row)

		var icon_lbl := Label.new()
		icon_lbl.text = g["icon"]
		icon_lbl.add_theme_font_size_override("font_size", 12)
		row.add_child(icon_lbl)

		var slot_lbl := Label.new()
		slot_lbl.text = "%s:" % g["slot"]
		slot_lbl.custom_minimum_size = Vector2(56, 0)
		slot_lbl.add_theme_font_size_override("font_size", 11)
		slot_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.82))
		row.add_child(slot_lbl)

		var item_lbl := Label.new()
		var iname: String = g["item"] if g["item"] != "" else "None"
		item_lbl.text = iname
		item_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item_lbl.add_theme_font_size_override("font_size", 11)
		if iname != "None":
			item_lbl.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
		else:
			item_lbl.add_theme_color_override("font_color", Color(0.45, 0.48, 0.55))
		row.add_child(item_lbl)

	# Action Buttons Row
	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 10)
	vbox.add_child(actions)

	# 1. Trade Button (Emerald Green)
	var trade_btn := Button.new()
	trade_btn.text = "🤝 TRADE"
	trade_btn.custom_minimum_size = Vector2(100, 38)
	trade_btn.add_theme_font_size_override("font_size", 12)
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = Color(0.14, 0.48, 0.26, 0.95)
	tsb.set_corner_radius_all(8)
	trade_btn.add_theme_stylebox_override("normal", tsb)
	trade_btn.pressed.connect(func():
		canvas.queue_free()
		Network.request_trade(pid)
		GameState.message.emit("Sent trade request to %s..." % rname)
	)
	actions.add_child(trade_btn)

	# 2. Add Friend Button (Royal Purple)
	var friend_btn := Button.new()
	friend_btn.text = "👥 FRIEND"
	friend_btn.custom_minimum_size = Vector2(100, 38)
	friend_btn.add_theme_font_size_override("font_size", 12)
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0.36, 0.22, 0.58, 0.95)
	fsb.set_corner_radius_all(8)
	friend_btn.add_theme_stylebox_override("normal", fsb)
	friend_btn.pressed.connect(func():
		canvas.queue_free()
		if not Api.token.is_empty():
			Api.send_friend_request(rname)
			Network.notify_friend_request(rname)
		else:
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

	# 3. Stats Button (Slate/Cyan)
	var stats_btn := Button.new()
	stats_btn.text = "📊 STATS"
	stats_btn.custom_minimum_size = Vector2(95, 38)
	stats_btn.add_theme_font_size_override("font_size", 12)
	var ssb := StyleBoxFlat.new()
	ssb.bg_color = Color(0.18, 0.28, 0.42, 0.95)
	ssb.set_corner_radius_all(8)
	stats_btn.add_theme_stylebox_override("normal", ssb)
	stats_btn.pressed.connect(func():
		canvas.queue_free()
		_show_player_stats_inspection(rplayer)
	)
	actions.add_child(stats_btn)

	# Bottom Close Button
	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.custom_minimum_size = Vector2(110, 32)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.add_theme_font_size_override("font_size", 11)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.2, 0.22, 0.28, 0.8)
	csb.set_corner_radius_all(6)
	close_btn.add_theme_stylebox_override("normal", csb)
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
	var canvas := CanvasLayer.new()
	canvas.layer = 98
	add_child(canvas)

	# Dimmed backdrop
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.5)
	canvas.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(400, 190)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.12, 0.18, 0.98)
	style.set_corner_radius_all(14)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(1.0, 0.78, 0.28)
	style.shadow_color = Color(0, 0, 0, 0.75)
	style.shadow_size = 20
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 18
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "🤝  TRADE REQUEST"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	vbox.add_child(title)

	var msg := Label.new()
	msg.text = "%s wants to trade with you!" % from_name
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 14)
	msg.add_theme_color_override("font_color", Color(0.9, 0.94, 1.0))
	vbox.add_child(msg)

	var timer_lbl := Label.new()
	timer_lbl.text = "Request expires in 15s"
	timer_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_lbl.add_theme_font_size_override("font_size", 11)
	timer_lbl.add_theme_color_override("font_color", Color(0.6, 0.65, 0.75))
	vbox.add_child(timer_lbl)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(hbox)

	var accept_btn := Button.new()
	accept_btn.text = "ACCEPT"
	accept_btn.custom_minimum_size = Vector2(130, 38)
	accept_btn.add_theme_font_size_override("font_size", 13)
	var accept_style := StyleBoxFlat.new()
	accept_style.bg_color = Color(0.18, 0.58, 0.32, 1.0)
	accept_style.set_corner_radius_all(8)
	accept_btn.add_theme_stylebox_override("normal", accept_style)
	accept_btn.pressed.connect(func():
		canvas.queue_free()
		Network.respond_trade(from_id, true)
		if is_instance_valid(trade_panel):
			trade_panel.open(from_id, from_name)
	)
	hbox.add_child(accept_btn)

	var decline_btn := Button.new()
	decline_btn.text = "DECLINE"
	decline_btn.custom_minimum_size = Vector2(130, 38)
	decline_btn.add_theme_font_size_override("font_size", 13)
	var decline_style := StyleBoxFlat.new()
	decline_style.bg_color = Color(0.68, 0.22, 0.22, 1.0)
	decline_style.set_corner_radius_all(8)
	decline_btn.add_theme_stylebox_override("normal", decline_style)
	decline_btn.pressed.connect(func():
		canvas.queue_free()
		Network.respond_trade(from_id, false)
	)
	hbox.add_child(decline_btn)

	get_tree().create_timer(15.0).timeout.connect(func():
		if is_instance_valid(canvas):
			canvas.queue_free()
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

	# Forward portal placed on the elevated puzzle summit platform
	var next: Variant = stage_data.get("next", null)
	if typeof(next) == TYPE_DICTIONARY and next != null:
		var next_number := int(next.get("number", 0))
		if next_number > 0 and not GameData.stage(next_number).is_empty():
			var next_portal: Portal = PORTAL_SCENE.instantiate()
			next_portal.position = _forward_portal_pos
			add_child(next_portal)
			next_portal.setup(next_number, 1)
			_portal_positions.append(_forward_portal_pos)


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

	_enemy_spawns = []
	var spawn_x := TRANSITION_END + 120.0
	var placed := 0
	var max_enemies := clampi(10 + int(world_width / 250.0), 10, 400)
	var spawn_limit := world_width - 180.0
	var platform_cap := maxi(2, max_enemies >> 1)
	var ground_cap := max_enemies - platform_cap

	# 1. Surface ground spawns — strictly skip open entrance and exit shafts!
	while spawn_x < spawn_limit and placed < ground_cap:
		var sx := spawn_x
		spawn_x += ENEMY_MIN_SPACING + _rng.randf_range(10.0, 45.0)
		# Skip open entrance shaft
		if sx >= _ug_entrance_x - 30.0 and sx <= _ug_entrance_x + _ug_entrance_w + 30.0:
			continue
		# Skip open exit shaft
		if sx >= _ug_exit_x - 30.0 and sx <= _ug_exit_x + _ug_exit_w + 30.0:
			continue
		if _is_near_portal(sx, ENEMY_ZONE_Y) or _is_near_npc(sx, ENEMY_ZONE_Y):
			continue
		_enemy_spawns.append(Vector2(sx, ENEMY_ZONE_Y))
		placed += 1

	# 2. Platform spawns
	var platform_candidates: Array[Rect2] = _platform_rects.duplicate()
	platform_candidates.sort_custom(func(a, b): return a.size.x > b.size.x)
	while placed < max_enemies and not platform_candidates.is_empty():
		var plat: Rect2 = platform_candidates.pop_front()
		if plat.size.x < 80.0:
			continue
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

	# 3. Underground cavern spawns across Level 1, Level 2, and Level 3
	if not _underground_rects.is_empty():
		var ug: Rect2 = _underground_rects[0]
		# Deep floor spawns (Level 3)
		var ug_x := ug.position.x + 130.0
		while ug_x < ug.end.x - 110.0:
			_enemy_spawns.append(Vector2(ug_x, _ug_floor3_y - 4.0))
			ug_x += 260.0

	# Assign monster keys and spawn
	var reg_count := regular.size()
	for i in range(_enemy_spawns.size()):
		var sp_pos := _enemy_spawns[i]
		var key: String = ""
		if not bosses.is_empty() and i == _enemy_spawns.size() - 1:
			key = str(bosses[0])
		else:
			var area_idx := int((sp_pos.x - TRANSITION_END) / 400.0)
			var is_underground := sp_pos.y > ENEMY_ZONE_Y + 50.0
			var is_elevated := sp_pos.y < ENEMY_ZONE_Y - 50.0
			var vertical_offset := 2 if is_underground else (1 if is_elevated else 0)
			var monster_idx := (area_idx + vertical_offset) % reg_count
			key = str(regular[monster_idx])
		_spawn_monster(key, sp_pos)


func _spawn_monster(monster_key: String, at_position: Vector2) -> void:
	var monster: Monster = MONSTER_SCENE.instantiate()
	monster.position = at_position
	add_child(monster)
	monster.setup(monster_key, stage_number)

	# Constrain wander bounds so monsters stay on walkable terrain and never float
	var is_underground := at_position.y > ENEMY_ZONE_Y + 50.0
	if is_underground:
		var on_plat := false
		for p in _platform_rects:
			if absf(at_position.y - p.position.y) < 14.0 and at_position.x >= p.position.x and at_position.x <= p.end.x:
				monster.left_bound = p.position.x + 6.0
				monster.right_bound = p.end.x - 6.0
				on_plat = true
				break
		if not on_plat:
			# Standing on the deep solid cavern floor (Level 3)
			monster.left_bound = _ug_entrance_x + 25.0
			monster.right_bound = _ug_exit_x + _ug_exit_w - 25.0
	else:
		var on_plat := false
		for p in _platform_rects:
			if absf(at_position.y - p.position.y) < 14.0 and at_position.x >= p.position.x and at_position.x <= p.end.x:
				monster.left_bound = p.position.x + 6.0
				monster.right_bound = p.end.x - 6.0
				on_plat = true
				break
		if not on_plat:
			# Surface monster: keep clear of shaft openings
			monster.left_bound = maxf(TRANSITION_END + 20.0, at_position.x - 140.0)
			monster.right_bound = minf(world_width - 80.0, at_position.x + 140.0)
			if at_position.x < _ug_entrance_x:
				monster.right_bound = minf(monster.right_bound, _ug_entrance_x - 15.0)
			elif at_position.x > _ug_entrance_x + _ug_entrance_w and at_position.x < _ug_exit_x:
				monster.left_bound = maxf(monster.left_bound, _ug_entrance_x + _ug_entrance_w + 15.0)
				monster.right_bound = minf(monster.right_bound, _ug_exit_x - 15.0)
			elif at_position.x > _ug_exit_x + _ug_exit_w:
				monster.left_bound = maxf(monster.left_bound, _ug_exit_x + _ug_exit_w + 15.0)

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
		# 0: Slate & Indigo Dungeon (exact theme of ui-redesign.html)
		{
			"bg_dark": Color(0.10, 0.10, 0.18),
			"bg_wall": Color(0.14, 0.14, 0.24),
			"brick_line": Color(0.08, 0.08, 0.14),
			"ground": Color(0.23, 0.23, 0.36),
			"top": Color(0.42, 0.48, 0.58),
			"plat": Color(0.21, 0.21, 0.31),
			"plat_edge": Color(0.48, 0.55, 0.65),
			"pillar": Color(0.38, 0.43, 0.50),
			"pillar_light": Color(0.49, 0.55, 0.62),
			"pillar_dark": Color(0.25, 0.29, 0.35),
			"accent": Color(0.98, 0.75, 0.14),
			"sky": Color(0.10, 0.10, 0.18),
			"far": Color(0.14, 0.14, 0.24),
			"near": Color(0.18, 0.18, 0.28)
		},
		# 1: Ancient Moss Crypt
		{
			"bg_dark": Color(0.09, 0.12, 0.10),
			"bg_wall": Color(0.14, 0.18, 0.15),
			"brick_line": Color(0.07, 0.09, 0.07),
			"ground": Color(0.18, 0.26, 0.20),
			"top": Color(0.35, 0.50, 0.38),
			"plat": Color(0.16, 0.22, 0.18),
			"plat_edge": Color(0.40, 0.58, 0.44),
			"pillar": Color(0.32, 0.42, 0.35),
			"pillar_light": Color(0.42, 0.54, 0.45),
			"pillar_dark": Color(0.20, 0.28, 0.22),
			"accent": Color(0.45, 0.85, 0.55),
			"sky": Color(0.09, 0.12, 0.10),
			"far": Color(0.14, 0.18, 0.15),
			"near": Color(0.18, 0.26, 0.20)
		},
		# 2: Molten Basalt Citadel
		{
			"bg_dark": Color(0.11, 0.09, 0.09),
			"bg_wall": Color(0.18, 0.13, 0.14),
			"brick_line": Color(0.08, 0.06, 0.06),
			"ground": Color(0.28, 0.18, 0.20),
			"top": Color(0.65, 0.35, 0.30),
			"plat": Color(0.24, 0.16, 0.17),
			"plat_edge": Color(0.70, 0.42, 0.35),
			"pillar": Color(0.38, 0.28, 0.30),
			"pillar_light": Color(0.50, 0.36, 0.38),
			"pillar_dark": Color(0.22, 0.16, 0.18),
			"accent": Color(1.00, 0.55, 0.20),
			"sky": Color(0.11, 0.09, 0.09),
			"far": Color(0.18, 0.13, 0.14),
			"near": Color(0.28, 0.18, 0.20)
		},
		# 3: Frost Crystal Sanctum
		{
			"bg_dark": Color(0.08, 0.11, 0.17),
			"bg_wall": Color(0.12, 0.17, 0.25),
			"brick_line": Color(0.06, 0.08, 0.12),
			"ground": Color(0.18, 0.27, 0.38),
			"top": Color(0.45, 0.65, 0.82),
			"plat": Color(0.15, 0.22, 0.32),
			"plat_edge": Color(0.55, 0.75, 0.90),
			"pillar": Color(0.32, 0.42, 0.55),
			"pillar_light": Color(0.45, 0.58, 0.72),
			"pillar_dark": Color(0.20, 0.28, 0.38),
			"accent": Color(0.40, 0.85, 1.00),
			"sky": Color(0.08, 0.11, 0.17),
			"far": Color(0.12, 0.17, 0.25),
			"near": Color(0.18, 0.27, 0.38)
		},
		# 4: Royal Obsidian Vault
		{
			"bg_dark": Color(0.11, 0.08, 0.15),
			"bg_wall": Color(0.17, 0.13, 0.23),
			"brick_line": Color(0.08, 0.06, 0.11),
			"ground": Color(0.26, 0.19, 0.35),
			"top": Color(0.60, 0.45, 0.75),
			"plat": Color(0.22, 0.16, 0.30),
			"plat_edge": Color(0.70, 0.55, 0.85),
			"pillar": Color(0.38, 0.30, 0.48),
			"pillar_light": Color(0.50, 0.40, 0.62),
			"pillar_dark": Color(0.24, 0.18, 0.32),
			"accent": Color(0.85, 0.65, 1.00),
			"sky": Color(0.11, 0.08, 0.15),
			"far": Color(0.17, 0.13, 0.23),
			"near": Color(0.26, 0.19, 0.35)
		},
		# 5: Sunken Sandstone Temple
		{
			"bg_dark": Color(0.13, 0.11, 0.09),
			"bg_wall": Color(0.21, 0.17, 0.13),
			"brick_line": Color(0.09, 0.07, 0.05),
			"ground": Color(0.34, 0.27, 0.19),
			"top": Color(0.72, 0.60, 0.42),
			"plat": Color(0.28, 0.22, 0.16),
			"plat_edge": Color(0.80, 0.68, 0.48),
			"pillar": Color(0.46, 0.38, 0.28),
			"pillar_light": Color(0.58, 0.48, 0.36),
			"pillar_dark": Color(0.30, 0.24, 0.18),
			"accent": Color(1.00, 0.82, 0.45),
			"sky": Color(0.13, 0.11, 0.09),
			"far": Color(0.21, 0.17, 0.13),
			"near": Color(0.34, 0.27, 0.19)
		}
	]
	return palettes[(stage_number - 1) % palettes.size()]


func _draw() -> void:
	var palette := _palette()
	var bg_dark: Color = palette["bg_dark"]
	var bg_wall: Color = palette["bg_wall"]
	var brick_line: Color = palette["brick_line"]
	var ground: Color = palette["ground"]
	var top: Color = palette["top"]
	var plat: Color = palette["plat"]
	var plat_edge: Color = palette["plat_edge"]
	var pillar_col: Color = palette["pillar"]
	var pillar_light: Color = palette["pillar_light"]
	var pillar_dark: Color = palette["pillar_dark"]
	var accent: Color = palette["accent"]

	# 1. Dark dungeon background
	draw_rect(Rect2(-600.0, -2200.0, world_width + 1200.0, 3000.0), bg_dark)

	# 2. Ashlar stone masonry brick pattern on background wall
	var brick_h := 30.0
	var brick_w := 64.0
	var wall_top := ENEMY_ZONE_Y - 520.0
	var wall_bottom := _ug_floor3_y + 180.0
	var row_y := wall_top
	var row_idx := 0
	while row_y < wall_bottom:
		# Horizontal mortar line
		draw_line(Vector2(-400.0, row_y), Vector2(world_width + 400.0, row_y), brick_line, 1.5)
		# Staggered vertical mortar notches
		var offset := (brick_w * 0.5) if (row_idx % 2 == 1) else 0.0
		var bx := -400.0 + offset
		while bx < world_width + 400.0:
			draw_line(Vector2(bx, row_y), Vector2(bx, row_y + brick_h), brick_line, 1.5)
			bx += brick_w
		row_y += brick_h
		row_idx += 1

	# 3. Vaulted stone arches in background between chambers
	for ch in _chambers:
		var arch_start: float = ch["start_x"]
		var arch_end: float = ch["end_x"]
		var arch_mid: float = (arch_start + arch_end) * 0.5
		var arch_r: float = (arch_end - arch_start) * 0.45
		draw_arc(Vector2(arch_mid, ENEMY_ZONE_Y - 80.0), arch_r, -PI, 0.0, 32, bg_wall.lightened(0.06), 6.0)

	# 4. Multi-Level Underground Cavern Backdrop & Interior (DRAWN BEFORE PLATFORMS!)
	if not _underground_rects.is_empty():
		var ug: Rect2 = _underground_rects[0]
		var cave_bg := bg_dark.darkened(0.35)
		var cave_rock := ground.darkened(0.2)

		# Deep multi-tier cavern chamber background
		draw_rect(Rect2(_ug_entrance_x - 14.0, ENEMY_ZONE_Y + 36.0, (_ug_exit_x + _ug_exit_w) - _ug_entrance_x + 28.0, _ug_floor3_y - ENEMY_ZONE_Y + 36.0), cave_bg)

		# Subterranean Level Labels on the cavern back wall
		var ug_mid_x := (_ug_entrance_x + _ug_exit_x + _ug_exit_w) * 0.5
		draw_string(ThemeDB.fallback_font, Vector2(ug_mid_x, _ug_floor1_y - 20.0),
			"— LEVEL I: UPPER CRYPT —", HORIZONTAL_ALIGNMENT_CENTER, 300, 11, accent.darkened(0.25))
		draw_string(ThemeDB.fallback_font, Vector2(ug_mid_x, _ug_floor2_y - 20.0),
			"— LEVEL II: CATACOMB VAULTS —", HORIZONTAL_ALIGNMENT_CENTER, 300, 11, accent.darkened(0.25))
		draw_string(ThemeDB.fallback_font, Vector2(ug_mid_x, _ug_floor3_y - 32.0),
			"— LEVEL III: SUNKEN ABYSS —", HORIZONTAL_ALIGNMENT_CENTER, 300, 11, accent.darkened(0.25))

		# Stalactites hanging from cavern roof
		var s_rng := RandomNumberGenerator.new()
		s_rng.seed = stage_number * 8831
		var sx := _ug_entrance_x + _ug_entrance_w + 30.0
		while sx < _ug_exit_x - 30.0:
			var sh := s_rng.randf_range(20.0, 42.0)
			draw_colored_polygon(PackedVector2Array([
				Vector2(sx - 12.0, ENEMY_ZONE_Y + 36.0),
				Vector2(sx + 12.0, ENEMY_ZONE_Y + 36.0),
				Vector2(sx, ENEMY_ZONE_Y + 36.0 + sh)
			]), cave_rock.darkened(0.2))
			sx += s_rng.randf_range(70.0, 150.0)

		# Stalagmites rising from Level 3 floor
		sx = _ug_entrance_x + _ug_entrance_w + 50.0
		while sx < _ug_exit_x - 40.0:
			if s_rng.randf() < 0.55:
				var smh := s_rng.randf_range(18.0, 36.0)
				draw_colored_polygon(PackedVector2Array([
					Vector2(sx - 10.0, _ug_floor3_y),
					Vector2(sx + 10.0, _ug_floor3_y),
					Vector2(sx, _ug_floor3_y - smh)
				]), cave_rock.lightened(0.08))
			sx += s_rng.randf_range(90.0, 180.0)

		# Level 3 Solid Cavern Floor
		draw_rect(ug, cave_rock)
		draw_rect(Rect2(ug.position, Vector2(ug.size.x, 5.0)), top.darkened(0.2))
		draw_line(ug.position, Vector2(ug.end.x, ug.position.y), plat_edge.darkened(0.2), 2.0)

	# 5. Segmented Surface Ground
	# Segment A: Town flat and ramp up to entrance shaft
	var poly_a := PackedVector2Array()
	for pt in _ground_pts:
		if pt.x <= _ug_entrance_x:
			poly_a.append(pt)
	poly_a.append(Vector2(_ug_entrance_x, GROUND_Y + 800.0))
	poly_a.append(Vector2(-500.0, GROUND_Y + 800.0))
	draw_colored_polygon(poly_a, ground)
	# Ridge line on segment A
	for i in range(poly_a.size() - 3):
		draw_line(poly_a[i], poly_a[i + 1], top.lightened(0.1), 2.5)

	# Segment B: Walkable stone roof over underground cavern
	var roof_rect := Rect2(_ug_entrance_x + _ug_entrance_w, ENEMY_ZONE_Y, _ug_exit_x - (_ug_entrance_x + _ug_entrance_w), 36.0)
	draw_rect(roof_rect, ground)
	draw_line(roof_rect.position, Vector2(roof_rect.end.x, roof_rect.position.y), top.lightened(0.12), 2.5)
	draw_line(Vector2(roof_rect.position.x, roof_rect.end.y), roof_rect.end, ground.darkened(0.4), 2.0)
	# Stone slab seam lines on roof
	var rx := roof_rect.position.x + 40.0
	while rx < roof_rect.end.x - 20.0:
		draw_line(Vector2(rx, roof_rect.position.y + 2.0), Vector2(rx, roof_rect.end.y - 2.0), ground.darkened(0.25), 1.5)
		rx += 40.0

	# Segment C: Right summit ground
	var poly_c := PackedVector2Array()
	var exit_end := _ug_exit_x + _ug_exit_w
	for pt in _ground_pts:
		if pt.x >= exit_end:
			poly_c.append(pt)
	poly_c.append(Vector2(world_width + 600.0, GROUND_Y + 800.0))
	poly_c.append(Vector2(exit_end, GROUND_Y + 800.0))
	draw_colored_polygon(poly_c, ground)
	# Ridge line on segment C
	for i in range(poly_c.size() - 3):
		draw_line(poly_c[i], poly_c[i + 1], top.lightened(0.1), 2.5)

	# 6. Open Entrance & Exit Shaft Visual Frames
	# Entrance Shaft jambs & label
	draw_rect(Rect2(_ug_entrance_x - 12.0, ENEMY_ZONE_Y, 14.0, 36.0), pillar_col)
	draw_rect(Rect2(_ug_entrance_x + _ug_entrance_w - 2.0, ENEMY_ZONE_Y, 14.0, 36.0), pillar_col)
	draw_rect(Rect2(_ug_entrance_x + 10.0, ENEMY_ZONE_Y - 30.0, _ug_entrance_w - 20.0, 22.0), bg_wall.darkened(0.2))
	draw_rect(Rect2(_ug_entrance_x + 10.0, ENEMY_ZONE_Y - 30.0, _ug_entrance_w - 20.0, 22.0), accent, false, 1.5)
	draw_string(ThemeDB.fallback_font, Vector2(_ug_entrance_x + _ug_entrance_w * 0.5, ENEMY_ZONE_Y - 15.0),
		"⬇ CATACOMBS", HORIZONTAL_ALIGNMENT_CENTER, int(_ug_entrance_w - 24.0), 11, accent)

	# Exit Shaft jambs & label
	draw_rect(Rect2(_ug_exit_x - 12.0, ENEMY_ZONE_Y, 14.0, 36.0), pillar_col)
	draw_rect(Rect2(_ug_exit_x + _ug_exit_w - 2.0, ENEMY_ZONE_Y, 14.0, 36.0), pillar_col)
	draw_rect(Rect2(_ug_exit_x + 10.0, ENEMY_ZONE_Y - 30.0, _ug_exit_w - 20.0, 22.0), bg_wall.darkened(0.2))
	draw_rect(Rect2(_ug_exit_x + 10.0, ENEMY_ZONE_Y - 30.0, _ug_exit_w - 20.0, 22.0), accent, false, 1.5)
	draw_string(ThemeDB.fallback_font, Vector2(_ug_exit_x + _ug_exit_w * 0.5, ENEMY_ZONE_Y - 15.0),
		"⬆ SURFACE", HORIZONTAL_ALIGNMENT_CENTER, int(_ug_exit_w - 24.0), 11, accent)

	# 7. Platforms (Drawn with 3D stone slab styling matching ui-redesign.html)
	for rect in _platform_rects:
		var r: Rect2 = rect
		# Main body
		draw_rect(r, plat)
		# Top highlight edge (crisp stone slab top)
		draw_rect(Rect2(r.position, Vector2(r.size.x, 4.0)), plat_edge)
		# Bottom shadow bevel
		draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - 4.0), Vector2(r.size.x, 4.0)), plat.darkened(0.45))
		# Vertical stone slab joints every 32px (matching tile grid)
		var jx := r.position.x + 32.0
		while jx < r.end.x - 16.0:
			draw_line(Vector2(jx, r.position.y + 4.0), Vector2(jx, r.end.y - 4.0), plat.darkened(0.3), 1.5)
			jx += 32.0

	# 8. Solid Stone Pillars (Large Partition Pillars & Small Obstacle Pillars)
	for p_rect in _pillar_rects:
		var pr: Rect2 = p_rect
		# Pillar body
		draw_rect(pr, pillar_col)
		# Left highlight bevel
		draw_rect(Rect2(pr.position, Vector2(7.0, pr.size.y)), pillar_light)
		# Right shadow bevel
		draw_rect(Rect2(pr.position + Vector2(pr.size.x - 7.0, 0.0), Vector2(7.0, pr.size.y)), pillar_dark)
		# Pillar capital on top
		var cap_w := pr.size.x + 14.0
		var cap_h := 12.0
		var cap_pos := pr.position - Vector2(7.0, cap_h)
		draw_rect(Rect2(cap_pos, Vector2(cap_w, cap_h)), pillar_light)
		draw_line(cap_pos, Vector2(cap_pos.x + cap_w, cap_pos.y), plat_edge, 2.0)
		# Pillar base molding at bottom
		var base_pos := pr.position + Vector2(-6.0, pr.size.y - 8.0)
		draw_rect(Rect2(base_pos, Vector2(pr.size.x + 12.0, 10.0)), pillar_dark)
		# Carved horizontal masonry grooves
		var groove_y := pr.position.y + 36.0
		while groove_y < pr.position.y + pr.size.y - 18.0:
			draw_line(Vector2(pr.position.x + 5.0, groove_y), Vector2(pr.position.x + pr.size.x - 5.0, groove_y), pillar_dark.darkened(0.35), 2.0)
			groove_y += 36.0

	# 9. Torches and Wall Sconces (Atmospheric dungeon lighting)
	for t_pos in _torch_positions:
		# Ambient radial light glow
		draw_circle(t_pos, 38.0, Color(1.0, 0.72, 0.22, 0.12))
		draw_circle(t_pos, 18.0, Color(1.0, 0.82, 0.35, 0.24))
		# Iron wall bracket
		draw_rect(Rect2(t_pos.x - 3.0, t_pos.y + 2.0, 6.0, 14.0), Color(0.18, 0.18, 0.22))
		# Wooden torch handle
		draw_rect(Rect2(t_pos.x - 2.0, t_pos.y - 4.0, 4.0, 10.0), Color(0.38, 0.24, 0.14))
		# Fire flame
		draw_circle(t_pos + Vector2(0.0, -6.0), 5.5, Color(1.0, 0.58, 0.12))
		draw_circle(t_pos + Vector2(0.0, -7.0), 3.2, Color(1.0, 0.94, 0.42))

	# 10. Chamber Name Overhead Banners
	for ch in _chambers:
		var mid_x: float = (ch["start_x"] + ch["end_x"]) * 0.5
		var label_y := ENEMY_ZONE_Y - 260.0
		# Plaque backing
		draw_rect(Rect2(mid_x - 90.0, label_y - 14.0, 180.0, 22.0), Color(0.07, 0.07, 0.12, 0.88))
		draw_rect(Rect2(mid_x - 90.0, label_y - 14.0, 180.0, 22.0), accent, false, 1.2)
		draw_string(ThemeDB.fallback_font, Vector2(mid_x, label_y + 1.0),
			str(ch["name"]), HORIZONTAL_ALIGNMENT_CENTER, 180, 11, accent)

	# 11. Town Stage Sign near spawn
	var sign_x := 240.0
	draw_rect(Rect2(sign_x - 3.0, GROUND_Y - 70.0, 6.0, 70.0), Color(0.38, 0.26, 0.16))
	draw_rect(Rect2(sign_x - 62.0, GROUND_Y - 106.0, 124.0, 40.0), Color(0.52, 0.36, 0.20))
	draw_string(ThemeDB.fallback_font, Vector2(sign_x - 60.0, GROUND_Y - 80.0),
		"#%d %s" % [stage_number, str(stage_data.get("name", "Stage"))],
		HORIZONTAL_ALIGNMENT_CENTER, 120, 12, Color(0.98, 0.94, 0.82))

	# 12. Forward Portal Dungeon Arch & Magical Glow
	var p_pos := _forward_portal_pos
	# Stone portal obelisk pillars
	draw_rect(Rect2(p_pos.x - 34.0, p_pos.y - 75.0, 12.0, 75.0), pillar_col)
	draw_rect(Rect2(p_pos.x + 22.0, p_pos.y - 75.0, 12.0, 75.0), pillar_col)
	draw_rect(Rect2(p_pos.x - 36.0, p_pos.y - 82.0, 72.0, 10.0), pillar_light)
	# Swirling portal vortex aura (matching ui-redesign.html purple portal)
	draw_circle(p_pos + Vector2(0.0, -36.0), 32.0, Color(0.55, 0.26, 0.68, 0.25))
	draw_circle(p_pos + Vector2(0.0, -36.0), 22.0, Color(0.68, 0.35, 0.82, 0.42))
	draw_circle(p_pos + Vector2(0.0, -36.0), 12.0, Color(0.85, 0.55, 1.00, 0.78))
	draw_circle(p_pos + Vector2(0.0, -36.0), 5.0, Color(1.00, 1.00, 1.00, 0.95))
