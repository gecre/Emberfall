extends CharacterBody2D
class_name Player

signal damaged(amount: int, world_position: Vector2)
signal died
signal prompt_changed(text: String)

const SPEED := 230.0
const JUMP_VELOCITY := -560.0
const GRAVITY := 1550.0
const MAX_FALL_SPEED := 950.0
const COYOTE_TIME := 0.12
const JUMP_BUFFER_TIME := 0.12
const DROP_TIME := 0.24
const PORTAL_USE_RANGE := 100.0  # Must be standing near the portal to click it.
const NPC_CLICK_RANGE := 100.0  # Click within this distance of an NPC to interact with it.

var facing := 1.0
var attack_cooldown := 0.0
## When true, this player is controlled over the network: local input is
## ignored and position is driven by RPC instead.
var swing_timer := 0.0
var invuln_timer := 0.0
var coyote_timer := 0.0
var jump_buffer_timer := 0.0
var drop_timer := 0.0
var drop_bodies: Array = []
var walk_phase := 0.0
var dead := false
var interact_target: Node = null
var _virtual_axis := Vector2.ZERO  # Set by touch controls (mobile); overrides keyboard axis
var rage_timer := 0.0
var active_rage_skill: String = ""  # Which rage skill is currently active (for tracking)
var blocking := false
var block_mp_timer := 0.0
var mp_restore_timer := 0.0

var _interactables: Array = []

# --- Multiplayer ---
const NETWORK_SEND_INTERVAL := 0.05  # 20 position updates per second
const INTERP_BUFFER_SIZE := 12
const INTERP_DELAY := 0.1  # 100ms interpolation buffer for lag compensation
var _network_timer := 0.0
var _position_history: Array = []  # [{time, position, velocity, facing}]
var _is_remote := false

@onready var attack_area: Area2D = $AttackArea
@onready var attack_shape: CollisionShape2D = $AttackArea/CollisionShape2D
@onready var interact_area: Area2D = $InteractArea
@onready var camera: Camera2D = $Camera2D


func _ready() -> void:
	add_to_group("player")
	attack_shape.shape = RectangleShape2D.new()
	interact_area.area_entered.connect(_on_interact_area_entered)
	interact_area.area_exited.connect(_on_interact_area_exited)
	if camera != null:
		camera.zoom = Vector2(GameState.camera_zoom, GameState.camera_zoom)
		GameState.camera_zoom_changed.connect(func(z: float) -> void:
			if is_instance_valid(camera):
				camera.zoom = Vector2(z, z)
		)
	_update_attack_shape()
	_multiplayer_setup()
	queue_redraw()


func _multiplayer_setup() -> void:
	var my_id := multiplayer.get_unique_id()
	_is_remote = get_multiplayer_authority() != my_id
	if _is_remote:
		# Remote players don't process local input or camera
		pass


