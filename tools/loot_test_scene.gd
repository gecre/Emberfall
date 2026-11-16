extends Node2D

const LOOT_SCENE := preload("res://Emberfall/scenes/entities/loot.tscn")

var _frames := 0
var _loot_platform: Node2D
var _loot_ground: Node2D


func _ready() -> void:
	# One-way platform at world y=300..322 (like stage._build_platforms)
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
	add_child(body)

	# Solid ground polygon at y=480 (like stage._build_bounds)
	var ground := StaticBody2D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-500, 480), Vector2(1300, 480), Vector2(1300, 980), Vector2(-500, 980)
	])
	ground.add_child(poly)
	add_child(ground)

	_loot_platform = LOOT_SCENE.instantiate()
	_loot_platform.call("setup_gold", 5)
	_loot_platform.position = Vector2(400, 150)
	add_child(_loot_platform)

	_loot_ground = LOOT_SCENE.instantiate()
	_loot_ground.call("setup_gold", 5)
	_loot_ground.position = Vector2(1000, 100)
	add_child(_loot_ground)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames % 20 == 0:
		var py := _loot_platform.global_position.y if is_instance_valid(_loot_platform) else -999.0
		var gy := _loot_ground.global_position.y if is_instance_valid(_loot_ground) else -999.0
		var ps := str(_loot_platform.get("settled")) if is_instance_valid(_loot_platform) else "freed"
		var gs := str(_loot_ground.get("settled")) if is_instance_valid(_loot_ground) else "freed"
		print("frame %d  platform-loot y=%.1f settled=%s   ground-loot y=%.1f settled=%s" % [_frames, py, ps, gy, gs])
	if _frames >= 120:
		get_tree().quit()
