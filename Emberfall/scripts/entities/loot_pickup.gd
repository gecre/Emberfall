extends Area2D
class_name LootPickup

const GRAVITY := 1550.0
const MAX_FALL_SPEED := 950.0
## Distance at which a dropped item's indicator icon becomes visible.
const INDICATOR_RANGE := 140.0
## Shared generated pickup sound (no audio assets exist in the project).
static var _pickup_stream: AudioStreamWAV = null

var kind := "gold"
var item_name := ""
var amount := 1
var collected := false
var phase := 0.0
var lifetime := 60.0
var player: Node2D = null
var base_y := 0.0
## Seconds after a failed pickup (e.g. full inventory) before the magnet
## tries again. Prevents the item from hovering at the player's feet forever.
var magnet_cooldown := 0.0
var velocity := Vector2.ZERO
## True once the loot has landed on a surface and is no longer falling.
var settled := false
## Books auto-collect via magnet (like gold) instead of requiring E.
var auto_collect := false
## True when the player is close enough to show this drop's indicator icon.
var player_near := false


func setup_gold(value: int) -> void:
	kind = "gold"
	amount = maxi(1, value)


func setup_item(name: String, qty: int = 1) -> void:
	kind = "item"
	item_name = name
	amount = maxi(1, qty)
	var data := GameData.item(name)
	auto_collect = str(data.get("slot", "")) == "book" or str(name).begins_with("Book of")


func _ready() -> void:
	add_to_group("loot")
	player = get_tree().get_first_node_in_group("player")
	phase = randf() * TAU
	base_y = global_position.y
	# Gold auto-collects via magnet — keep it off the interact layer.
	# Items sit on layer 4 so the player's InteractArea can detect them.
	if kind == "gold":
		collision_layer = 0
		monitorable = false
	else:
		# Keep the item name plate above the player, monsters and scenery.
		z_index = 20
	queue_redraw()


func _process(delta: float) -> void:
	if collected:
		return
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()
		return

	phase += delta * 3.2
	if magnet_cooldown > 0.0:
		magnet_cooldown = maxf(0.0, magnet_cooldown - delta)

	# Show the item indicator only while the player is close enough to loot it.
	if kind != "gold":
		var near := false
		if player != null and is_instance_valid(player):
			near = global_position.distance_to(player.global_position) <= INDICATOR_RANGE
		if near != player_near:
			player_near = near
			queue_redraw()

	var moving := false
	if player != null and is_instance_valid(player):
		var target_point: Vector2 = player.global_position + Vector2(0, -30)
		var distance := global_position.distance_to(target_point)
		# Gold auto-collects via magnet. Books also auto-collect; other items
		# are only collected via E (interact).
		if (kind == "gold" or auto_collect) and magnet_cooldown <= 0.0 and distance < 120.0:
			moving = true
			# Being pulled: it is no longer resting on its surface, so it must
			# be allowed to fall again (otherwise it freezes mid-air forever).
			settled = false
			var pull_speed := 220.0 + (120.0 - distance) * 3.0
			global_position = global_position.move_toward(target_point, pull_speed * delta)
			if global_position.distance_to(target_point) < 22.0:
				collect()

	# Gravity: fall until the loot rests on a surface below it. Applies to gold
	# and items alike so nothing floats in mid-air after being dropped.
	var falling := false
	if not moving and not settled:
		falling = true
		_apply_gravity(delta)

	# Only redraw while a gold piece is actually moving toward the player or
	# the loot is still falling to the ground. Stationary drops no longer
	# redraw every frame.
	if moving or falling:
		queue_redraw()


## Pulls the loot down onto the nearest surface below it so gold and items
## rest on the ground/platforms instead of floating in mid-air. Checked each
## frame until the loot lands, then it stays put. Uses the same landing math
## as the old one-time settle: CircleShape2D radius 24 at offset (0, -8) has
## its bottom edge at y + 16, so the item rests flush on the surface.
func _apply_gravity(delta: float) -> void:
	if settled:
		return
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	# CircleShape2D radius 24 at offset (0, -8): bottom edge sits at y + 16.
	var start := global_position + Vector2(0, -8.0)
	var end := start + Vector2(0, 900.0)
	var params := PhysicsRayQueryParameters2D.create(start, end)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.collision_mask = 1  # ground and platforms live on layer 1
	var hit := space.intersect_ray(params)
	if not hit.is_empty():
		var hit_pos := hit.get("position", Vector2(0, 0)) as Vector2
		global_position.y = hit_pos.y - 16.0
		settled = true
		velocity = Vector2.ZERO
		base_y = global_position.y
	else:
		# No surface below within range: fall with gravity until one is found.
		velocity.y = minf(velocity.y + GRAVITY * delta, MAX_FALL_SPEED)
		global_position.y += velocity.y * delta


## Called by the player interaction system when E is pressed on this loot.
func interact(_player: Node) -> void:
	if kind != "gold":
		collect()


## Prompt shown above the player when this loot is the nearest interactable.
func get_prompt() -> String:
	if kind == "gold" or auto_collect:
		return ""  # Auto-collects via magnet; no prompt needed
	return "Press E to pick up %s" % item_name