func _physics_process(delta: float) -> void:
	if _is_remote:
		_network_interpolate(delta)
		return
	var was_swinging := swing_timer > 0.0
	var was_invuln := invuln_timer > 0.0
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	swing_timer = maxf(0.0, swing_timer - delta)
	invuln_timer = maxf(0.0, invuln_timer - delta)
	coyote_timer = maxf(0.0, coyote_timer - delta)
	jump_buffer_timer = maxf(0.0, jump_buffer_timer - delta)

	if drop_timer > 0.0:
		drop_timer -= delta
		if drop_timer <= 0.0:
			_end_drop_through()

	if dead:
		velocity = Vector2.ZERO
		return

	if Input.is_action_just_pressed("move_down") and is_on_floor():
		_try_drop_through()
	# Keyboard input actions; mobile touch invokes touch_attack / touch_jump directly.
	if Input.is_action_just_pressed("jump"):
		jump_buffer_timer = JUMP_BUFFER_TIME
	if Input.is_action_pressed("attack") and attack_cooldown <= 0.0:
		_attack()
	var interact_just := Input.is_action_just_pressed("interact")
	if interact_just:
		# E is loot only: pick up the nearest nearby item. NPCs are clicked, never E'd.
		var loot := _nearest_loot()
		if loot != null and is_instance_valid(loot) and loot.has_method("interact"):
			loot.interact(self)
	# --- Rage (Self Rage / Guild Rage): press R ---
	if Input.is_action_just_pressed("rage") and not dead:
		var skill_name := "Self Rage" if int(GameState.skills.get("Self Rage", 0)) > 0 else "Guild Rage"
		# Cooldown takes priority: if the skill is on cooldown, report that
		# instead of saying it is active.
		var remaining := float(GameState.skill_cooldowns.get(skill_name, 0))
		if remaining > 0.0:
			GameState.message.emit("%s on cooldown (%.1fs)" % [skill_name, remaining])
		else:
			var active := GameState.get_active_skills()
			if active.has("Self Rage"):
				GameState.message.emit("Self Rage is active!")
			elif active.has("Guild Rage"):
				GameState.message.emit("Guild Rage is active!")
			elif GameState.activate_skill(skill_name):
				var rage_lvl := int(GameState.skills.get(skill_name, 0))
				rage_timer = float(rage_lvl)  # 1 second per level
				active_rage_skill = skill_name
				GameState.set_active_skill(skill_name, rage_timer)
				GameState.message.emit("Rage activated! (%d seconds)" % rage_lvl)
			else:
				GameState.message.emit("%s on cooldown (%.1fs)" % [skill_name, remaining])

	# --- Block (V key): hold to reduce incoming damage ---
	var block_lvl := int(GameState.skills.get("Block", 0))
	if block_lvl > 0 and not dead:
		if Input.is_action_pressed("block") and not blocking:
			if GameState.current_mp > 0:
				blocking = true
				GameState.set_active_skill("Block", 999.0)
		elif Input.is_action_just_released("block"):
			blocking = false
			GameState.set_active_skill("Block", 0.0)

	if blocking:
		block_mp_timer += delta
		if block_mp_timer >= 1.0:
			block_mp_timer = 0.0
			if GameState.current_mp > 0:
				GameState.current_mp = maxi(0, GameState.current_mp - 8)
				GameState.stats_changed.emit()
			else:
				blocking = false
				GameState.set_active_skill("Block", 0.0)
		# Keep Block registered as active while held (update_active_skills
		# in HUD decrements durations each frame, so re-sync to prevent expiry).
		GameState.set_active_skill("Block", 999.0)
	else:
		block_mp_timer = 0.0

	if rage_timer > 0.0:
		rage_timer -= delta
		if active_rage_skill != "":
			GameState.set_active_skill(active_rage_skill, max(0.0, rage_timer))
	elif rage_timer <= 0.0 and active_rage_skill != "":
		GameState.set_active_skill(active_rage_skill, 0.0)
		active_rage_skill = ""

	var pstats := GameState.stats()
	var axis := Input.get_axis("move_left", "move_right")
	if _virtual_axis != Vector2.ZERO:
		axis = _virtual_axis.x
	var move_speed: float = float(pstats.get("speed", SPEED))
	if absf(axis) > 0.01:
		facing = signf(axis)
		velocity.x = axis * move_speed
		walk_phase += delta * 11.0
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 9.0 * delta)

	if not is_on_floor():
		var down_accel_lvl := float(GameState.skills.get("Downward Acceleration", 0))
		if Input.is_action_pressed("move_down") and down_accel_lvl > 0.0:
			velocity.y = minf(velocity.y + GRAVITY * delta * (1.0 + down_accel_lvl * 0.15), MAX_FALL_SPEED * 1.5)
		else:
			velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL_SPEED)
	else:
		coyote_timer = COYOTE_TIME

	if jump_buffer_timer > 0.0 and coyote_timer > 0.0:
		velocity.y = float(pstats.get("jump_velocity", JUMP_VELOCITY))
		jump_buffer_timer = 0.0
		coyote_timer = 0.0

	if Input.is_action_just_released("jump") and velocity.y < 0.0:
		velocity.y *= 0.5

	# --- MP Restoration: restores MP every 10 seconds ---
	mp_restore_timer += delta
	if mp_restore_timer >= 10.0:
		mp_restore_timer = 0.0
		var mp_lvl := int(GameState.skills.get("MP Restoration", 0))
		if mp_lvl > 0:
			var restore := 2 + int((mp_lvl - 1) / 2)
			GameState.restore_mp(restore)

	move_and_slide()

	# --- Network: broadcast position to remote peers ---
	_network_timer += delta
	if _network_timer >= NETWORK_SEND_INTERVAL:
		_network_timer = 0.0
		var now := Time.get_ticks_msec() / 1000.0
		rpc_sync_move(global_position, velocity, facing, now)

	_update_attack_shape()
	_refresh_interact_target()
	# Only redraw while something visually changes (movement bob, swing, or
	# invuln flash). Standing still skips the per-frame immediate draw.
	var is_moving := absf(axis) > 0.01 and is_on_floor()
	# Redraw once more when a timed visual (swing / invuln flash) ends so the
	# idle appearance is drawn and the stale frame doesn't stick on screen.
	if is_moving or swing_timer > 0.0 or invuln_timer > 0.0 or was_swinging or was_invuln:
		queue_redraw()


