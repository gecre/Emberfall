extends SceneTree

var _frames := 0
var _root: Node2D


func _initialize() -> void:
	_root = Node2D.new()
	_root.name = "TestRoot"
	get_root().add_child(_root)

	# One-way platform at y=300 (22px tall), same setup as stage.gd
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	body.position = Vector2(400, 311)  # center of rect (400,300,200x22)
	var col := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(200, 22)
	col.shape = rect
	col.one_way_collision = true
	col.one_way_collision_margin = 8.0
	body.add_child(col)
	_root.add_child(body)

	# Solid ground polygon at y=480 like the stage ground
	var ground := StaticBody2D.new()
	ground.collision_layer = 1
	ground.collision_mask = 0
	var poly := CollisionPolygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(-500, 480), Vector2(900, 480), Vector2(900, 980), Vector2(-500, 980)
	])
	ground.add_child(poly)
	_root.add_child(ground)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	var space := _root.get_world_2d().direct_space_state

	# Ray from above the platform downward (loot settling on it)
	var q := PhysicsRayQueryParameters2D.create(Vector2(400, 150), Vector2(400, 1050))
	q.collision_mask = 1
	var down_hit := space.intersect_ray(q)
	print("DOWN ray hit: ", down_hit)

	# Ray from below the platform upward
	var q2 := PhysicsRayQueryParameters2D.create(Vector2(400, 400), Vector2(400, 100))
	q2.collision_mask = 1
	var up_hit := space.intersect_ray(q2)
	print("UP ray hit: ", up_hit)

	# Ray downward but starting BELOW the platform (between platform and ground)
	var q3 := PhysicsRayQueryParameters2D.create(Vector2(400, 330), Vector2(400, 1050))
	q3.collision_mask = 1
	var mid_hit := space.intersect_ray(q3)
	print("MID ray hit: ", mid_hit)

	# Ray cast that starts INSIDE the platform body
	var q4 := PhysicsRayQueryParameters2D.create(Vector2(400, 311), Vector2(400, 1050))
	q4.collision_mask = 1
	var inside_hit := space.intersect_ray(q4)
	print("INSIDE ray hit: ", inside_hit)

	quit()
	return true
