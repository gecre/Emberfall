extends Control
class_name TouchControls

## Touch-based virtual joystick + action buttons for mobile.
## Reuses the project's existing input actions (move_left/right, jump,
## attack, interact) so the player script needs almost no changes.

const JOYSTICK_BASE_R := 64.0
const JOYSTICK_KNOB_R := 28.0
const JOYSTICK_DEADZONE := 0.20
const BUTTON_SIZE := 104.0
const BUTTON_GAP := 16.0
const PICKUP_BUTTON_SIZE := 96.0
const LOOT_LIST_WIDTH := 240.0
const LOOT_ROW_HEIGHT := 34.0
const LOOT_HEADER_HEIGHT := 24.0

## The player controlled by these controls. Set externally or found by group.
var player: Player = null

## Normalized movement axis (-1..1) produced by the joystick.
var virtual_axis: Vector2 = Vector2.ZERO

## Touch tracking
var _joy_touch_idx := -1
var _joy_knob_offset := Vector2.ZERO
var _btn_touch_idx: Dictionary = {}   # touch index -> button name
var _button_pressed: Dictionary = {}  # button name -> bool (current frame)
var _joy_center: Vector2 = Vector2.ZERO

var _BUTTON_SPECS := [
	{"name": "attack", "label": "ATK",  "keycode": KEY_SPACE},
	{"name": "jump",   "label": "JUMP",  "keycode": KEY_W},
]

var _button_labels: Dictionary = {}  # name -> Label
## Manual-pickup loot currently in range, nearest first.
var _nearby_loot: Array = []
var _pickup_label: Label = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	for spec in _BUTTON_SPECS:
		var name := str(spec["name"])
		var lbl := Label.new()
		lbl.text = str(spec["label"])
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_constant_override("outline_size", 4)
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		lbl.add_theme_color_override("font_color", Color.WHITE)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(lbl)
		_button_labels[name] = lbl

	# Dedicated PICK UP control, separate from Attack and Jump.
	_pickup_label = Label.new()
	_pickup_label.text = "PICK UP"
	_pickup_label.add_theme_font_size_override("font_size", 15)
	_pickup_label.add_theme_constant_override("outline_size", 4)
	_pickup_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_pickup_label.add_theme_color_override("font_color", Color.WHITE)
	_pickup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pickup_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pickup_label.visible = false
	add_child(_pickup_label)

func _resolve_player() -> void:
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")

func _screen_size() -> Vector2:
	return get_viewport_rect().size

## Returns the screen-space rect for a named action button.
func _button_rect(name: String) -> Rect2:
	var size := _screen_size()
	var btn_y := size.y - 120.0
	var x := size.x - 80.0
	for i in _BUTTON_SPECS.size():
		var spec: Dictionary = _BUTTON_SPECS[i]
		if str(spec["name"]) == name:
			var bx := x - i * (BUTTON_SIZE + BUTTON_GAP)
			return Rect2(bx - BUTTON_SIZE * 0.5, btn_y - BUTTON_SIZE * 0.5, BUTTON_SIZE, BUTTON_SIZE)
	return Rect2()


## PICK UP sits above Attack/Jump so it never shares their hit areas.
func _pickup_button_rect() -> Rect2:
	var size := _screen_size()
	return Rect2(size.x - 80.0 - PICKUP_BUTTON_SIZE * 0.5,
		size.y - 258.0 - PICKUP_BUTTON_SIZE * 0.5,
		PICKUP_BUTTON_SIZE, PICKUP_BUTTON_SIZE)


func _can_pickup() -> bool:
	return not _nearby_loot.is_empty()


## Selection list shown above the PICK UP button when 2+ items are nearby.
func _loot_list_rect() -> Rect2:
	if _nearby_loot.size() <= 1:
		return Rect2()
	var header := LOOT_HEADER_HEIGHT
	var height := header + _nearby_loot.size() * LOOT_ROW_HEIGHT + 8.0
	var button := _pickup_button_rect()
	return Rect2(_screen_size().x - 16.0 - LOOT_LIST_WIDTH,
		button.position.y - 10.0 - height,
		LOOT_LIST_WIDTH, height)


func _loot_row_rect(index: int) -> Rect2:
	var list := _loot_list_rect()
	return Rect2(list.position.x + 4.0,
		list.position.y + LOOT_HEADER_HEIGHT + index * LOOT_ROW_HEIGHT,
		list.size.x - 8.0, LOOT_ROW_HEIGHT)


func _refresh_nearby_loot() -> void:
	_nearby_loot.clear()
	if player == null or not is_instance_valid(player) or player.dead:
		return
	if get_tree().paused:
		return
	if player.has_method("get_nearby_loot"):
		_nearby_loot = player.get_nearby_loot()