## Lets the player fall through one-way (floating) platforms by temporarily
## ignoring collisions with every platform under their feet.
func _try_drop_through() -> void:
	if drop_timer > 0.0:
		return
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	var bodies: Array = []
	for offset_x in [-10.0, 0.0, 10.0]:
		var params := PhysicsRayQueryParameters2D.create(
			global_position + Vector2(offset_x, -6.0),
			global_position + Vector2(offset_x, 26.0),
			1
		)
		var exclude: Array[RID] = [get_rid()]
		params.exclude = exclude
		params.collide_with_areas = false
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			continue
		var body: Variant = hit.get("collider")
		if body != null and body is StaticBody2D and _is_one_way_platform(body) and not bodies.has(body):
			bodies.append(body)
	if bodies.is_empty():
		return
	drop_bodies = bodies
	for body in bodies:
		add_collision_exception_with(body)
	drop_timer = DROP_TIME
	global_position.y += 2.0
	velocity.y = maxf(velocity.y, 60.0)


func _is_one_way_platform(body: Node) -> bool:
	for child in body.get_children():
		if child is CollisionShape2D and child.one_way_collision:
			return true
	return false


func _end_drop_through() -> void:
	for body in drop_bodies:
		if is_instance_valid(body):
			remove_collision_exception_with(body)
	drop_bodies.clear()
	drop_timer = 0.0


func _process(delta: float) -> void:
	if absf(velocity.x) > 8.0 and is_on_floor():
		walk_phase += delta * 2.0


# ---------------------------------------------------------------------------
# Combat
# ---------------------------------------------------------------------------
func _attack() -> void:
	var stats := GameState.stats()
	var rpm := float(stats.get("rpm", 0.0))
	var cooldown := 0.001
	if rpm > 0.0:
		cooldown = clampf(60.0 / rpm, 0.18, 0.8)
	attack_cooldown = cooldown
	swing_timer = 0.16

	var damage_min := float(stats.get("damage_min", 2.0))
	var damage_max := float(stats.get("damage_max", 4.0))

	var crit_chance := float(stats.get("crit_chance", 0.05))
	var crit_mult := float(stats.get("crit_mult", 1.75))

	var knockback_mult := float(stats.get("knockback_mult", 1.0))
	_update_attack_shape()
	var targets := _attack_targets()
	for body in targets:
		var damage := randf_range(damage_min, damage_max)
		if rage_timer > 0.0:
			damage *= 1.35
		var critical := randf() < crit_chance
		if critical:
			damage *= crit_mult
		if body.has_method("take_damage"):
			body.take_damage(damage, global_position, critical, knockback_mult)


