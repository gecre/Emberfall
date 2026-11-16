extends Area2D
class_name Portal

## Stage transition gate. Walking up and pressing E reloads the world scene on
## the linked stage.

var target_number := 1
var target_name := ""
var direction := 1  # 1 = next stage, -1 = previous stage
var phase := 0.0
var _player_near := false
const PROMPT_RANGE := 100.0  # Show the "T" prompt when the player is this close.


func setup(number: int, dir: int = 1) -> void:
	target_number = number
	direction = dir
	target_name = GameData.stage_name(number)
	queue_redraw()


func _ready() -> void:
	add_to_group("portals")
	phase = randf() * TAU
	queue_redraw()


func _process(delta: float) -> void:
	phase += delta * 2.4
	var player := get_tree().get_first_node_in_group("player")
	_player_near = player != null and is_instance_valid(player) and global_position.distance_to(player.global_position) < PROMPT_RANGE
	queue_redraw()


func get_prompt() -> String:
	var arrow := "forward" if direction > 0 else "back"
	return "Click to travel %s to #%d  %s" % [arrow, target_number, target_name]


func interact(_player: Node) -> void:
	var stage := get_tree().get_first_node_in_group("stage")
	if stage != null and stage.has_method("go_to_stage"):
		stage.go_to_stage(target_number, direction)


func _draw() -> void:
	var glow := 0.55 + sin(phase) * 0.15
	var ring_color := Color(0.55, 0.85, 1.0, glow)
	if direction < 0:
		ring_color = Color(0.95, 0.78, 0.42, glow)

	# Stone arch
	draw_rect(Rect2(-46, -118, 12, 118), Color(0.42, 0.44, 0.5))
	draw_rect(Rect2(34, -118, 12, 118), Color(0.42, 0.44, 0.5))
	draw_rect(Rect2(-46, -126, 92, 14), Color(0.5, 0.52, 0.58))

	# Portal surface
	for i in range(5):
		var t := float(i) / 4.0
		var radius := 38.0 - t * 26.0
		var alpha := glow * (1.0 - t * 0.5)
		draw_circle(Vector2(0, -62), radius, Color(ring_color.r, ring_color.g, ring_color.b, alpha * 0.45))

	# Swirl
	var points := PackedVector2Array()
	for i in range(25):
		var angle := float(i) / 24.0 * TAU * 2.0 + phase
		var radius := 6.0 + float(i) * 1.15
		points.append(Vector2(cos(angle) * radius, -62 + sin(angle) * radius * 1.15))
	draw_polyline(points, Color(1, 1, 1, 0.55), 2.0)

	# Arrow
	var arrow_x := 22.0 * float(direction)
	var arrow_y := -62.0
	draw_colored_polygon(PackedVector2Array([
		Vector2(arrow_x, arrow_y - 12), Vector2(arrow_x, arrow_y + 12),
		Vector2(arrow_x + 14.0 * float(direction), arrow_y),
	]), Color(1, 1, 1, 0.8))

	# Label
	var label := "#%d %s" % [target_number, target_name]
	draw_string(ThemeDB.fallback_font, Vector2(-110, -138), label,
		HORIZONTAL_ALIGNMENT_CENTER, 220, 13, Color(1, 1, 1, 0.95))

	# Click prompt (shown above the portal when the player is near enough to click it).
	if _player_near:
		draw_string(ThemeDB.fallback_font, Vector2(-14, -152), "Click",
			HORIZONTAL_ALIGNMENT_CENTER, 28, 18, Color(1, 1, 1, 1.0))
