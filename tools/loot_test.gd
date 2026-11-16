extends SceneTree

## Reproduces the stage's physics setup (one-way platform + ground polygon)
## and spawns a real LootPickup above it, then reports its y over time.

const LOOT_SCENE := preload("res://Emberfall/scenes/entities/loot.tscn")

var _frames := 0
var _root: Node2D
var _loot_platform: Node2D
var _loot_ground: Node2D

func _initialize() -> void:
	_root = Node2D.new()
	get_root().add_child(_root)

	# One-way platform at world y=300..322 (like _build_platforms)
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector2(400, 311)
	var col := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(300, 22)
	col.shape = rect
	col.one_way_collision = true
	col.one_way_collision_margin = 8.0
	body.add_child(col)
	_root.add_child(body)

	# Solid ground polygon at y=480 (like _build_bounds)
	var ground := StaticBody2D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-500, 480), Vector2(1300, 480), Vector2(1300, 980), Vector2(-500, 980)
	])
	ground.add_child(poly)
	_root.add_child(ground)

	_loot_platform = LOOT_SCENE.instantiate()
	_loot_platform.call("setup_gold", 5)
	_loot_platform.position = Vector2(400, 150)  # above the one-way platform
	_root.add_child(_loot_platform)

	_loot_ground = LOOT_SCENE.instantiate()
	_loot_ground.call("setup_gold", 5)
	_loot_ground.position = Vector2(1000, 100)  # above plain ground, no platform
	_root.add_child(_loot_ground)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames % 30 == 0:
		print("frame %d  loot_platform.y=%s settled=%s   loot_ground.y=%s settled=%s" % [
			_frames,
			str(_loot_platform.global_position.y) if is_instance_valid(_loot_platform) else "gone",
			str(_loot_platform.get("settled")),
			str(_loot_ground.global_position.y) if is_instance_valid(_loot_ground) else "gone",
			str(_loot_ground.get("settled")),
		])
	if _frames >= 120:
		print("platform.y final: ", _loot_platform.global_position.y if is_instance_valid(_loot_platform) else "freed")
		print("ground.y final: ", _loot_ground.global_position.y if is_instance_valid(_loot_ground) else "freed")
		quit()
		return true
	return false