## Returns every damageable body inside the current swing arc. The Area2D
## overlap list can lag a physics frame behind the player, so a direct shape
## query is used as the authoritative check.
func _attack_targets() -> Array:
	var targets: Array = []
	var seen := {}
	for body in attack_area.get_overlapping_bodies():
		if body != null and body.has_method("take_damage") and not seen.has(body):
			seen[body] = true
			targets.append(body)

	var space := get_world_2d().direct_space_state
	if space != null and attack_shape.shape is RectangleShape2D:
		var rect := attack_shape.shape as RectangleShape2D
		var query_shape := RectangleShape2D.new()
		query_shape.size = rect.size + Vector2(10.0, 14.0)
		var params := PhysicsShapeQueryParameters2D.new()
		params.shape = query_shape
		params.transform = attack_area.global_transform
		params.collision_mask = 2
		params.collide_with_bodies = true
		params.collide_with_areas = false
		var exclude: Array[RID] = [get_rid()]
		params.exclude = exclude
		for hit in space.intersect_shape(params, 32):
			var body: Variant = hit.get("collider")
			if body != null and body.has_method("take_damage") and not seen.has(body):
				seen[body] = true
				targets.append(body)

	return targets


func take_damage(amount: float, from_position: Vector2) -> void:
	if dead:
		return
	var stats := GameState.stats()
	var avoidance := float(stats.get("avoidance", 0.0))
	if avoidance > 0.0 and randf() < avoidance:
		damaged.emit(0, global_position)
		return
	var defense := float(stats.get("defense", 0.0))
	var reduced := maxf(1.0, amount * 120.0 / (120.0 + defense))
	if blocking:
		var block_reduction := float(stats.get("block_reduction", 0.0))
		if block_reduction > 0.0:
			reduced *= (1.0 - block_reduction)
	var final_damage := int(round(reduced))
	GameState.damage(final_damage)
	damaged.emit(final_damage, global_position + Vector2(0, -70))
	invuln_timer = 0.75
	var direction := signf(global_position.x - from_position.x)
	if direction == 0.0:
		direction = -facing
	velocity.x = direction * 210.0
	velocity.y = -190.0
	if GameState.current_hp <= 0:
		_die()


func _die() -> void:
	if dead:
		return
	dead = true
	velocity = Vector2.ZERO
	died.emit()
	queue_redraw()
	if multiplayer.is_server():
		rpc_died()


func respawn(at_position: Vector2) -> void:
	dead = false
	rage_timer = 0.0
	active_rage_skill = ""
	GameState.set_active_skill("Self Rage", 0.0)
	GameState.set_active_skill("Guild Rage", 0.0)
	global_position = at_position
	velocity = Vector2.ZERO
	invuln_timer = 2.0
	GameState.current_hp = GameState.stats()["max_hp"]
	GameState.current_mp = GameState.stats()["max_mp"]
	GameState.stats_changed.emit()
	queue_redraw()


func set_virtual_axis(axis: Vector2) -> void:
	## Allows touch controls to drive movement instead of the keyboard axis.
	_virtual_axis = axis


func touch_attack() -> void:
	## Triggered by mobile touch attack button: fires one swing if not on cooldown.
	if attack_cooldown <= 0.0:
		_attack()


func touch_jump() -> void:
	## Triggered by mobile touch jump button: sets the jump buffer.
	if not dead:
		jump_buffer_timer = JUMP_BUFFER_TIME


func _update_attack_shape() -> void:
	var stats := GameState.stats()
	var reach := float(stats.get("reach", 1.6))
	var wtype := str(stats.get("weapon_type", "melee"))
	if wtype == "ranged" or wtype == "artillery":
		reach = maxf(reach, 4.2)
	elif wtype == "magic":
		reach = maxf(reach, 3.0)
	var reach_px := 22.0 + reach * 14.0
	var rect := attack_shape.shape as RectangleShape2D
	if rect != null:
		rect.size = Vector2(reach_px, 54.0)
	attack_area.position = Vector2(facing * (reach_px * 0.5 + 8.0), -34.0)


# ---------------------------------------------------------------------------
# Interaction
# ---------------------------------------------------------------------------
func _on_interact_area_entered(area: Area2D) -> void:
	if area is Portal:
		return  # Portals are clicked like NPCs, not activated with T or E.
	if area.has_method("interact") and not _interactables.has(area):
		_interactables.append(area)
		_refresh_interact_target()


