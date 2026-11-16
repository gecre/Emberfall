extends CharacterBody2D
class_name Monster

signal died(monster: Monster)
signal damage_dealt(amount: int, critical: bool, world_position: Vector2)

const GRAVITY := 1550.0
const MAX_FALL_SPEED := 950.0

var monster_name := "Monster"
var data: Dictionary = {}
var max_hp := 10
var hp := 10
var damage := 1
var speed := 70.0
var xp_reward := 0
var gold_reward := 0
var drops: Array = []
var is_boss := false
var dead := false

var target: Node = null
var facing := 1.0
var wander_direction := 1.0
var home_x := 0.0
var attack_cooldown := 0.0
var hurt_flash := 0.0
var bob_phase := 0.0
var left_bound := 0.0
var right_bound := 10000.0

@onready var collision: CollisionShape2D = $CollisionShape2D


func _ready() -> void:
	add_to_group("monsters")
	target = get_tree().get_first_node_in_group("player")
	home_x = global_position.x
	wander_direction = 1.0 if randf() < 0.5 else -1.0
	bob_phase = randf() * TAU


func setup(monster_key: String, _stage_number: int) -> void:
	monster_name = monster_key
	data = GameData.monster(monster_key)
	if data.is_empty():
		data = {"name": monster_key, "health": 30, "power": 6, "xp": 5, "worth": 2, "speed": 4.0, "height": 3.0}
	max_hp = GameData.balance_hp(data)
	hp = max_hp
	damage = GameData.balance_damage(data)
	speed = GameData.balance_speed(data)
	xp_reward = int(data.get("xp", 5))
	gold_reward = int(data.get("worth", 2))
	drops = data.get("drops", [])
	is_boss = bool(data.get("boss", false))

	var height := float(data.get("height", 3.0))
	var visual := clampf(0.75 + height / 26.0, 0.8, 2.1)
	if is_boss:
		visual = maxf(visual, 1.7)
	scale = Vector2.ONE * visual
	queue_redraw()


func _physics_process(delta: float) -> void:
	if dead:
		return

	# In multiplayer, only the server runs monster AI.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return

	var was_flashing := hurt_flash > 0.0
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	hurt_flash = maxf(0.0, hurt_flash - delta)
	bob_phase += delta * 3.0

	if not is_on_floor():
		velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL_SPEED)

	var has_target := target != null and is_instance_valid(target) and not bool(target.get("dead"))
	var in_melee := false
	if has_target:
		var dx: float = target.global_position.x - global_position.x
		var dy: float = absf(target.global_position.y - global_position.y)
		# Monsters cannot melee attack a player standing on a platform above.
		var target_on_higher_floor: bool = bool(target.call("is_on_floor")) and target.global_position.y < global_position.y - 16.0
		if absf(dx) <= 52.0 and dy <= 32.0 and not target_on_higher_floor:
			in_melee = true
			if absf(dx) > 4.0:
				facing = signf(dx)
			velocity.x = move_toward(velocity.x, 0.0, speed * 8.0 * delta)
			if attack_cooldown <= 0.0:
				if target.has_method("rpc_take_damage"):
					target.rpc_take_damage(float(damage), global_position)
				else:
					target.call("take_damage", float(damage), global_position)
				attack_cooldown = 1.05
	if not in_melee:
		_wander(delta)

	if global_position.x < left_bound:
		global_position.x = left_bound
		velocity.x = absf(velocity.x)
	if global_position.x > right_bound:
		global_position.x = right_bound
		velocity.x = -absf(velocity.x)

	move_and_slide()
	# Only redraw while actively attacking or flashing hurt. Idle wander bob is
	# cosmetic and can freeze to save per-frame immediate draws (up to ~32
	# monsters were redrawing every frame).
	# Redraw once more when the hurt flash ends so the monster returns to its
	# normal color instead of staying stuck on the white flash frame.
	if in_melee or hurt_flash > 0.0 or was_flashing:
		queue_redraw()


func _wander(delta: float) -> void:
	if absf(global_position.x - home_x) > 110.0:
		wander_direction = -signf(global_position.x - home_x)
		facing = wander_direction
	velocity.x = wander_direction * speed * 0.4
	if is_on_wall():
		wander_direction *= -1.0