## Rarity color shared by the ground indicator, name plate and mobile loot list.
## Uses the item's level hue (existing visual style), with rare items boosted.
func get_rarity_color() -> Color:
	if kind == "gold":
		return Color(0.98, 0.82, 0.25)
	var data := GameData.item(item_name)
	var item_level := int(data.get("level", 1))
	var hue := clampf(0.12 + float(item_level) / 240.0, 0.0, 0.75)
	var saturation := 0.62
	var value := 0.92
	if bool(data.get("rare", false)):
		saturation = 0.78
		value = 1.0
	return Color.from_hsv(hue, saturation, value)


## Name shown in the mobile loot selection list.
func get_display_name() -> String:
	var text := item_name
	if amount > 1:
		text += " x%d" % amount
	return text


func collect() -> void:
	if collected:
		return
	collected = true
	if kind == "gold":
		GameState.add_gold(amount)
		# Show "+Gold" floating text above the player's head only on pickup.
		var stage := get_tree().get_first_node_in_group("stage")
		if stage != null and stage.has_method("spawn_floating_text"):
			var origin := global_position + Vector2(0.0, -20.0)
			var player := get_tree().get_first_node_in_group("player")
			if player != null and is_instance_valid(player):
				origin = player.global_position + Vector2(0.0, -90.0)
			stage.spawn_floating_text("+%s Gold" % GameState.format_number(amount),
				origin, Color(0.98, 0.85, 0.35), 19, 46.0, 1.05)
		queue_free()
		return
	if GameState.add_item(item_name, amount):
		GameState.message.emit("Looted %s" % item_name)
		_play_pickup_sound()
		_play_pickup_animation()
	else:
		collected = false  # Inventory full — leave it on the ground
		var steal_lvl := int(GameState.skills.get("Loot Stealer", 0))
		magnet_cooldown = maxf(0.0, 3.0 - steal_lvl * 0.07)  # Loot Stealer reduces the wait


## Short lift/fade animation before the collected drop is removed.
func _play_pickup_animation() -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position:y", position.y - 26.0, 0.28) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2(1.35, 1.35), 0.28) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 0.0, 0.28)
	tween.chain().tween_callback(queue_free)


## Plays a generated two-tone chime for collected items.
func _play_pickup_sound() -> void:
	var audio := AudioStreamPlayer.new()
	audio.stream = _get_pickup_stream()
	audio.volume_db = -5.0
	add_child(audio)
	audio.play()


static func _get_pickup_stream() -> AudioStreamWAV:
	if _pickup_stream != null:
		return _pickup_stream
	var rate := 22050
	var duration := 0.16
	var sample_count := int(rate * duration)
	var data := PackedByteArray()
	data.resize(sample_count * 2)
	for i in sample_count:
		var t := float(i) / float(rate)
		var env := 1.0 - t / duration
		env *= env
		var freq := 880.0 + 520.0 * (t / duration)
		var value := int(sin(TAU * freq * t) * env * 0.35 * 32767.0)
		data.encode_s16(i * 2, value)
	_pickup_stream = AudioStreamWAV.new()
	_pickup_stream.format = AudioStreamWAV.FORMAT_16_BITS
	_pickup_stream.mix_rate = rate
	_pickup_stream.stereo = false
	_pickup_stream.data = data
	return _pickup_stream


func _draw() -> void:
	var bob := sin(phase) * 3.0
	if kind == "gold":
		draw_circle(Vector2(0, -8 + bob), 8.0, Color(0.98, 0.82, 0.25))
		draw_circle(Vector2(0, -8 + bob), 5.0, Color(1.0, 0.92, 0.55))
		draw_line(Vector2(0, -13 + bob), Vector2(0, -3 + bob), Color(0.65, 0.48, 0.1), 2.0)
	else:
		var color := get_rarity_color()

		# Soft glow so drops stand out against the scenery.
		draw_circle(Vector2(0, -8 + bob), 18.0, Color(color.r, color.g, color.b, 0.14))
		draw_rect(Rect2(-8, -16 + bob, 16, 15), Color(0.25, 0.18, 0.12))
		draw_rect(Rect2(-8, -16 + bob, 16, 6), color)
		draw_circle(Vector2(0, -11 + bob), 2.5, Color(1, 1, 1, 0.8))

		# Small rarity-colored icon above the drop, shown when the player is near.
		if player_near:
			var icon_y := -54.0 + bob
			draw_circle(Vector2(0, icon_y), 10.0, Color(color.r, color.g, color.b, 0.28))
			draw_rect(Rect2(-6, icon_y - 6, 12, 12), color)
			draw_rect(Rect2(-6, icon_y - 6, 12, 12), Color(1, 1, 1, 0.85), false, 1.5)

		# Name plate above the drop so the player knows what is on the ground.
		var text := item_name
		if amount > 1:
			text += " x%d" % amount
		var font := ThemeDB.fallback_font
		var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var plate_width := maxf(48.0, text_width + 12.0)
		var plate := Rect2(-plate_width * 0.5, -38 + bob, plate_width, 16.0)
		draw_rect(plate, Color(0.03, 0.03, 0.04, 0.66))
		draw_rect(Rect2(plate.position, Vector2(plate.size.x, 2.0)), color)
		draw_string(font, Vector2(plate.position.x, plate.position.y + 12.0), text,
			HORIZONTAL_ALIGNMENT_CENTER, plate.size.x, 11, Color(1.0, 1.0, 1.0, 0.95))