func _on_interact_area_exited(area: Area2D) -> void:
	_interactables.erase(area)
	_refresh_interact_target()


func _refresh_interact_target() -> void:
	var best: Node = null
	var best_distance := 1.0e20
	for area in _interactables:
		if not is_instance_valid(area):
			continue
		var distance := global_position.distance_to(area.global_position)
		if distance < best_distance:
			best = area
			best_distance = distance
	if best != interact_target:
		interact_target = best
		prompt_changed.emit(get_prompt())


func get_prompt() -> String:
	if interact_target != null and is_instance_valid(interact_target) and interact_target.has_method("get_prompt"):
		return str(interact_target.get_prompt())
	return ""


## Returns the nearest LootPickup currently inside the interact area, or null.
## E only loots items; NPCs are interacted with by clicking them.
func _nearest_loot() -> LootPickup:
	var best: LootPickup = null
	var best_distance := 1.0e20
	for area in _interactables:
		if not is_instance_valid(area):
			continue
		if not (area is LootPickup):
			continue
		if area.collected:
			continue
		var distance := global_position.distance_to(area.global_position)
		if distance < best_distance:
			best = area
			best_distance = distance
	return best


## Manual-pickup loot inside the interact area, nearest first. Gold and
## auto-collect books are excluded because they are collected automatically.
func get_nearby_loot() -> Array:
	var loot_list: Array = []
	for area in _interactables:
		if not is_instance_valid(area):
			continue
		if not (area is LootPickup):
			continue
		if area.collected or area.kind == "gold" or area.auto_collect:
			continue
		loot_list.append(area)
	loot_list.sort_custom(func(a: LootPickup, b: LootPickup) -> bool:
		return global_position.distance_squared_to(a.global_position) \
			< global_position.distance_squared_to(b.global_position)
	)
	return loot_list


## Mobile PICK UP button: collect the nearest manual-pickup item.
func pick_up_nearest_loot() -> void:
	var loot_list := get_nearby_loot()
	if loot_list.is_empty():
		return
	var loot := loot_list[0] as LootPickup
	if loot != null and is_instance_valid(loot):
		loot.interact(self)


## Mobile loot-list selection: collect a specific nearby item.
func pick_up_loot(loot: LootPickup) -> void:
	if loot == null or not is_instance_valid(loot) or loot.collected:
		return
	if global_position.distance_to(loot.global_position) > 140.0:
		return
	loot.interact(self)


func _unhandled_input(event: InputEvent) -> void:
	# Left-click an NPC to interact (talk / shop / heal). Never picks up loot.
	# Only works when the player is standing near the NPC.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if get_tree().paused:
			return
		var mouse_world := get_global_mouse_position()
		var best: NPC = null
		var best_distance := 1.0e20
		for npc in get_tree().get_nodes_in_group("npcs"):
			if not is_instance_valid(npc):
				continue
			var distance := mouse_world.distance_to(npc.global_position)
			if distance < best_distance:
				best = npc
				best_distance = distance
		if best != null and best.has_method("interact") \
			and global_position.distance_to(best.global_position) < NPC_CLICK_RANGE \
			and mouse_world.distance_to(best.global_position) < NPC_CLICK_RANGE:
			best.interact(self)

		# Left-click a portal to travel (when standing near it). Portals are no
		# longer activated with T — click them like NPCs.
		var best_portal: Portal = null
		var best_portal_dist := 1.0e20
		for p in get_tree().get_nodes_in_group("portals"):
			if not is_instance_valid(p):
				continue
			var d := mouse_world.distance_to(p.global_position)
			if d < best_portal_dist:
				best_portal = p
				best_portal_dist = d
		if best_portal != null and best_portal.has_method("interact") \
			and global_position.distance_to(best_portal.global_position) < PORTAL_USE_RANGE \
			and mouse_world.distance_to(best_portal.global_position) < PORTAL_USE_RANGE:
			best_portal.interact(self)

	# Tap the screen near an NPC or portal to interact (like clicking with the mouse).
	elif event is InputEventScreenTouch and event.pressed:
		if get_tree().paused:
			return
		var touch_world: Vector2 = get_viewport().canvas_transform.affine_inverse() * event.position
		var best: NPC = null
		var best_distance: float = 1.0e20
		for npc in get_tree().get_nodes_in_group("npcs"):
			if not is_instance_valid(npc):
				continue
			var distance: float = touch_world.distance_to(npc.global_position)
			if distance < best_distance:
				best = npc
				best_distance = distance
		if best != null and best.has_method("interact") \
			and global_position.distance_to(best.global_position) < NPC_CLICK_RANGE \
			and touch_world.distance_to(best.global_position) < NPC_CLICK_RANGE:
			best.interact(self)
			return
		var best_portal: Portal = null
		var best_portal_dist: float = 1.0e20
		for p in get_tree().get_nodes_in_group("portals"):
			if not is_instance_valid(p):
				continue
			var d: float = touch_world.distance_to(p.global_position)
			if d < best_portal_dist:
				best_portal = p
				best_portal_dist = d
		if best_portal != null and best_portal.has_method("interact") \
			and global_position.distance_to(best_portal.global_position) < PORTAL_USE_RANGE \
			and touch_world.distance_to(best_portal.global_position) < PORTAL_USE_RANGE:
			best_portal.interact(self)