func _pick_up_nearest() -> void:
	_resolve_player()
	if player != null and is_instance_valid(player) and player.has_method("pick_up_nearest_loot"):
		player.pick_up_nearest_loot()
	_refresh_nearby_loot()


func _select_loot(index: int) -> void:
	if index < 0 or index >= _nearby_loot.size():
		return
	var loot: LootPickup = _nearby_loot[index] as LootPickup
	_resolve_player()
	if loot != null and is_instance_valid(loot) and player != null \
		and is_instance_valid(player) and player.has_method("pick_up_loot"):
		player.pick_up_loot(loot)
	_refresh_nearby_loot()

## Sets the joystick knob position from a screen point and updates virtual_axis.
func _set_joystick_from(pos: Vector2) -> void:
	var delta := pos - _joy_center
	var max_r := JOYSTICK_BASE_R - JOYSTICK_KNOB_R
	if max_r <= 0:
		virtual_axis = Vector2.ZERO
		return
	var dir := delta.normalized()
	var dist := clampf(delta.length(), 0.0, max_r)
	_joy_knob_offset = dir * dist
	var raw := _joy_knob_offset / max_r
	if raw.length() < JOYSTICK_DEADZONE:
		virtual_axis = Vector2.ZERO
	else:
		virtual_axis = raw.clamp(Vector2(-1.0, -1.0), Vector2(1.0, 1.0))

## Clears held joystick/button state and stops driving the player.
## Used while the controls are hidden behind a blocking UI panel.
func _reset_touch_state() -> void:
	if _joy_touch_idx == -1 and _btn_touch_idx.is_empty() \
		and _button_pressed.is_empty() and virtual_axis == Vector2.ZERO:
		return
	_joy_touch_idx = -1
	_joy_knob_offset = Vector2.ZERO
	_btn_touch_idx.clear()
	_button_pressed.clear()
	virtual_axis = Vector2.ZERO
	if player != null and is_instance_valid(player):
		player.set_virtual_axis(Vector2.ZERO)

func _process(delta: float) -> void:
	# Hidden by the HUD while a blocking panel is open: release any held
	# touch so the player doesn't keep moving/attacking behind the menu.
	if not visible:
		_reset_touch_state()
		return
	_resolve_player()
	_refresh_nearby_loot()
	var size := _screen_size()
	_joy_center = Vector2(100.0, size.y - 100.0)

	# Position button labels over their rects.
	var btn_y := size.y - 120.0
	var x := size.x - 80.0
	for i in _BUTTON_SPECS.size():
		var spec: Dictionary = _BUTTON_SPECS[i]
		var name := str(spec["name"])
		var bx := x - i * (BUTTON_SIZE + BUTTON_GAP)
		var r := Rect2(bx - BUTTON_SIZE * 0.5, btn_y - BUTTON_SIZE * 0.5, BUTTON_SIZE, BUTTON_SIZE)
		var lbl := _button_labels.get(name) as Label
		if lbl != null and is_instance_valid(lbl):
			lbl.position = r.position
			lbl.size = r.size

	# PICK UP button and its label only exist while loot is in range.
	if _pickup_label != null and is_instance_valid(_pickup_label):
		_pickup_label.visible = _can_pickup()
		if _pickup_label.visible:
			var pr := _pickup_button_rect()
			_pickup_label.position = pr.position
			_pickup_label.size = pr.size

	# Apply virtual axis to the player (zero = fall back to keyboard).
	if player != null and is_instance_valid(player):
		player.set_virtual_axis(virtual_axis)

	queue_redraw()