func take_damage(amount: float, from_position: Vector2, critical: bool = false, knockback_mult: float = 1.0) -> void:
	if dead:
		return
	var final_damage := maxi(1, int(round(amount)))
	hp -= final_damage
	hurt_flash = 0.16
	damage_dealt.emit(final_damage, critical, global_position + Vector2(0, -55.0 * scale.y))
	var knock_direction := signf(global_position.x - from_position.x)
	if knock_direction == 0.0:
		knock_direction = 1.0
	velocity.x = knock_direction * 130.0 * knockback_mult
	if hp <= 0:
		_die()


func _die() -> void:
	if dead:
		return
	dead = true
	remove_from_group("monsters")
	collision.set_deferred("disabled", true)
	died.emit(self)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector2.ZERO, 0.18)
	tween.tween_property(self, "modulate:a", 0.0, 0.18)
	tween.chain().tween_callback(queue_free)


func _draw() -> void:
	var hue := float(abs(hash(monster_name)) % 997) / 997.0
	var base := Color.from_hsv(hue, 0.55, 0.85)
	if is_boss:
		base = Color(0.86, 0.55, 0.16)
	if hurt_flash > 0.0:
		base = Color(1.0, 0.95, 0.9)

	var bob := sin(bob_phase) * 1.5

	# Shadow
	draw_set_transform(Vector2(0, -1), 0.0, Vector2(1.0, 0.3))
	draw_circle(Vector2.ZERO, 20.0, Color(0.0, 0.0, 0.0, 0.22))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# Legs
	draw_rect(Rect2(-14, -14 + bob, 9, 14), base.darkened(0.25))
	draw_rect(Rect2(5, -14 + bob, 9, 14), base.darkened(0.25))

	# Body
	draw_circle(Vector2(0, -30 + bob), 21.0, base)
	draw_rect(Rect2(-21, -30 + bob, 42, 18), base)
	draw_circle(Vector2(0, -30 + bob), 21.0, base)

	# Belly highlight
	draw_circle(Vector2(facing * 4.0, -24 + bob), 9.0, base.lightened(0.22))

	# Eyes
	var eye_offset := facing * 5.0
	draw_circle(Vector2(-6 + eye_offset, -36 + bob), 4.5, Color.WHITE)
	draw_circle(Vector2(6 + eye_offset, -36 + bob), 4.5, Color.WHITE)
	draw_circle(Vector2(-6 + eye_offset + facing * 1.5, -36 + bob), 2.2, Color(0.06, 0.06, 0.09))
	draw_circle(Vector2(6 + eye_offset + facing * 1.5, -36 + bob), 2.2, Color(0.06, 0.06, 0.09))

	# Boss horns
	if is_boss:
		draw_colored_polygon(PackedVector2Array([
			Vector2(-16, -48 + bob), Vector2(-24, -64 + bob), Vector2(-9, -50 + bob)
		]), Color(0.95, 0.85, 0.6))
		draw_colored_polygon(PackedVector2Array([
			Vector2(16, -48 + bob), Vector2(24, -64 + bob), Vector2(9, -50 + bob)
		]), Color(0.95, 0.85, 0.6))

	# Name
	draw_string(ThemeDB.fallback_font, Vector2(-70, -72 + bob), monster_name,
		HORIZONTAL_ALIGNMENT_CENTER, 140, 11, Color(1, 1, 1, 0.92))

	# Health bar
	if hp < max_hp or is_boss:
		var width := 52.0
		var ratio := clampf(float(hp) / float(max_hp), 0.0, 1.0)
		draw_rect(Rect2(-width * 0.5, -64 + bob, width, 6), Color(0.08, 0.08, 0.1, 0.85))
		var fill_color := Color(0.28, 0.82, 0.35)
		if ratio < 0.35:
			fill_color = Color(0.9, 0.28, 0.25)
		elif ratio < 0.65:
			fill_color = Color(0.95, 0.75, 0.2)
		draw_rect(Rect2(-width * 0.5 + 1, -63 + bob, (width - 2) * ratio, 4), fill_color)