## Returns the nearest portal (group "portals"), or null if none exist.
func _nearest_portal() -> Portal:
	var best: Portal = null
	var best_distance := 1.0e20
	for p in get_tree().get_nodes_in_group("portals"):
		if not is_instance_valid(p):
			continue
		var d := global_position.distance_to(p.global_position)
		if d < best_distance:
			best = p
			best_distance = d
	return best


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------
func _gear_color(slot: String, fallback: Color) -> Color:
	var item_name := str(GameState.equipment.get(slot, ""))
	if item_name == "":
		return fallback
	var data := GameData.item(item_name)
	var item_level := int(data.get("level", 1))
	var t := clampf(float(item_level) / 200.0, 0.0, 1.0)
	return Color.from_hsv(0.09 + t * 0.52, 0.55, 0.82)


func _draw() -> void:
	if dead:
		return
	if invuln_timer > 0.0 and int(invuln_timer * 24.0) % 2 == 0:
		return

	var moving := absf(velocity.x) > 10.0 and is_on_floor()
	var bob := (sin(walk_phase) * 1.6) if moving else (sin(walk_phase * 0.35) * 0.6)
	var leg_swing := (sin(walk_phase) * 4.0) if moving else 0.0

	# Shadow
	draw_set_transform(Vector2(0, -1), 0.0, Vector2(1.0, 0.32))
	draw_circle(Vector2.ZERO, 20.0, Color(0.0, 0.0, 0.0, 0.25))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var skin := Color(0.96, 0.78, 0.62)
	var armor := _gear_color("armor", Color(0.30, 0.45, 0.75))
	var legs := _gear_color("legs", Color(0.24, 0.28, 0.42))
	var helmet := _gear_color("helmet", Color(0.55, 0.62, 0.75))
	var boots := _gear_color("boots", Color(0.20, 0.18, 0.20))

	var y := bob
	# Legs
	draw_rect(Rect2(-8 + leg_swing * 0.4, -18 + y, 7, 18), legs)
	draw_rect(Rect2(1 - leg_swing * 0.4, -18 + y, 7, 18), legs)
	# Boots
	draw_rect(Rect2(-9 + leg_swing * 0.4, -4 + y, 9, 5), boots)
	draw_rect(Rect2(0 - leg_swing * 0.4, -4 + y, 9, 5), boots)
	# Torso
	draw_rect(Rect2(-11, -44 + y, 22, 28), armor)
	draw_circle(Vector2(0, -44 + y), 11.0, armor)
	draw_rect(Rect2(-13, -40 + y, 5, 15), armor.darkened(0.15))
	draw_rect(Rect2(8, -40 + y, 5, 15), armor.darkened(0.15))
	# Belt
	draw_rect(Rect2(-11, -22 + y, 22, 4), Color(0.35, 0.24, 0.14))
	# Head
	draw_circle(Vector2(0, -56 + y), 10.0, skin)
	# Helmet
	draw_circle(Vector2(0, -59 + y), 11.0, helmet)
	draw_rect(Rect2(-11, -60 + y, 22, 6), helmet)
	draw_rect(Rect2(-11, -51 + y, 22, 3), helmet.darkened(0.25))
	draw_rect(Rect2(facing * 2.0 - 5.0, -59 + y, 9, 3), Color(0.08, 0.09, 0.12))
	# Plume
	draw_line(Vector2(0, -70 + y), Vector2(-facing * 4.0, -80 + y), Color(0.85, 0.22, 0.22), 3.0)
	# Eyes
	draw_circle(Vector2(facing * 3.0, -55 + y), 1.7, Color(0.08, 0.09, 0.12))

	# Shield
	if str(GameState.equipment.get("shield", "")) != "":
		draw_circle(Vector2(-facing * 12.0, -38 + y), 8.0, Color(0.62, 0.68, 0.78))
		draw_circle(Vector2(-facing * 12.0, -38 + y), 5.0, Color(0.85, 0.72, 0.35))

	# Weapon / swing
	var hand := Vector2(facing * 11.0, -38 + y)
	if swing_timer > 0.0:
		var radius := 40.0 + float(GameState.stats().get("reach", 1.6)) * 8.0
		var start_angle := -1.0 if facing > 0.0 else PI - 1.0
		var end_angle := 1.0 if facing > 0.0 else PI + 1.0
		draw_arc(hand, radius, start_angle, end_angle, 18, Color(1.0, 1.0, 1.0, 0.75), 4.0)
		draw_line(hand, hand + Vector2(facing * radius, -8.0), Color(0.85, 0.9, 1.0), 3.0)
	else:
		var tip := hand + Vector2(facing * 20.0, -14.0)
		draw_line(hand, tip, Color(0.80, 0.86, 0.95), 3.0)
		draw_line(hand + Vector2(facing * 12.0, -8.0), hand + Vector2(facing * 18.0, -2.0), Color(0.55, 0.42, 0.22), 3.0)