func _draw() -> void:
	var c := _joy_center
	draw_circle(c, JOYSTICK_BASE_R, Color(0.07, 0.07, 0.09, 0.55))
	draw_arc(c, JOYSTICK_BASE_R, 0.0, TAU, 48, Color(0.93, 0.42, 0.12, 0.55), 3.0, true)
	var joy_active := _joy_touch_idx != -1
	var knob := c + _joy_knob_offset
	draw_circle(knob, JOYSTICK_KNOB_R, Color(0.93, 0.42, 0.12, 0.9 if joy_active else 0.65))
	draw_arc(knob, JOYSTICK_KNOB_R, 0.0, TAU, 32, Color(1.0, 0.75, 0.5, 0.9), 2.0, true)
	for spec in _BUTTON_SPECS:
		var name := str(spec["name"])
		var r := _button_rect(name)
		var pressed: bool = bool(_button_pressed.get(name, false))
		var radius := r.size.x * 0.5 - (4.0 if pressed else 0.0)
		var fill := Color(0.93, 0.42, 0.12, 0.85) if name == "attack" else Color(0.07, 0.07, 0.09, 0.6)
		if pressed:
			fill = Color(1.0, 0.55, 0.22, 0.95)
		draw_circle(r.get_center(), radius, fill)
		draw_arc(r.get_center(), radius, 0.0, TAU, 48, Color(1.0, 0.6, 0.3, 0.8), 3.0, true)

	# Contextual PICK UP button.
	if _can_pickup():
		var pr := _pickup_button_rect()
		var pickup_pressed: bool = bool(_button_pressed.get("pickup", false))
		var pickup_radius := pr.size.x * 0.5 - (4.0 if pickup_pressed else 0.0)
		var pickup_fill := Color(0.20, 0.62, 0.30, 0.90)
		if pickup_pressed:
			pickup_fill = Color(0.30, 0.85, 0.42, 0.98)
		draw_circle(pr.get_center(), pickup_radius, pickup_fill)
		draw_arc(pr.get_center(), pickup_radius, 0.0, TAU, 48,
			Color(0.55, 1.0, 0.65, 0.9), 3.0, true)

	# Multiple nearby items: small selection list with icon + name rows.
	var list := _loot_list_rect()
	if list.size.x > 0.0:
		draw_rect(list, Color(0.04, 0.05, 0.06, 0.94))
		draw_rect(list, Color(0.93, 0.42, 0.12, 0.85), false, 2.0)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(list.position.x + 10.0, list.position.y + 17.0),
			"NEARBY LOOT", HORIZONTAL_ALIGNMENT_LEFT, list.size.x - 20.0, 12,
			Color(1.0, 0.82, 0.55))
		for i in range(_nearby_loot.size()):
			var loot := _nearby_loot[i] as LootPickup
			if loot == null or not is_instance_valid(loot):
				continue
			var row := _loot_row_rect(i)
			if i == 0:
				draw_rect(row, Color(1.0, 1.0, 1.0, 0.07))
			var color := loot.get_rarity_color()
			draw_circle(Vector2(row.position.x + 16.0, row.position.y + row.size.y * 0.5),
				10.0, Color(color.r, color.g, color.b, 0.25))
			draw_rect(Rect2(row.position.x + 9.0, row.position.y + 9.0, 14.0, 14.0), color)
			draw_rect(Rect2(row.position.x + 9.0, row.position.y + 9.0, 14.0, 14.0),
				Color(1.0, 1.0, 1.0, 0.85), false, 1.0)
			draw_string(font, Vector2(row.position.x + 31.0, row.position.y + 22.0),
				loot.get_display_name(), HORIZONTAL_ALIGNMENT_LEFT, row.size.x - 38.0,
				14, Color(0.95, 0.95, 0.98))

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touch_began(touch.index, touch.position)
		else:
			_touch_ended(touch.index, touch.position)
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _joy_touch_idx:
			_set_joystick_from(drag.position)

func _touch_began(idx: int, pos: Vector2) -> void:
	# Joystick takes priority.
	if _joy_touch_idx == -1 and pos.distance_to(_joy_center) < JOYSTICK_BASE_R + 30.0:
		_joy_touch_idx = idx
		_set_joystick_from(pos)
		return
	# Loot selection rows (shown only when multiple items are nearby).
	if _loot_list_rect().size.x > 0.0:
		for i in range(_nearby_loot.size()):
			if _loot_row_rect(i).has_point(pos):
				_select_loot(i)
				return
	# Contextual PICK UP button.
	if _can_pickup() and _pickup_button_rect().has_point(pos):
		_button_pressed["pickup"] = true
		_btn_touch_idx[idx] = "pickup"
		_pick_up_nearest()
		return
	# Buttons.
	for spec in _BUTTON_SPECS:
		var name := str(spec["name"])
		if _button_rect(name).has_point(pos):
			_button_pressed[name] = true
			_btn_touch_idx[idx] = name
			# Directly invoke the action so taps are reliable even if the
			# platform misses the touch-up event. One tap = one action.
			if player != null and is_instance_valid(player):
				if name == "attack":
					player.touch_attack()
				elif name == "jump":
					player.touch_jump()
			return

func _touch_ended(idx: int, pos: Vector2) -> void:
	if idx == _joy_touch_idx:
		_joy_touch_idx = -1
		_joy_knob_offset = Vector2.ZERO
		virtual_axis = Vector2.ZERO
		return
	var name := ""
	for k in _btn_touch_idx.keys():
		if _btn_touch_idx[k] == idx:
			name = k
			break
	if name != "":
		_btn_touch_idx.erase(idx)
		_button_pressed[name] = false