# ---------------------------------------------------------------------------
# Multiplayer: movement sync + lag-compensated interpolation
# ---------------------------------------------------------------------------

## Interpolates the remote player's position from the buffered position history.
## Targets `INTERP_DELAY` seconds in the past to smooth out network jitter.
func _network_interpolate(delta: float) -> void:
	if _position_history.size() < 2:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var target_time := now - INTERP_DELAY

	# Find the two history entries bracketing target_time.
	var idx := 0
	while idx < _position_history.size() - 1 \
			and _position_history[idx + 1]["time"] <= target_time:
		idx += 1

	var p0: Dictionary = _position_history[idx]
	var p1: Dictionary = _position_history[idx + 1] if idx + 1 < _position_history.size() else p0

	var t := 0.0
	if p1["time"] > p0["time"]:
		t = clampf((target_time - p0["time"]) / (p1["time"] - p0["time"]), 0.0, 1.0)

	global_position = p0["position"].lerp(p1["position"], t)
	velocity = p0["velocity"].lerp(p1["velocity"], t)
	facing = p0["facing"]
	_update_attack_shape()
	queue_redraw()


## Receives position/velocity/facing from the authority player. Called ~20/sec.
@rpc("authority", "call_local", "reliable")
func rpc_sync_move(position: Vector2, velocity: Vector2, facing: float, timestamp: float) -> void:
	if not _is_remote:
		return
	_position_history.append({
		"time": timestamp,
		"position": position,
		"velocity": velocity,
		"facing": facing,
	})
	while _position_history.size() > INTERP_BUFFER_SIZE:
		_position_history.pop_front()


## Receives damage sync from the server. Applies damage locally on each peer.
@rpc("authority", "call_local", "reliable")
func rpc_take_damage(amount: float, from_position: Vector2) -> void:
	take_damage(amount, from_position)


## Notifies all peers that this player died.
@rpc("authority", "call_local", "reliable")
func rpc_died() -> void:
	_die()
