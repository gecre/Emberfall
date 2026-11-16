extends CanvasLayer
class_name HUD

const MAIN_MENU_SCENE := "res://Emberfall/scenes/interface/main_menu.tscn"

## Shop buy-mode category tabs, mapped to each item's "slot" field.
## A tab only appears when the shop actually sells that item type.
const SHOP_CATEGORIES := [
	{"label": "Weapons", "slot": "weapon"},
	{"label": "Helmets", "slot": "helmet"},
	{"label": "Armor", "slot": "armor"},
	{"label": "Legs", "slot": "legs"},
	{"label": "Boots", "slot": "boots"},
	{"label": "Shields", "slot": "shield"},
	{"label": "Accessories", "slot": "accessory"},
	{"label": "Pet Helmets", "slot": "pet_helmet"},
]

var stage = null
var player: Player = null
var paused := false

var root: Control
var hp_bar: ProgressBar
var mp_bar: ProgressBar
var xp_bar: ProgressBar
var hp_text: Label
var mp_text: Label
var level_label: Label
var gold_label: Label
var xp_label: Label
var stage_label: Label
var prompt_label: Label
var toast_box: VBoxContainer
var hotbar: HBoxContainer
var skill_bar: HBoxContainer
## Skill name -> Button, for activatable learned skills.
var _skill_buttons: Dictionary = {}
## Skill name -> cooldown Label (shows remaining seconds, or empty when ready).
var _skill_cd_labels: Dictionary = {}
var stats_label: Label
var fps_label: Label
var show_fps := false
## Label showing active timed skills (e.g. Rage) with remaining seconds.
## One label per active skill (skill_name -> Label). No PanelContainer box
## per skill — just plain text labels.
var _active_skill_labels: Dictionary = {}
var _active_skill_max: Dictionary = {}
## Separate panel holding the active skills display (outside the stats box).
var active_skills_panel: PanelContainer = null
## HBoxContainer inside the active skills panel; holds one label per active skill
## shown side by side.
var active_skills_box: VBoxContainer = null
## Cached values so _process only rewrites UI nodes when something actually
## changes (avoids per-frame label/bar redraws while idle).
var _cached_hp := -1
var _cached_max_hp: float = -1.0
var _cached_mp := -1
var _cached_max_mp: float = -1.0
var _cached_prompt := ""
var _cached_fps := -1
var _fps_accum := 0.0

var character_panel: PanelContainer
var char_stats_box: VBoxContainer
var char_help_panel: PanelContainer
var char_help_label: Label
var ability_points_label: Label
var skills_panel: PanelContainer
var skills_list: VBoxContainer
var skills_points_label: Label
var skills_tab: String = "All"
var monsterpedia_panel: PanelContainer
var monsterpedia_list: VBoxContainer
var settings_panel: PanelContainer
var zoom_label: Label
var zoom_slider: HSlider
var fps_btn: Button

var inventory_panel: PanelContainer
var inventory_grid: GridContainer
var equipment_box: VBoxContainer

## Floating context-menu that appears when clicking an inventory item.
var _item_context_popup: PanelContainer = null
## Sort menu that appears when clicking the inventory Sort button.
var _sort_popup: PanelContainer = null
## Exact screen rect of the sort popup when open; used for click dismissal so
## it matches the positioned rect regardless of content/layout sizing.
var _sort_popup_rect: Rect2 = Rect2()
## Reference to the "Quantity (Qty ↓)" sort button; hidden in the shop since
## shop items have no quantity to sort by.
var _qty_sort_button: Button = null
## Label that shows compare stats inside the inventory panel.
var _compare_label: Label = null
## Currently selected item name for the context popup.
var _context_item: String = ""
## Currently selected item name, used to highlight it in the inventory/equipment grid.
var _selected_item: String = ""
## Inventory-array index of the selected backpack item (duplicates share a name,
## so we need this to highlight only the exact button that was clicked).
var _selected_inv_index: int = -1
## Equipment slot of the selected equipped item (e.g. "weapon", "helmet").
var _selected_slot: String = ""

var shop_panel: PanelContainer
var shop_title: Label
var shop_list: VBoxContainer
var shop_category_tabs: HBoxContainer
var shop_mode := "buy"
var shop_category := ""
var shop_npc := ""
var shop_gold_label: Label
var _shop_buy_tab: Button

var pause_panel: PanelContainer
var death_panel: PanelContainer
var death_label: Label
var stage_panel: PanelContainer
var stage_list: Control
var dialogue_panel: PanelContainer
var dialogue_name_label: Label
var dialogue_text_label: Label
var chat_box = null
var friends_panel: PanelContainer

var _hotbar_assignments: Dictionary = {}

## Touch control node (mobile only).
var _touch_controls: TouchControls = null

## Cached skill status labels: skill_name -> Label (shows "CD: X.Xs" or "ACTIVE: X.Xs").
var _skill_status_labels: Dictionary = {}
## Cached skill row containers: skill_name -> HBoxContainer (for active-skill highlighting).
var _skill_rows: Dictionary = {}
## The skill name currently highlighted as active (only one at a time).
var _active_skill_name: String = ""

## Drag state for movable menus.
var _drag_active := false
var _drag_panel: PanelContainer = null
var _drag_start: Vector2 = Vector2.ZERO
var _drag_ol: float = 0.0
var _drag_ot: float = 0.0
var _drag_or: float = 0.0
var _drag_ob: float = 0.0


func _ready() -> void:
	add_to_group("hud")
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = 0  # 0 = uncapped
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_build_ui()

	GameState.stats_changed.connect(_refresh_stats)
	GameState.inventory_changed.connect(_refresh_inventory)
	GameState.equipment_changed.connect(_refresh_inventory)
	GameState.gold_changed.connect(_refresh_stats)
	GameState.message.connect(show_toast)
	GameState.leveled_up.connect(_on_leveled_up)
	_refresh_stats()
	_refresh_inventory()

	# Restore persisted FPS preference so it survives scene reloads (teleport).
	show_fps = GameState.show_fps
	if fps_label != null:
		fps_label.visible = show_fps


func bind(stage_ref, player_ref: Player) -> void:
	stage = stage_ref
	player = player_ref
	stage_label.text = "Stage #%d  %s" % [stage.stage_number, GameData.stage_name(stage.stage_number)]
	_refresh_stats()
	_refresh_inventory()
	_setup_touch_controls(player_ref)


## True on touch-first mobile platforms. Desktop keeps its existing
## mouse/keyboard interaction model even when a touchscreen is present.
func _is_mobile_platform() -> bool:
	var os_name := OS.get_name()
	return os_name == "Android" or os_name == "iOS"


## Backpack header hint. Desktop text is unchanged; mobile gets touch wording.
func _inventory_hint() -> String:
	if _is_mobile_platform():
		return "Tap an item: actions & compare"
	return "Left-click: compare  ·  Right-click: menu"


## Spawns the virtual joystick / action buttons on mobile platforms.
func _setup_touch_controls(player_ref: Player) -> void:
	if not _is_mobile_platform():
		return
	if _touch_controls != null:
		return
	_touch_controls = TouchControls.new()
	_touch_controls.player = player_ref
	add_child(_touch_controls)
	_sync_touch_controls()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------
func _style(color: Color, radius: int = 10) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	return style

func _hud_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, 0.92)
	style.set_corner_radius_all(14)
	style.border_color = Color(0.93, 0.42, 0.12, 1.0)
	style.border_width_left = 4
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 8
	style.content_margin_left = 18
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


## StyleBox used to visually mark the currently selected inventory/equipment item.
func _box(bg: Color, border: Color = Color(0, 0, 0, 0), border_w: int = 0, radius: int = 8, pad: Vector2 = Vector2(14, 8)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad.x
	sb.content_margin_right = pad.x
	sb.content_margin_top = pad.y
	sb.content_margin_bottom = pad.y
	return sb


func _modal_style() -> StyleBoxFlat:
	var s := _box(Color(0.08, 0.08, 0.10, 0.97), Color(0.35, 0.22, 0.14), 1, 14, Vector2(22, 18))
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 16
	return s


func _popup_style() -> StyleBoxFlat:
	return _box(Color(0.08, 0.08, 0.10, 0.98), Color(0.93, 0.42, 0.12, 0.8), 1, 10, Vector2(10, 10))


func _chip_style() -> StyleBoxFlat:
	return _box(Color(0.07, 0.07, 0.09, 0.9), Color(0.93, 0.42, 0.12, 0.7), 1, 20, Vector2(14, 6))


func _card_style() -> StyleBoxFlat:
	return _box(Color(0.05, 0.05, 0.07, 0.55), Color(0.18, 0.16, 0.16), 1, 10, Vector2(12, 10))


func _add_card(parent: Control, child: Control) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	card.size_flags_horizontal = child.size_flags_horizontal
	parent.add_child(card)
	card.add_child(child)
	return card


func _section_label(text: String) -> Label:
	return _make_label(text.to_upper(), 12, Color(0.65, 0.65, 0.7))


func _fmt_stat(v: Variant) -> String:
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return GameState.format_number(int(v))
	return str(v)


func _make_theme() -> Theme:
	var t := Theme.new()
	var orange := Color(0.93, 0.42, 0.12)
	var glow := Color(1.0, 0.5, 0.2)
	var none := Color(0, 0, 0, 0)

	t.set_stylebox("normal", "Button", _box(Color(0.13, 0.13, 0.16, 0.95), Color(0.3, 0.3, 0.35), 1, 8, Vector2(12, 6)))
	t.set_stylebox("hover", "Button", _box(Color(0.18, 0.15, 0.15, 0.98), glow, 1, 8, Vector2(12, 6)))
	t.set_stylebox("pressed", "Button", _box(Color(0.10, 0.10, 0.12), Color(0.8, 0.4, 0.15), 1, 8, Vector2(12, 6)))
	t.set_stylebox("disabled", "Button", _box(Color(0.09, 0.09, 0.11, 0.8), Color(0.18, 0.18, 0.22), 1, 8, Vector2(12, 6)))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.9, 0.9, 0.92))
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", glow)
	t.set_color("font_disabled_color", "Button", Color(0.4, 0.4, 0.45))

	t.set_type_variation("PrimaryButton", "Button")
	t.set_stylebox("normal", "PrimaryButton", _box(orange, none, 0, 8, Vector2(12, 6)))
	t.set_stylebox("hover", "PrimaryButton", _box(Color(1.0, 0.52, 0.2), none, 0, 8, Vector2(12, 6)))
	t.set_stylebox("pressed", "PrimaryButton", _box(Color(0.75, 0.32, 0.08), none, 0, 8, Vector2(12, 6)))
	t.set_stylebox("disabled", "PrimaryButton", _box(Color(0.25, 0.15, 0.10, 0.7), none, 0, 8, Vector2(12, 6)))
	t.set_color("font_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_hover_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_pressed_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_disabled_color", "PrimaryButton", Color(0.6, 0.5, 0.45))

	t.set_type_variation("NavButton", "Button")
	t.set_stylebox("normal", "NavButton", _box(Color(0.07, 0.07, 0.09, 0.85), Color(0.25, 0.2, 0.18), 1, 16, Vector2(14, 5)))
	t.set_stylebox("hover", "NavButton", _box(Color(0.15, 0.09, 0.06, 0.95), glow, 1, 16, Vector2(14, 5)))
	t.set_stylebox("pressed", "NavButton", _box(orange, none, 0, 16, Vector2(14, 5)))

	t.set_type_variation("SlotButton", "Button")
	t.set_stylebox("normal", "SlotButton", _box(Color(0.07, 0.07, 0.09, 0.8), Color(0.28, 0.24, 0.22), 2, 10, Vector2(6, 4)))
	t.set_stylebox("hover", "SlotButton", _box(Color(0.12, 0.09, 0.07, 0.9), glow, 2, 10, Vector2(6, 4)))
	t.set_stylebox("pressed", "SlotButton", _box(Color(0.25, 0.12, 0.05, 0.95), orange, 2, 10, Vector2(6, 4)))
	t.set_stylebox("disabled", "SlotButton", _box(Color(0.05, 0.05, 0.07, 0.6), Color(0.16, 0.16, 0.2), 2, 10, Vector2(6, 4)))

	t.set_type_variation("TabButton", "Button")
	t.set_stylebox("pressed", "TabButton", _box(Color(0.93, 0.42, 0.12, 0.25), glow, 1, 8, Vector2(12, 6)))
	t.set_stylebox("hover_pressed", "TabButton", _box(Color(0.93, 0.42, 0.12, 0.32), glow, 1, 8, Vector2(12, 6)))
	t.set_color("font_pressed_color", "TabButton", Color.WHITE)
	t.set_color("font_hover_pressed_color", "TabButton", Color.WHITE)

	var sep := StyleBoxLine.new()
	sep.color = Color(1, 1, 1, 0.10)
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 12)

	t.set_stylebox("scroll", "VScrollBar", _box(Color(0, 0, 0, 0.25), none, 0, 4, Vector2(5, 0)))
	t.set_stylebox("grabber", "VScrollBar", _box(Color(0.35, 0.3, 0.28), none, 0, 4, Vector2(5, 0)))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color(0.93, 0.42, 0.12, 0.9), none, 0, 4, Vector2(5, 0)))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(Color(1.0, 0.52, 0.2), none, 0, 4, Vector2(5, 0)))

	t.set_stylebox("slider", "HSlider", _box(Color(0.03, 0.03, 0.04), Color(0.2, 0.2, 0.24), 1, 4, Vector2(0, 3)))
	t.set_stylebox("grabber_area", "HSlider", _box(orange, none, 0, 4, Vector2(0, 3)))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(Color(1.0, 0.52, 0.2), none, 0, 4, Vector2(0, 3)))

	t.set_stylebox("panel", "TooltipPanel", _box(Color(0.06, 0.06, 0.08, 0.97), Color(0.93, 0.42, 0.12, 0.8), 1, 8, Vector2(10, 8)))
	t.set_color("font_color", "TooltipLabel", Color(0.92, 0.94, 0.95))
	t.set_font_size("font_size", "TooltipLabel", 13)
	return t


func _selection_style() -> StyleBoxFlat:
	return _box(Color(0.93, 0.42, 0.12, 0.22), Color(1.0, 0.5, 0.2), 2, 8, Vector2(12, 6))


func _make_bar(fill: Color, height: int = 18) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(260, height)
	bar.max_value = 100.0
	bar.value = 100.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.03, 0.03, 0.04, 0.95)
	bg.border_color = Color(0.2, 0.2, 0.24)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(height / 2)
	var fg := StyleBoxFlat.new()
	fg.bg_color = fill
	fg.border_color = fill.lightened(0.35)
	fg.border_width_top = 2
	fg.set_corner_radius_all(height / 2)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fg)
	return bar

func _bar_text(bar: ProgressBar) -> Label:
	var t := _make_label("", 12, Color.WHITE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	t.add_theme_constant_override("outline_size", 3)
	bar.add_child(t)
	return t


func _make_button(text: String, min_size: Vector2 = Vector2(160, 36)) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = min_size
	button.add_theme_font_size_override("font_size", 15)
	return button


func _make_label(text: String, size: int = 15, color: Color = Color(0.92, 0.96, 0.9)) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _build_ui() -> void:
	root = Control.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _make_theme()

	# ---- top left stats ----
	var top_left := PanelContainer.new()
	top_left.add_theme_stylebox_override("panel", _hud_panel_style())
	top_left.position = Vector2(16, 16)
	top_left.custom_minimum_size = Vector2(292, 0)
	root.add_child(top_left)

	var stats_box := VBoxContainer.new()
	stats_box.add_theme_constant_override("separation", 8)
	top_left.add_child(stats_box)

	level_label = _make_label("Lv 1  Hero", 20, Color(1.0, 0.85, 0.7))
	level_label.add_theme_color_override("font_outline_color", Color(0.2, 0.08, 0.02, 0.9))
	level_label.add_theme_constant_override("outline_size", 4)
	stats_box.add_child(level_label)

	hp_bar = _make_bar(Color(0.88, 0.27, 0.25), 20)
	stats_box.add_child(hp_bar)
	hp_text = _bar_text(hp_bar)

	mp_bar = _make_bar(Color(0.25, 0.52, 0.95), 20)
	stats_box.add_child(mp_bar)
	mp_text = _bar_text(mp_bar)

	xp_bar = _make_bar(Color(1.0, 0.6, 0.2), 6)
	xp_bar.max_value = 1.0
	stats_box.add_child(xp_bar)

	var bottom_row := HBoxContainer.new()
	stats_box.add_child(bottom_row)
	gold_label = _make_label("0 gold", 14, Color(1.0, 0.82, 0.3))
	bottom_row.add_child(gold_label)
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_row.add_child(bottom_spacer)
	xp_label = _make_label("0 / 0 XP", 12, Color(0.65, 0.65, 0.7))
	bottom_row.add_child(xp_label)

	# ---- Active skills: stacked list under the stats card ----
	active_skills_panel = PanelContainer.new()
	active_skills_panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	active_skills_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	active_skills_panel.position = Vector2(16, 180)
	active_skills_panel.custom_minimum_size = Vector2(220, 0)
	active_skills_panel.visible = false
	root.add_child(active_skills_panel)

	var active_box := VBoxContainer.new()
	active_box.add_theme_constant_override("separation", 4)
	active_skills_panel.add_child(active_box)
	active_skills_box = active_box

	# ---- top right menu buttons ----
	var top_right := HBoxContainer.new()
	top_right.alignment = BoxContainer.ALIGNMENT_END
	top_right.add_theme_constant_override("separation", 6)
	top_right.anchor_left = 1.0
	top_right.anchor_right = 1.0
	top_right.offset_left = -740.0
	top_right.offset_right = -12.0
	top_right.offset_top = 12.0
	root.add_child(top_right)

	var char_button := _make_button("Character", Vector2(100, 32))
	char_button.add_theme_font_size_override("font_size", 13)
	char_button.pressed.connect(_toggle_character_panel)
	top_right.add_child(char_button)

	var skills_button := _make_button("Skills", Vector2(76, 32))
	skills_button.add_theme_font_size_override("font_size", 13)
	skills_button.pressed.connect(_toggle_skills_panel)
	top_right.add_child(skills_button)

	var map_button := _make_button("Map", Vector2(64, 32))
	map_button.add_theme_font_size_override("font_size", 13)
	map_button.pressed.connect(_open_stage_panel)
	top_right.add_child(map_button)

	var inv_button := _make_button("Items", Vector2(64, 32))
	inv_button.add_theme_font_size_override("font_size", 13)
	inv_button.pressed.connect(_toggle_inventory)
	top_right.add_child(inv_button)

	var chat_button := _make_button("Chat", Vector2(64, 32))
	chat_button.add_theme_font_size_override("font_size", 13)
	chat_button.pressed.connect(_toggle_chat_box)
	top_right.add_child(chat_button)

	var pedia_button := _make_button("Monsterpedia", Vector2(120, 32))
	pedia_button.add_theme_font_size_override("font_size", 13)
	pedia_button.pressed.connect(_toggle_monsterpedia)
	top_right.add_child(pedia_button)

	var options_button := _make_button("Options", Vector2(76, 32))
	options_button.add_theme_font_size_override("font_size", 13)
	options_button.pressed.connect(_toggle_settings)
	top_right.add_child(options_button)

	var friends_button := _make_button("👥 Friends", Vector2(100, 32))
	friends_button.add_theme_font_size_override("font_size", 13)
	friends_button.pressed.connect(_toggle_friends)
	top_right.add_child(friends_button)

	# Mobile-only Pause entry point; Esc remains the desktop shortcut.
	var pause_button := _make_button("Pause", Vector2(76, 32))
	pause_button.add_theme_font_size_override("font_size", 13)
	pause_button.pressed.connect(_toggle_pause_panel)
	pause_button.visible = _is_mobile_platform()
	top_right.add_child(pause_button)

	for b in top_right.get_children():
		(b as Control).theme_type_variation = "NavButton"

	# ---- stage label below menu ----
	stage_label = _make_label("Stage", 18, Color(1.0, 0.85, 0.7))
	stage_label.add_theme_color_override("font_outline_color", Color(0.2, 0.08, 0.02, 0.9))
	stage_label.add_theme_constant_override("outline_size", 5)
	stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stage_label.anchor_left = 1.0
	stage_label.anchor_right = 1.0
	stage_label.offset_left = -740.0
	stage_label.offset_right = -14.0
	stage_label.offset_top = 54.0
	root.add_child(stage_label)

	# ---- prompt ----
	prompt_label = _make_label("", 17, Color(1.0, 0.95, 0.7))
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.anchor_left = 0.5
	prompt_label.anchor_right = 0.5
	prompt_label.anchor_top = 1.0
	prompt_label.anchor_bottom = 1.0
	prompt_label.offset_left = -320.0
	prompt_label.offset_right = 320.0
	prompt_label.offset_top = -176.0
	prompt_label.offset_bottom = -146.0
	root.add_child(prompt_label)

	# ---- hotbar ----
	hotbar = HBoxContainer.new()
	hotbar.alignment = BoxContainer.ALIGNMENT_CENTER
	hotbar.add_theme_constant_override("separation", 8)
	hotbar.anchor_left = 0.5
	hotbar.anchor_right = 0.5
	hotbar.anchor_top = 1.0
	hotbar.anchor_bottom = 1.0
	hotbar.offset_left = -300.0
	hotbar.offset_right = 300.0
	hotbar.offset_top = -124.0
	hotbar.offset_bottom = -64.0
	root.add_child(hotbar)

	# ---- skill bar (activatable learned skills) ----
	skill_bar = HBoxContainer.new()
	skill_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	skill_bar.add_theme_constant_override("separation", 8)
	skill_bar.anchor_left = 0.5
	skill_bar.anchor_right = 0.5
	skill_bar.anchor_top = 1.0
	skill_bar.anchor_bottom = 1.0
	skill_bar.offset_left = -480.0
	skill_bar.offset_right = 480.0
	skill_bar.offset_top = -56.0
	skill_bar.offset_bottom = -8.0
	root.add_child(skill_bar)

	# ---- toasts ----
	toast_box = VBoxContainer.new()
	toast_box.alignment = BoxContainer.ALIGNMENT_CENTER
	toast_box.anchor_left = 0.5
	toast_box.anchor_right = 0.5
	toast_box.offset_left = -300.0
	toast_box.offset_right = 300.0
	toast_box.offset_top = 92.0
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast_box)

	# ---- FPS counter (toggled from Options) ----
	fps_label = _make_label("FPS: 0", 14, Color(0.9, 1.0, 0.8))
	fps_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	fps_label.add_theme_constant_override("outline_size", 3)
	fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	fps_label.anchor_left = 1.0
	fps_label.anchor_right = 1.0
	fps_label.anchor_top = 1.0
	fps_label.anchor_bottom = 1.0
	fps_label.offset_left = -140.0
	fps_label.offset_right = -12.0
	fps_label.offset_top = -30.0
	fps_label.offset_bottom = -12.0
	fps_label.visible = false
	fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(fps_label)

	_build_inventory_panel()
	_build_shop_panel()
	_build_pause_panel()
	_build_death_panel()
	_build_stage_panel()
	_build_dialogue_panel()
	_build_character_panel()
	_build_skills_panel()
	_build_monsterpedia_panel()
	_build_settings_panel()
	_build_chat_box()
	_build_friends_panel()


func _build_chat_box() -> void:
	chat_box = preload("res://Emberfall/scripts/ui/chat_box.gd").new()
	var screen_h := 720.0
	if get_viewport() != null:
		screen_h = get_viewport().get_visible_rect().size.y
	if _is_mobile_platform():
		chat_box.position = Vector2(16, maxf(180, screen_h - 380))
		chat_box.is_minimized = true
		chat_box._toggle_minimize()
	else:
		chat_box.position = Vector2(16, maxf(280, screen_h - 240))
	root.add_child(chat_box)


func _toggle_chat_box() -> void:
	if chat_box != null and is_instance_valid(chat_box):
		chat_box.toggle_window()


func _centered_panel(min_size: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _modal_style())
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -min_size.x * 0.5
	panel.offset_right = min_size.x * 0.5
	panel.offset_top = -min_size.y * 0.5
	panel.offset_bottom = min_size.y * 0.5
	panel.custom_minimum_size = min_size
	panel.visible = false
	root.add_child(panel)
	return panel


## Makes a panel draggable by its title bar (handle), or by the whole panel
## when no handle is given. Dragging pans the panel by the mouse delta while
## preserving its size. All coordinates are in viewport space so the panel
## doesn't shake as it moves.
func _make_draggable(panel: PanelContainer, handle: Control = null) -> void:
	var target := handle if handle != null else panel
	target.mouse_filter = Control.MOUSE_FILTER_STOP
	target.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_drag_active = true
				_drag_panel = panel
				_drag_start = get_viewport().get_mouse_position()
				_drag_ol = panel.offset_left
				_drag_ot = panel.offset_top
				_drag_or = panel.offset_right
				_drag_ob = panel.offset_bottom
				get_viewport().set_input_as_handled()
			elif _drag_active and _drag_panel == panel:
				_drag_active = false
				_drag_panel = null
		elif event is InputEventMouseMotion and _drag_active and _drag_panel == panel:
			var mouse: Vector2 = get_viewport().get_mouse_position()
			var delta: Vector2 = mouse - _drag_start
			panel.offset_left = _drag_ol + delta.x
			panel.offset_top = _drag_ot + delta.y
			panel.offset_right = _drag_or + delta.x
			panel.offset_bottom = _drag_ob + delta.y
			get_viewport().set_input_as_handled()
	)


func _build_inventory_panel() -> void:
	inventory_panel = _centered_panel(Vector2(1020, 540))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	inventory_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := _make_label("Inventory & Equipment", 22, Color(1.0, 0.5, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var sort_button := _make_button("Sort", Vector2(80, 34))
	sort_button.add_theme_font_size_override("font_size", 13)
	sort_button.pressed.connect(_open_sort_menu)
	header.add_child(sort_button)
	var close_button := _make_button("Close", Vector2(90, 34))
	close_button.pressed.connect(_close_panels)
	header.add_child(close_button)
	_make_draggable(inventory_panel, header)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	outer.add_child(body)

	# ---- Left column: equipped gear + current stats ----
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(260, 0)
	left.add_theme_constant_override("separation", 6)
	_add_card(body, left)
	left.add_child(_section_label("Equipped"))
	equipment_box = VBoxContainer.new()
	equipment_box.add_theme_constant_override("separation", 5)
	left.add_child(equipment_box)
	stats_label = _make_label("", 13, Color(0.75, 0.85, 0.8))
	stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_label.custom_minimum_size = Vector2(260, 0)
	left.add_child(stats_label)

	# ---- Centre column: backpack grid ----
	var centre := VBoxContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.custom_minimum_size = Vector2(460, 0)
	_add_card(body, centre)
	centre.add_child(_section_label("Backpack   " + _inventory_hint()))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	centre.add_child(scroll)
	inventory_grid = GridContainer.new()
	inventory_grid.columns = 3
	inventory_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inventory_grid.add_theme_constant_override("h_separation", 8)
	inventory_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(inventory_grid)

	# ---- Right column: compare stats ----
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(240, 0)
	right.add_theme_constant_override("separation", 6)
	_add_card(body, right)
	right.add_child(_section_label("Compare"))
	_compare_label = _make_label("", 13, Color(0.82, 0.9, 0.98))
	_compare_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_compare_label.custom_minimum_size = Vector2(240, 0)
	right.add_child(_compare_label)

	# ---- Context popup (appears at mouse position on right-click) ----
	_item_context_popup = PanelContainer.new()
	_item_context_popup.add_theme_stylebox_override("panel", _popup_style())
	_item_context_popup.visible = false
	_item_context_popup.z_index = 20
	root.add_child(_item_context_popup)
	var popup_box := VBoxContainer.new()
	popup_box.name = "VBoxContainer"
	popup_box.add_theme_constant_override("separation", 6)
	_item_context_popup.add_child(popup_box)

	var title_lbl := _make_label("Item Menu", 15, Color(1.0, 0.88, 0.45))
	title_lbl.name = "ItemTitle"
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	popup_box.add_child(title_lbl)

	# Popup buttons — text/action set dynamically in _show_item_context()
	for btn_label in ["Equip", "Unequip", "Use", "Drop", "Lock"]:
		var btn := _make_button(btn_label, Vector2(160, 34))
		btn.name = btn_label
		popup_box.add_child(btn)

	popup_box.get_node("Equip").pressed.connect(_context_equip)
	popup_box.get_node("Unequip").pressed.connect(_context_unequip)
	popup_box.get_node("Use").pressed.connect(_context_use)
	popup_box.get_node("Drop").pressed.connect(_context_drop)
	popup_box.get_node("Lock").pressed.connect(_context_lock)

	# Hotbar assignment buttons — assign a consumable to slots 1–5.
	for i in range(5):
		var hbtn := _make_button("Hotbar %d" % [i + 1], Vector2(160, 34))
		hbtn.name = "Hotbar %d" % [i + 1]
		popup_box.add_child(hbtn)
		hbtn.pressed.connect(_context_hotbar.bind(i))

	# ---- Sort popup menu (opened by the Sort button) ----
	_sort_popup = PanelContainer.new()
	_sort_popup.add_theme_stylebox_override("panel", _popup_style())
	_sort_popup.visible = false
	_sort_popup.z_index = 20
	root.add_child(_sort_popup)
	var sort_box := VBoxContainer.new()
	sort_box.add_theme_constant_override("separation", 4)
	_sort_popup.add_child(sort_box)
	var sort_title := _make_label("Sort by", 14, Color(1.0, 0.88, 0.45))
	sort_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sort_box.add_child(sort_title)
	for opt in [
		{"label": "Name (A-Z)", "by": "name"},
		{"label": "Level (Lvl ↑)", "by": "level_asc"},
		{"label": "Level (Lvl ↓)", "by": "level_desc"},
		{"label": "Quantity (Qty ↓)", "by": "qty_desc"},
	]:
		var btn := _make_button(opt["label"], Vector2(150, 32))
		btn.add_theme_font_size_override("font_size", 13)
		btn.pressed.connect(_on_sort_criterion_selected.bind(opt["by"]))
		btn.pressed.connect(func(): _sort_popup.visible = false)
		if opt["by"] == "qty_desc":
			btn.name = "QtySortBtn"
			_qty_sort_button = btn
		sort_box.add_child(btn)


func _build_shop_panel() -> void:
	shop_panel = _centered_panel(Vector2(820, 520))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	shop_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	shop_title = _make_label("Shop", 22, Color(1.0, 0.5, 0.2))
	shop_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(shop_title)
	shop_gold_label = _make_label("0 gold", 16, Color(1.0, 0.82, 0.3))
	shop_gold_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(shop_gold_label)
	var gold_gap := Control.new()
	gold_gap.custom_minimum_size = Vector2(14, 0)
	header.add_child(gold_gap)
	var close_button := _make_button("Close", Vector2(90, 34))
	close_button.pressed.connect(_close_panels)
	header.add_child(close_button)
	_make_draggable(shop_panel, header)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	outer.add_child(tabs)
	var mode_group := ButtonGroup.new()
	var buy_tab := _make_button("Buy", Vector2(120, 34))
	buy_tab.theme_type_variation = "TabButton"
	buy_tab.toggle_mode = true
	buy_tab.button_group = mode_group
	buy_tab.button_pressed = true
	buy_tab.pressed.connect(_set_shop_mode.bind("buy"))
	tabs.add_child(buy_tab)
	_shop_buy_tab = buy_tab
	var sell_tab := _make_button("Sell", Vector2(120, 34))
	sell_tab.theme_type_variation = "TabButton"
	sell_tab.toggle_mode = true
	sell_tab.button_group = mode_group
	sell_tab.pressed.connect(_set_shop_mode.bind("sell"))
	tabs.add_child(sell_tab)

	shop_category_tabs = HBoxContainer.new()
	shop_category_tabs.add_theme_constant_override("separation", 6)
	outer.add_child(shop_category_tabs)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	shop_list = VBoxContainer.new()
	shop_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shop_list.add_theme_constant_override("separation", 6)
	scroll.add_child(shop_list)


func _build_pause_panel() -> void:
	pause_panel = _centered_panel(Vector2(380, 330))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pause_panel.add_child(box)
	box.add_child(_make_label("Paused", 26, Color(1.0, 0.5, 0.2)))

	var resume := _make_button("Resume", Vector2(320, 40))
	resume.theme_type_variation = "PrimaryButton"
	resume.pressed.connect(_close_panels)
	box.add_child(resume)

	var options := _make_button("Options / Graphics", Vector2(320, 40))
	options.pressed.connect(_toggle_settings)
	box.add_child(options)

	var save := _make_button("Save Game", Vector2(320, 40))
	save.pressed.connect(func() -> void:
		GameState.save_game()
		show_toast("Game saved.")
	)
	box.add_child(save)

	var stages_button := _make_button("Stage Select", Vector2(320, 40))
	stages_button.pressed.connect(_open_stage_panel)
	box.add_child(stages_button)

	var menu := _make_button("Save & Main Menu", Vector2(320, 40))
	menu.pressed.connect(_go_to_menu)
	box.add_child(menu)
	_make_draggable(pause_panel)


func _build_death_panel() -> void:
	death_panel = _centered_panel(Vector2(460, 300))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	death_panel.add_child(box)
	box.add_child(_make_label("You were defeated", 28, Color(0.95, 0.4, 0.35)))
	death_label = _make_label("", 16, Color(0.9, 0.85, 0.7))
	death_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(death_label)

	var respawn := _make_button("Respawn at stage start", Vector2(400, 42))
	respawn.theme_type_variation = "PrimaryButton"
	respawn.pressed.connect(_on_respawn_pressed)
	box.add_child(respawn)

	var menu := _make_button("Main Menu", Vector2(400, 42))
	menu.pressed.connect(_go_to_menu)
	box.add_child(menu)
	_make_draggable(death_panel)


func _build_stage_panel() -> void:
	stage_panel = _centered_panel(Vector2(520, 460))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	stage_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := _make_label("Stage Select", 22, Color(1.0, 0.5, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := _make_button("Close", Vector2(90, 34))
	close_button.pressed.connect(_close_panels)
	header.add_child(close_button)
	_make_draggable(stage_panel, header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	stage_list = GridContainer.new()
	stage_list.columns = 4
	stage_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stage_list.add_theme_constant_override("h_separation", 10)
	stage_list.add_theme_constant_override("v_separation", 8)
	scroll.add_child(stage_list)


func _build_dialogue_panel() -> void:
	dialogue_panel = _centered_panel(Vector2(620, 260))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	dialogue_panel.add_child(box)
	dialogue_name_label = _make_label("NPC", 22, Color(1.0, 0.5, 0.2))
	box.add_child(dialogue_name_label)
	dialogue_text_label = _make_label("...", 16, Color(0.9, 0.94, 0.88))
	dialogue_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialogue_text_label.custom_minimum_size = Vector2(580, 90)
	box.add_child(dialogue_text_label)
	var close_button := _make_button("Close", Vector2(120, 36))
	close_button.pressed.connect(_close_panels)
	box.add_child(close_button)
	_make_draggable(dialogue_panel)


func _build_character_panel() -> void:
	character_panel = _centered_panel(Vector2(980, 600))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	character_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := _make_label("Character Info", 22, Color(1.0, 0.5, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := _make_button("X", Vector2(40, 34))
	close_btn.pressed.connect(_close_panels)
	header.add_child(close_btn)
	_make_draggable(character_panel, header)

	ability_points_label = _make_label("Stat Points: 0   |   Skill Points: 0", 16, Color(0.5, 1.0, 0.5))
	outer.add_child(ability_points_label)

	var char_scroll := ScrollContainer.new()
	char_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	char_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(char_scroll)
	char_stats_box = VBoxContainer.new()
	char_stats_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	char_stats_box.add_theme_constant_override("separation", 6)
	char_scroll.add_child(char_stats_box)

	# Click/tap help for the "?" stat buttons. Tooltips only appear on mouse
	# hover, so touch devices need this visible text instead.
	char_help_panel = PanelContainer.new()
	char_help_panel.add_theme_stylebox_override("panel", _card_style())
	char_help_panel.visible = false
	outer.add_child(char_help_panel)
	char_help_label = _make_label("", 14, Color(0.95, 0.9, 0.72))
	char_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	char_help_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	char_help_panel.add_child(char_help_label)


func _build_skills_panel() -> void:
	skills_panel = _centered_panel(Vector2(700, 520))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	skills_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := _make_label("Skills", 22, Color(1.0, 0.5, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := _make_button("X", Vector2(40, 34))
	close_btn.pressed.connect(_close_panels)
	header.add_child(close_btn)
	_make_draggable(skills_panel, header)

	var sub_header := HBoxContainer.new()
	sub_header.add_theme_constant_override("separation", 16)
	outer.add_child(sub_header)
	skills_points_label = _make_label("Skill Points: 0", 16, Color(0.4, 0.95, 0.5))
	skills_points_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub_header.add_child(skills_points_label)

	var tabs_row := HBoxContainer.new()
	tabs_row.add_theme_constant_override("separation", 6)
	outer.add_child(tabs_row)
	var tab_group := ButtonGroup.new()
	for t in ["All", "General", "Class"]:
		var tab_btn := _make_button(t, Vector2(90, 30))
		tab_btn.add_theme_font_size_override("font_size", 13)
		tab_btn.theme_type_variation = "TabButton"
		tab_btn.toggle_mode = true
		tab_btn.button_group = tab_group
		tab_btn.button_pressed = (t == skills_tab)
		tab_btn.pressed.connect(_set_skills_tab.bind(t))
		tabs_row.add_child(tab_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	skills_list = VBoxContainer.new()
	skills_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skills_list.add_theme_constant_override("separation", 6)
	scroll.add_child(skills_list)


func _build_monsterpedia_panel() -> void:
	monsterpedia_panel = _centered_panel(Vector2(620, 500))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	monsterpedia_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := _make_label("Monsterpedia", 22, Color(1.0, 0.5, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := _make_button("X", Vector2(40, 34))
	close_btn.pressed.connect(_close_panels)
	header.add_child(close_btn)
	_make_draggable(monsterpedia_panel, header)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	monsterpedia_list = VBoxContainer.new()
	monsterpedia_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	monsterpedia_list.add_theme_constant_override("separation", 4)
	scroll.add_child(monsterpedia_list)


func _build_settings_panel() -> void:
	settings_panel = _centered_panel(Vector2(560, 360))
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	settings_panel.add_child(outer)

	var header := HBoxContainer.new()
	outer.add_child(header)
	var title := _make_label("Options & Graphics", 22, Color(1.0, 0.5, 0.2))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := _make_button("X", Vector2(40, 34))
	close_btn.pressed.connect(_close_panels)
	header.add_child(close_btn)
	_make_draggable(settings_panel, header)

	# --- Camera Zoom Section ---
	var zoom_section := VBoxContainer.new()
	zoom_section.add_theme_constant_override("separation", 6)
	_add_card(outer, zoom_section)

	zoom_label = _make_label("Camera Zoom: 1.00x", 16, Color(0.92, 0.96, 0.9))
	zoom_section.add_child(zoom_label)

	zoom_slider = HSlider.new()
	zoom_slider.min_value = 0.5
	zoom_slider.max_value = 1.8
	zoom_slider.step = 0.05
	zoom_slider.value = GameState.camera_zoom
	zoom_slider.custom_minimum_size = Vector2(440, 24)
	zoom_slider.value_changed.connect(_on_zoom_slider_changed)
	zoom_section.add_child(zoom_slider)

	var zoom_presets := HBoxContainer.new()
	zoom_presets.add_theme_constant_override("separation", 6)
	zoom_section.add_child(zoom_presets)

	var presets: Array = [
		{"label": "0.65x (Wide)", "val": 0.65},
		{"label": "0.85x", "val": 0.85},
		{"label": "1.00x (Default)", "val": 1.0},
		{"label": "1.25x", "val": 1.25},
		{"label": "1.50x (Close)", "val": 1.5},
	]
	for p in presets:
		var pbtn := _make_button(p["label"], Vector2(90, 28))
		pbtn.add_theme_font_size_override("font_size", 11)
		pbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pbtn.pressed.connect(_apply_zoom.bind(p["val"]))
		zoom_presets.add_child(pbtn)


	# --- Graphics Section ---
	var gfx_section := VBoxContainer.new()
	gfx_section.add_theme_constant_override("separation", 8)
	_add_card(outer, gfx_section)
	gfx_section.add_child(_section_label("Display Mode"))

	var gfx_row := HBoxContainer.new()
	gfx_row.add_theme_constant_override("separation", 10)
	gfx_section.add_child(gfx_row)

	var fs_btn := _make_button("Toggle Fullscreen", Vector2(180, 36))
	fs_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fs_btn.pressed.connect(_toggle_fullscreen)
	gfx_row.add_child(fs_btn)

	var vsync_btn := _make_button("Toggle V-Sync", Vector2(160, 36))
	vsync_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vsync_btn.pressed.connect(_toggle_vsync)
	gfx_row.add_child(vsync_btn)

	var fps_btn := _make_button("Show FPS: Off", Vector2(160, 36))
	fps_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fps_btn.pressed.connect(_toggle_show_fps)
	gfx_row.add_child(fps_btn)
	self.fps_btn = fps_btn


# ---------------------------------------------------------------------------
# Live updates
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	var stats := GameState.stats()
	var hp := GameState.current_hp
	var mp := GameState.current_mp
	var max_hp: float = float(stats["max_hp"])
	var max_mp: float = float(stats["max_mp"])

	# Only rewrite bars/labels when the underlying values change.
	if hp != _cached_hp or max_hp != _cached_max_hp:
		hp_bar.max_value = float(max_hp)
		hp_bar.value = float(hp)
		hp_text.text = "%d / %d" % [hp, max_hp]
		_cached_hp = hp
		_cached_max_hp = max_hp
	if mp != _cached_mp or max_mp != _cached_max_mp:
		mp_bar.max_value = float(max_mp)
		mp_bar.value = float(mp)
		mp_text.text = "%d / %d" % [mp, max_mp]
		_cached_mp = mp
		_cached_max_mp = max_mp

	# Update skill bar buttons: cooldown timers and MP availability.
	if skill_bar != null and not paused:
		GameState.update_skill_cooldowns(_delta)
		for sname in _skill_buttons.keys():
			var btn: Button = _skill_buttons[sname]
			var sdata := GameData.skill(sname)
			var cost := int(sdata.get("mana_cost", 0))
			var cur_lvl := int(GameState.skills.get(sname, 0))
			var remaining := float(GameState.skill_cooldowns.get(sname, 0))

			var key := _skill_key(sname)
			if remaining > 0.0:
				btn.disabled = true
				btn.text = "%s  [%s]  Lv%d (%.1fs)" % [sname, key, cur_lvl, remaining]
			elif mp < cost:
				btn.disabled = true
				btn.text = "%s  [%s]  Lv%d (need %d MP)" % [sname, key, cur_lvl, cost]
			else:
				btn.disabled = false
				btn.text = "%s  [%s]  Lv%d" % [sname, key, cur_lvl]

	# Decrement active skill durations (e.g. Rage countdown).
	GameState.update_active_skills(_delta)

	# Active skills: one compact chip per skill (name + seconds + thin timer bar).
	var active := GameState.get_active_skills()
	if active_skills_panel != null:
		active_skills_panel.visible = not active.is_empty()
	var seen: Array = []
	for key in active.keys():
		seen.append(key)
		var remaining := float(active[key])
		var perm: bool = key == "Block" or remaining > 60.0
		if not _active_skill_labels.has(key):
			_active_skill_max[key] = maxf(remaining, 1.0)
			var chip := PanelContainer.new()
			chip.add_theme_stylebox_override("panel", _chip_style())
			chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var box := VBoxContainer.new()
			box.add_theme_constant_override("separation", 3)
			chip.add_child(box)
			var top := HBoxContainer.new()
			box.add_child(top)
			var lbl := _make_label(str(key), 13, Color(1.0, 0.85, 0.7))
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			top.add_child(lbl)
			var tlbl := _make_label("", 13, Color(1.0, 0.82, 0.3))
			top.add_child(tlbl)
			chip.set_meta("time", tlbl)
			var bar := _make_bar(Color(1.0, 0.6, 0.2), 4)
			bar.custom_minimum_size = Vector2(0, 4)
			box.add_child(bar)
			chip.set_meta("lbl", lbl)
			chip.set_meta("bar", bar)
			if active_skills_box != null:
				active_skills_box.add_child(chip)
			_active_skill_labels[key] = chip
		var c: PanelContainer = _active_skill_labels[key]
		if not is_instance_valid(c):
			continue
		if remaining > float(_active_skill_max[key]):
			_active_skill_max[key] = remaining
		var c_lbl: Label = c.get_meta("time")
		var c_bar: ProgressBar = c.get_meta("bar")
		c_lbl.text = "Active" if perm else "%ds" % int(ceil(remaining))
		c_bar.max_value = float(_active_skill_max[key])
		c_bar.value = c_bar.max_value if perm else remaining
	for key in _active_skill_labels.keys():
		if not seen.has(key):
			var old: PanelContainer = _active_skill_labels[key]
			if is_instance_valid(old):
				old.queue_free()
			_active_skill_labels.erase(key)
			_active_skill_max.erase(key)

	if prompt_label != null:
		var prompt := player.get_prompt()
		if paused or prompt == "":
			prompt = ""
		if prompt != _cached_prompt:
			prompt_label.text = prompt
			_cached_prompt = prompt

	if show_fps and fps_label != null:
		_fps_accum += _delta
		if _fps_accum >= 0.5:
			var fps := int(Engine.get_frames_per_second())
			if fps != _cached_fps:
				fps_label.text = "FPS: %d" % fps
				_cached_fps = fps
			_fps_accum = 0.0

	# Refresh each skill's cooldown / active status label while the skills panel is open.
	if skills_panel != null and skills_panel.visible:
		_refresh_skill_status()


func _refresh_stats() -> void:
	if hp_bar == null:
		return
	var stats := GameState.stats()
	var hp := GameState.current_hp
	var mp := GameState.current_mp
	var max_hp: float = float(stats["max_hp"])
	var max_mp: float = float(stats["max_mp"])

	level_label.text = "Lv %d  %s  (%s)" % [GameState.level, GameState.player_name, GameState.player_class]
	gold_label.text = "%s gold" % GameState.format_number(GameState.gold)
	xp_label.text = "%d / %d XP" % [GameState.xp, GameState.xp_to_next()]
	xp_bar.value = GameState.xp_progress()

	if hp != _cached_hp or max_hp != _cached_max_hp:
		hp_bar.max_value = max_hp
		hp_bar.value = float(hp)
		hp_text.text = "%d / %d" % [hp, int(max_hp)]
		_cached_hp = hp
		_cached_max_hp = max_hp
	if mp != _cached_mp or max_mp != _cached_max_mp:
		mp_bar.max_value = max_mp
		mp_bar.value = float(mp)
		mp_text.text = "%d / %d" % [mp, int(max_mp)]
		_cached_mp = mp
		_cached_max_mp = max_mp

	if skill_bar != null:
		_rebuild_skill_bar()

	if stats_label != null and stats_label.is_inside_tree():
		stats_label.text = "Defense %d   Power %d\nDamage %.0f - %.0f   Reach %.1f\nCrit %d%%   Magic %d   Luck %d" % [
			int(stats["defense"]), int(stats["power"]),
			float(stats["damage_min"]), float(stats["damage_max"]), float(stats["reach"]),
			int(round(float(stats["crit_chance"]) * 100.0)),
			int(stats["magic"]), int(stats["luck"]),
		]

	if character_panel != null and character_panel.visible:
		_rebuild_character_panel()
	if skills_panel != null and skills_panel.visible:
		_rebuild_skills_panel()


func _on_leveled_up(new_level: int) -> void:
	show_toast("Level up!  You are now level %d." % new_level)
	show_toast("+3 stat points   +1 special skill point")
	_refresh_stats()
	if character_panel != null and character_panel.visible:
		_rebuild_character_panel()
	if skills_panel != null and skills_panel.visible:
		_rebuild_skills_panel()


func _refresh_inventory() -> void:
	if hotbar != null:
		_rebuild_hotbar()
	if inventory_panel != null and inventory_panel.visible:
		_rebuild_inventory()
	_refresh_stats()


func _rebuild_hotbar() -> void:
	_clear(hotbar)
	for i in range(5):
		var button := _make_button("", Vector2(112, 52))
		button.add_theme_font_size_override("font_size", 12)
		button.theme_type_variation = "SlotButton"
		var item_name := ""
		if _hotbar_assignments.has(i):
			item_name = str(_hotbar_assignments[i])
		if item_name != "":
			var qty := GameState.count_item(item_name)
			button.text = "%d\n%s x%d" % [i + 1, item_name, qty]
			button.pressed.connect(_use_hotbar.bind(i))
			button.tooltip_text = _item_tooltip(GameData.item(item_name))
			if qty <= 0:
				button.disabled = true
				button.text = "%d\n%s (empty)" % [i + 1, item_name]
		else:
			button.text = "%d\n-" % (i + 1)
			button.disabled = true
		hotbar.add_child(button)


func _use_hotbar(index: int) -> void:
	if not _hotbar_assignments.has(index):
		return
	var item_name := str(_hotbar_assignments[index])
	if GameState.count_item(item_name) <= 0:
		_hotbar_assignments.erase(index)
		_rebuild_hotbar()
		return
	GameState.use_item(item_name)
	if GameState.count_item(item_name) <= 0:
		_hotbar_assignments.erase(index)
		_rebuild_hotbar()


## Builds activation buttons for every learned skill that has a mana cost.
## Passive skills (mana_cost == 0) are skipped since they need no button.
func _rebuild_skill_bar() -> void:
	if skill_bar == null:
		return
	_clear(skill_bar)
	_skill_buttons.clear()

	for sdata in GameData.skill_list():
		var sname: String = str(sdata.get("name", ""))
		if sname == "":
			continue
		var cur_lvl := int(GameState.skills.get(sname, 0))
		if cur_lvl <= 0:
			continue
		# Only show skills matching the player's class (plus General skills
		# available to everyone). A Mage should not see Archer's Triple Shot.
		var sclass: String = GameData.skill_class(sname)
		if sclass != "General" and sclass != GameState.player_class:
			continue
		var mana_cost := int(sdata.get("mana_cost", 0))
		var cooldown := float(sdata.get("cooldown", 0))
		if cooldown <= 0.0:
			continue

		var key := _skill_key(sname)
		var btn := _make_button("%s  [%s]  Lv%d" % [sname, key, cur_lvl], Vector2(140, 44))
		btn.add_theme_font_size_override("font_size", 11)
		btn.theme_type_variation = "SlotButton"
		btn.tooltip_text = "Key: %s   Cost: %d MP" % [key, mana_cost]
		btn.pressed.connect(_activate_skill.bind(sname))
		skill_bar.add_child(btn)
		_skill_buttons[sname] = btn


## Activates the given skill through GameState, then refreshes button states.
func _activate_skill(skill_name: String) -> void:
	# Check if the skill is already active (duration-based skills like Rage, Block).
	var active := GameState.get_active_skills()
	if active.has(skill_name):
		GameState.message.emit("%s is active!" % skill_name)
		return
	# Check cooldown.
	var remaining := float(GameState.skill_cooldowns.get(skill_name, 0))
	if remaining > 0.0:
		GameState.message.emit("%s on cooldown (%.1fs)" % [skill_name, remaining])
		return
	if GameState.activate_skill(skill_name):
		_rebuild_skill_bar()
		# Refresh skills panel status so the new cooldown shows immediately if open.
		if skills_panel != null and skills_panel.visible:
			_refresh_skill_status()
		if skill_name == "Self Rage" or skill_name == "Guild Rage":
			var lvl := int(GameState.skills.get(skill_name, 0))
			GameState.set_active_skill(skill_name, float(lvl))
			if player != null and is_instance_valid(player):
				player.active_rage_skill = skill_name
	else:
		var sdata := GameData.skill(skill_name)
		var cost := int(sdata.get("mana_cost", 0))
		if GameState.current_mp < cost:
			GameState.message.emit("Not enough MP for %s (need %d)" % [skill_name, cost])


## Returns the key/text the player presses to activate a skill. Empty string
## for skills with no single-key bind (e.g. double-tap dash, space+direction).
func _skill_key(sname: String) -> String:
	match sname:
		"Self Rage":
			return "R"
		"Guild Rage":
			return "Y"
		"Block":
			return "V"
		"Circular Magic Attack":
			return "B"
		"Light Beam":
			return "L"
		"Grenade Attack":
			return "F"
		"Charged Arrow Barrage":
			return "C"
		"Thunder Attack":
			return "M"
		"Self Heal":
			return "H"
		"Guild/Pet Heal":
			return "G"
		"Shotgun Attack":
			return "N"
		"Power Attack":
			return "P"
		"Speed Dash":
			return "→→ (dash)"
		"Downward Acceleration":
			return "↓ (air)"
		"Triple Shot Attack":
			return "↓ + Space"
		"Arrow Rain Attack":
			return "↑ + Space"
		"Piercing Arrow Attack":
			return "→ + Space"
		"Down Crush":
			return "↓ + Space (air)"
		"Air Power Slash":
			return "↓ + Space (air)"
		"Multi-Attack":
			return "↓ + Space"
		"Spinning Cutter":
			return "↑ + Space"
		"Upward Shoot":
			return "↑ + Space"
		"Jump Grenade":
			return "↓ + Space (air)"
		_:
			return ""  # passive skills or no direct key bind


func _item_tooltip(data: Dictionary) -> String:
	if data.is_empty():
		return ""
	var lines: Array[String] = []
	lines.append("%s" % str(data.get("name", "")))
	var type_text := str(data.get("type", "")).replace("_", " ").capitalize()
	lines.append("%s   Lv %d" % [type_text, int(data.get("level", 1))])
	if int(data.get("damage_max", 0)) > 0:
		lines.append("Damage: %d - %d" % [int(data.get("damage_min", 0)), int(data.get("damage_max", 0))])
	if float(data.get("reach", 0)) > 0:
		lines.append("Reach: %.1f" % float(data.get("reach", 0)))
	if int(data.get("defense", 0)) != 0:
		lines.append("Defense: +%d" % int(data.get("defense", 0)))
	if int(data.get("power", 0)) != 0:
		lines.append("Power: +%d" % int(data.get("power", 0)))
	if int(data.get("magic", 0)) != 0:
		lines.append("Magic: +%d" % int(data.get("magic", 0)))
	if int(data.get("range", 0)) != 0:
		lines.append("Range: +%d" % int(data.get("range", 0)))
	if int(data.get("luck", 0)) != 0:
		lines.append("Luck: +%d" % int(data.get("luck", 0)))
	if int(data.get("strength", 0)) != 0:
		lines.append("Strength: +%d" % int(data.get("strength", 0)))
	if str(data.get("effect", "")) != "":
		lines.append(str(data.get("effect", "")))
	if int(data.get("price", 0)) > 0:
		lines.append("Shop price: %s" % GameState.format_number(int(data.get("price", 0))))
	var sell := GameState.sell_price(str(data.get("name", "")))
	if sell > 0:
		lines.append("Sells for: %s" % GameState.format_number(sell))
	return "\n".join(lines)


func _rebuild_inventory() -> void:
	_clear(inventory_grid)
	_clear(equipment_box)
	_close_item_context()

	# Keep locked items at the top of the backpack (preserving relative order
	# within locked and unlocked groups) so they don't sink below new items.
	var locked: Array = []
	var unlocked: Array = []
	for entry in GameState.inventory:
		if bool(entry.get("locked", false)):
			locked.append(entry)
		else:
			unlocked.append(entry)
	GameState.inventory = locked + unlocked

	for slot in GameState.EQUIPMENT_SLOTS:
		var item_name := str(GameState.equipment.get(slot, ""))
		var display_name := item_name
		if item_name != "":
			var eq_data := GameData.item(item_name)
			var eq_lvl := int(eq_data.get("level", 0))
			if eq_lvl > 0:
				display_name += " [Lv %d]" % eq_lvl
		var text := "%s: %s" % [slot.replace("_", " ").capitalize(), (display_name if item_name != "" else "empty")]
		var button := _make_button(text, Vector2(260, 34))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", 13)
		# No tooltip on hover. Left-click compares, right-click opens menu.
		if item_name != "":
			button.set_meta("item_name", item_name)
			button.set_meta("slot", slot)
			button.gui_input.connect(func(event: InputEvent) -> void:
				if event is InputEventMouseButton and event.pressed:
					if event.button_index == MOUSE_BUTTON_LEFT:
						# Mobile has no right-click: a tap opens the existing
						# action menu (which also refreshes the comparison).
						if _is_mobile_platform():
							_on_equipped_item_right_clicked(slot, item_name)
						else:
							_on_equipped_item_left_clicked(slot, item_name)
					elif event.button_index == MOUSE_BUTTON_RIGHT:
						_on_equipped_item_right_clicked(slot, item_name)
			)
		else:
			button.disabled = true
		equipment_box.add_child(button)

	var inv_index := 0
	for entry in GameState.inventory:
		var item_name := str(entry["name"])
		var qty := int(entry["qty"])
		var data := GameData.item(item_name)
		var item_lvl := int(data.get("level", 0))
		var label_text := item_name
		if item_lvl > 0:
			label_text += " Lv%d" % item_lvl
		if qty > 1:
			label_text += " x%d" % qty
		if bool(entry.get("locked", false)):
			label_text += " 🔒"
		var button := _make_button(label_text, Vector2(150, 48))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.clip_text = false
		button.add_theme_font_size_override("font_size", 13)
		# No tooltip on hover. Left-click compares, right-click opens menu.
		button.set_meta("item_name", item_name)
		button.set_meta("inv_index", inv_index)
		button.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed:
				if event.button_index == MOUSE_BUTTON_LEFT:
					# Mobile has no right-click: a tap opens the existing
					# action menu (which also refreshes the comparison).
					if _is_mobile_platform():
						_on_inventory_item_right_clicked(item_name, inv_index)
					else:
						_on_inventory_item_left_clicked(item_name, inv_index)
				elif event.button_index == MOUSE_BUTTON_RIGHT:
					_on_inventory_item_right_clicked(item_name, inv_index)
		)
		inventory_grid.add_child(button)
		inv_index += 1

	_apply_selection_highlight()
	_refresh_stats()
	if _compare_label != null:
		if _is_mobile_platform():
			_compare_label.text = "Tap an item to compare stats\nand open the Equip / Use / Drop menu."
		else:
			_compare_label.text = "Left-click an item to compare stats.\nRight-click for Equip / Unequip / Drop menu."



## Left-click on a backpack item: compares stats without opening menu.
func _on_inventory_item_left_clicked(item_name: String, inv_index: int) -> void:
	_selected_item = item_name
	_selected_inv_index = inv_index
	_selected_slot = ""
	_apply_selection_highlight()
	_close_item_context()
	_show_compare_stats(item_name)


## Right-click on a backpack item: opens menu at fixed location and compares stats.
func _on_inventory_item_right_clicked(item_name: String, inv_index: int) -> void:
	_selected_item = item_name
	_selected_inv_index = inv_index
	_selected_slot = ""
	_apply_selection_highlight()
	_show_item_context(item_name)
	_show_compare_stats(item_name)


## Left-click on an equipped item: compares stats without opening menu.
func _on_equipped_item_left_clicked(slot: String, item_name: String) -> void:
	_selected_item = item_name
	_selected_inv_index = -1
	_selected_slot = slot
	_apply_selection_highlight()
	_close_item_context()
	_show_compare_stats(item_name)


## Right-click on an equipped item: opens menu at fixed location and compares stats.
func _on_equipped_item_right_clicked(slot: String, item_name: String) -> void:
	_selected_item = item_name
	_selected_inv_index = -1
	_selected_slot = slot
	_apply_selection_highlight()
	_show_item_context(item_name)
	_show_compare_stats(item_name)


## Builds and displays the context popup in ONE fixed location.
func _show_item_context(item_name: String) -> void:
	if _item_context_popup == null:
		return
	_context_item = item_name
	var data := GameData.item(item_name)
	var slot := str(data.get("slot", "none"))
	var is_equippable := GameState.EQUIPMENT_SLOTS.has(slot)
	var is_equipped := false
	for s in GameState.EQUIPMENT_SLOTS:
		if str(GameState.equipment.get(s, "")) == item_name:
			is_equipped = true
			break
	var is_consumable := slot == "consumable"

	var popup_box := _item_context_popup.get_node("VBoxContainer")
	if popup_box.has_node("ItemTitle"):
		var title_lbl: Label = popup_box.get_node("ItemTitle")
		title_lbl.text = item_name

	var equip_btn: Button = popup_box.get_node("Equip")
	equip_btn.visible = is_equippable and not is_equipped

	var unequip_btn: Button = popup_box.get_node("Unequip")
	unequip_btn.visible = is_equipped

	var use_btn: Button = popup_box.get_node("Use")
	use_btn.visible = is_consumable

	var drop_btn: Button = popup_box.get_node("Drop")
	drop_btn.visible = true

	var lock_btn: Button = popup_box.get_node("Lock")
	var is_locked := false
	if _selected_inv_index >= 0 and _selected_inv_index < GameState.inventory.size():
		var entry: Dictionary = GameState.inventory[_selected_inv_index]
		if str(entry.get("name", "")) == item_name:
			is_locked = bool(entry.get("locked", false))
	lock_btn.text = "Unlock" if is_locked else "Lock"
	lock_btn.visible = _selected_inv_index >= 0

	var hotbar_box := _item_context_popup.get_node("VBoxContainer")
	for i in range(5):
		var hbtn := hotbar_box.get_node("Hotbar %d" % [i + 1])
		var already := _hotbar_assignments.has(i) and str(_hotbar_assignments[i]) == item_name
		hbtn.visible = is_consumable
		hbtn.text = "Hotbar %d%s" % [i + 1, " ✓" if already else ""]

	# Position popup at mouse cursor position (clamped within viewport)
	var mouse_pos := get_viewport().get_mouse_position()
	var vp_size := get_viewport().get_visible_rect().size
	var popup_w := 170.0
	var popup_h := 400.0
	var target_x := clampf(mouse_pos.x - 15.0, 10.0, vp_size.x - popup_w - 10.0)
	var target_y := clampf(mouse_pos.y - 15.0, 10.0, vp_size.y - popup_h - 10.0)

	_item_context_popup.anchor_left = 0.0
	_item_context_popup.anchor_right = 0.0
	_item_context_popup.anchor_top = 0.0
	_item_context_popup.anchor_bottom = 0.0
	_item_context_popup.offset_left = target_x
	_item_context_popup.offset_top = target_y
	_item_context_popup.offset_right = target_x + popup_w
	_item_context_popup.offset_bottom = target_y + popup_h
	_item_context_popup.position = Vector2(target_x, target_y)
	_item_context_popup.visible = true


## Hides and resets the context popup.
func _close_item_context() -> void:
	if _item_context_popup != null:
		_item_context_popup.visible = false
	_context_item = ""

## Applies a highlight style to exactly one inventory/equipment button: the one
## that matches _selected_item plus its unique identifier (inventory index for
## backpack items, equipment slot for equipped items). Duplicates sharing the
## same name (e.g. 4 bazookas) are NOT all highlighted — only the clicked one.
## Clears any previous highlight first so it doesn't accumulate across clicks.
func _apply_selection_highlight() -> void:
	if inventory_grid == null or equipment_box == null:
		return
	var style := _selection_style()
	for container in [inventory_grid, equipment_box]:
		for child in container.get_children():
			if not (child is Button):
				continue
			# Remove any old highlight so it doesn't accumulate across clicks
			child.remove_theme_stylebox_override("normal")
			var item_name := str(child.get_meta("item_name", ""))
			var inv_index := int(child.get_meta("inv_index", -1))
			var slot := str(child.get_meta("slot", ""))
			if item_name == "":
				continue
			var is_match := item_name == _selected_item
			if _selected_inv_index >= 0:
				is_match = is_match and inv_index == _selected_inv_index
			elif _selected_slot != "":
				is_match = is_match and slot == _selected_slot
			if is_match:
				child.add_theme_stylebox_override("normal", style)


## Builds the compare-stats text for _compare_label.
func _show_compare_stats(item_name: String) -> void:
	if _compare_label == null:
		return
	var data := GameData.item(item_name)
	if data.is_empty():
		_compare_label.text = ""
		return
	var slot := str(data.get("slot", "none"))
	if not GameState.EQUIPMENT_SLOTS.has(slot):
		# Not gear — just show item details
		_compare_label.text = _item_tooltip(data)
		return

	# Find currently equipped item in the same slot
	var equipped_name := str(GameState.equipment.get(slot, ""))
	var equipped_data := GameData.item(equipped_name) if equipped_name != "" else {}

	var stat_keys := ["defense", "power", "magic", "range", "strength", "dexterity", "luck",
					  "damage_min", "damage_max", "reach", "health"]
	var lines: Array[String] = []

	if item_name == equipped_name:
		lines.append("[%s]  (Equipped)" % item_name)
		lines.append("Lv %d   %s" % [int(data.get("level", 1)), str(data.get("type", "")).capitalize()])
		lines.append("")
		for key in stat_keys:
			var val := float(data.get(key, 0))
			if val == 0.0:
				continue
			lines.append("%s: %.0f" % [key.replace("_", " ").capitalize(), val])
	else:
		if equipped_name != "":
			lines.append("[%s]  vs.  [%s]" % [item_name, equipped_name])
		else:
			lines.append("[%s]  (slot is empty)" % item_name)
		lines.append("Lv %d   %s" % [int(data.get("level", 1)), str(data.get("type", "")).capitalize()])
		lines.append("")

		for key in stat_keys:
			var new_val := float(data.get(key, 0))
			var old_val := float(equipped_data.get(key, 0)) if not equipped_data.is_empty() else 0.0
			if new_val == 0.0 and old_val == 0.0:
				continue
			var diff := new_val - old_val
			var diff_str := ""
			if diff > 0.0:
				diff_str = "  [+%.0f]" % diff
			elif diff < 0.0:
				diff_str = "  [%.0f]" % diff
			else:
				diff_str = "  [=]"
			if equipped_name != "":
				lines.append("%s: %.0f vs %.0f%s" % [key.replace("_", " ").capitalize(), new_val, old_val, diff_str])
			else:
				lines.append("%s: %.0f%s" % [key.replace("_", " ").capitalize(), new_val, diff_str])

	if str(data.get("effect", "")) != "":
		lines.append("")
		lines.append(str(data.get("effect", "")))

	_compare_label.text = "\n".join(lines)


# --- Context popup actions ---

func _context_equip() -> void:
	if _context_item != "":
		GameState.equip(_context_item)
	_close_item_context()
	_rebuild_inventory()


func _context_unequip() -> void:
	if _context_item == "":
		return
	var data := GameData.item(_context_item)
	var slot := str(data.get("slot", "none"))
	# May be called from either backpack or equipped column
	if str(GameState.equipment.get(slot, "")) == _context_item:
		GameState.unequip(slot)
	_close_item_context()
	_rebuild_inventory()


func _context_use() -> void:
	if _context_item != "":
		GameState.use_item(_context_item)
	_close_item_context()
	_rebuild_inventory()


func _context_drop() -> void:
	if _context_item == "":
		return
	var item := _context_item
	if GameState.drop_item(item):
		# Spawn the dropped item in the world at the player's feet
		var s := get_tree().get_first_node_in_group("stage")
		if s != null and s.has_method("spawn_item_drop"):
			s.spawn_item_drop(item, 1)
		_remove_from_hotbar(item)
	_close_item_context()
	_rebuild_inventory()


func _context_lock() -> void:
	if _context_item == "" or _selected_inv_index < 0:
		return
	if _selected_inv_index >= GameState.inventory.size():
		return
	var entry: Dictionary = GameState.inventory[_selected_inv_index]
	if str(entry.get("name", "")) != _context_item:
		return
	entry["locked"] = not bool(entry.get("locked", false))
	if bool(entry.get("locked", false)):
		_remove_from_hotbar(_context_item)
	GameState.inventory_changed.emit()
	_close_item_context()
	_rebuild_inventory()


## Removes an item from every hotbar slot it is assigned to.
func _remove_from_hotbar(item_name: String) -> void:
	var changed := false
	for i in range(5):
		if _hotbar_assignments.has(i) and str(_hotbar_assignments[i]) == item_name:
			_hotbar_assignments.erase(i)
			changed = true
	if changed:
		_rebuild_hotbar()


func _context_hotbar(slot_index: int) -> void:
	if _context_item == "":
		return
	var data := GameData.item(_context_item)
	if str(data.get("slot", "")) != "consumable":
		GameState.message.emit("Only consumables can be assigned to the hotbar.")
		return
	_hotbar_assignments[slot_index] = _context_item
	_close_item_context()
	_rebuild_inventory()
	_rebuild_hotbar()
	show_toast("Assigned %s to hotbar %d" % [_context_item, slot_index + 1])


## Opens the sort menu near the mouse cursor so the player can pick a sort
## criterion for the backpack.
func _open_sort_menu() -> void:
	if _sort_popup == null:
		return
	var mouse_pos := get_viewport().get_mouse_position()
	var vp_size := get_viewport().get_visible_rect().size
	var popup_w := 170.0
	var popup_h := 160.0
	var target_x := clampf(mouse_pos.x - 15.0, 10.0, vp_size.x - popup_w - 10.0)
	var target_y := clampf(mouse_pos.y - 15.0, 10.0, vp_size.y - popup_h - 10.0)
	_sort_popup.anchor_left = 0.0
	_sort_popup.anchor_right = 0.0
	_sort_popup.anchor_top = 0.0
	_sort_popup.anchor_bottom = 0.0
	_sort_popup.offset_left = target_x
	_sort_popup.offset_top = target_y
	_sort_popup.offset_right = target_x + popup_w
	_sort_popup.offset_bottom = target_y + popup_h
	_sort_popup.position = Vector2(target_x, target_y)
	# Give the popup an explicit size so its hit rect matches the positioned
	# rect; otherwise clicks on its buttons can be read as "outside" and close
	# the menu before the button press fires.
	_sort_popup.custom_minimum_size = Vector2(popup_w, popup_h)
	_sort_popup_rect = Rect2(target_x, target_y, popup_w, popup_h)
	# Shop items have no quantity, so hide the quantity sort criterion there.
	if _qty_sort_button != null:
		_qty_sort_button.visible = not (shop_panel != null and shop_panel.visible)
	_sort_popup.visible = true


## Sorts the backpack by the given criterion while keeping locked items at
## the top. Locked items keep their relative order; unlocked items are sorted.
## Criteria: "name", "level_asc", "level_desc", "qty_desc".
func _sort_inventory(by: String) -> void:
	var locked: Array = []
	var unlocked: Array = []
	for entry in GameState.inventory:
		if bool(entry.get("locked", false)):
			locked.append(entry.duplicate())
		else:
			unlocked.append(entry.duplicate())
	match by:
		"name":
			unlocked.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
		"level_asc":
			unlocked.sort_custom(func(a, b):
				var la := int(GameData.item(str(a["name"])).get("level", 0))
				var lb := int(GameData.item(str(b["name"])).get("level", 0))
				if la != lb:
					return la < lb
				return str(a["name"]) < str(b["name"])
			)
		"level_desc":
			unlocked.sort_custom(func(a, b):
				var la := int(GameData.item(str(a["name"])).get("level", 0))
				var lb := int(GameData.item(str(b["name"])).get("level", 0))
				if la != lb:
					return la > lb
				return str(a["name"]) < str(b["name"])
			)
		"qty_desc":
			unlocked.sort_custom(func(a, b): return int(a["qty"]) > int(b["qty"]))
		_:
			unlocked.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	GameState.inventory = locked + unlocked
	GameState.inventory_changed.emit()


## Sorts the backpack by the given criterion (called from the sort popup).
func _on_sort_criterion_selected(by: String) -> void:
	_sort_inventory(by)


func _unequip_slot(slot: String) -> void:
	GameState.unequip(slot)
	_rebuild_inventory()


# ---------------------------------------------------------------------------
# Shop
# ---------------------------------------------------------------------------
func open_shop(npc_name: String) -> void:
	shop_npc = npc_name
	shop_mode = "buy"
	shop_category = ""
	if _shop_buy_tab != null:
		_shop_buy_tab.button_pressed = true
	shop_title.text = "%s's Shop" % npc_name
	_rebuild_shop()
	_open_panel(shop_panel)


func _set_shop_mode(mode: String) -> void:
	shop_mode = mode
	shop_category = ""
	_rebuild_shop()


## Selects a shop buy category. Empty string means "All" (no filter).
func _set_shop_category(slot: String) -> void:
	shop_category = slot
	_rebuild_shop()


## Returns the item slot types this shop actually sells (buy mode only).
func _shop_sold_slots() -> Array:
	var slots: Array = []
	for item_name in GameData.items_for_shop(shop_npc):
		var data := GameData.item(item_name)
		var slot := str(data.get("slot", ""))
		if slot != "" and not slots.has(slot):
			slots.append(slot)
	return slots


## Builds a compact stats string for an item shown in the shop (buy mode).
func _shop_item_stats(data: Dictionary) -> String:
	if data.is_empty():
		return ""
	var parts: Array[String] = []
	var dmg_min := int(data.get("damage_min", 0))
	var dmg_max := int(data.get("damage_max", 0))
	if dmg_max > 0:
		parts.append("Dmg %d-%d" % [dmg_min, dmg_max])
	var reach := float(data.get("reach", 0))
	if reach > 0:
		parts.append("Reach %.1f" % reach)
	var defense := int(data.get("defense", 0))
	if defense != 0:
		parts.append("Def +%d" % defense)
	var power := int(data.get("power", 0))
	if power != 0:
		parts.append("Pow +%d" % power)
	var magic := int(data.get("magic", 0))
	if magic != 0:
		parts.append("Mag +%d" % magic)
	var range_v := int(data.get("range", 0))
	if range_v != 0:
		parts.append("Rng +%d" % range_v)
	var luck := int(data.get("luck", 0))
	if luck != 0:
		parts.append("Lck +%d" % luck)
	var strength := int(data.get("strength", 0))
	if strength != 0:
		parts.append("Str +%d" % strength)
	return "   ".join(parts)


func _rebuild_shop() -> void:
	_clear(shop_list)
	_clear(shop_category_tabs)
	if shop_gold_label != null:
		shop_gold_label.text = "%s gold" % GameState.format_number(GameState.gold)

	var names: Array = []
	if shop_mode == "buy":
		names = GameData.items_for_shop(shop_npc)

		# Category tabs: only show types this shop actually sells.
		var all_btn := _make_button("All", Vector2(60, 32))
		all_btn.theme_type_variation = "TabButton"
		all_btn.toggle_mode = true
		all_btn.button_pressed = (shop_category == "")
		all_btn.pressed.connect(_set_shop_category.bind(""))
		shop_category_tabs.add_child(all_btn)
		var sold_slots := _shop_sold_slots()
		for cat in SHOP_CATEGORIES:
			var slot := str(cat["slot"])
			if not sold_slots.has(slot):
				continue
			var btn := _make_button(str(cat["label"]), Vector2(70, 32))
			btn.theme_type_variation = "TabButton"
			btn.toggle_mode = true
			btn.button_pressed = (shop_category == slot)
			btn.pressed.connect(_set_shop_category.bind(slot))
			shop_category_tabs.add_child(btn)

		if shop_category != "":
			var filtered: Array = []
			for name in names:
				var data := GameData.item(name)
				if str(data.get("slot", "")) == shop_category:
					filtered.append(name)
			names = filtered
	for entry in GameState.inventory:
			names.append(str(entry["name"]))

	if names.is_empty():
		shop_list.add_child(_make_label("Nothing here yet.", 15, Color(0.8, 0.85, 0.8)))
		return

	for item_name in names:
		var data := GameData.item(item_name)
		if data.is_empty():
			continue
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _box(Color(0.05, 0.05, 0.07, 0.55), Color(0.18, 0.16, 0.16), 1, 10, Vector2(12, 8)))
		shop_list.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		card.add_child(row)

		var info := _make_label("%s   (Lv %d)" % [item_name, int(data.get("level", 1))], 14)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.tooltip_text = _item_tooltip(data)
		row.add_child(info)

		if shop_mode == "buy":
			var stats_text := _shop_item_stats(data)
			if stats_text != "":
				var stats_label := _make_label(stats_text, 12, Color(0.85, 0.9, 1.0))
				stats_label.custom_minimum_size = Vector2(150, 0)
				row.add_child(stats_label)

		var price := int(data.get("price", 0)) if shop_mode == "buy" else GameState.sell_price(item_name)
		var price_label := _make_label("%s g" % GameState.format_number(price), 14, Color(0.98, 0.85, 0.35))
		price_label.custom_minimum_size = Vector2(90, 0)
		row.add_child(price_label)

		if shop_mode == "buy":
			var action := _make_button("Buy", Vector2(80, 30))
			action.theme_type_variation = "PrimaryButton"
			action.disabled = GameState.gold < price
			action.pressed.connect(_buy_item.bind(item_name))
			row.add_child(action)
		else:
			var btn_box := HBoxContainer.new()
			btn_box.add_theme_constant_override("separation", 4)
			var sell1 := _make_button("Sell 1x", Vector2(70, 30))
			sell1.pressed.connect(_sell_item.bind(item_name, 1))
			btn_box.add_child(sell1)
			var sell_qty := GameState.count_item(item_name)
			if sell_qty > 10:
				var sell10 := _make_button("Sell 10x", Vector2(70, 30))
				sell10.pressed.connect(_sell_item.bind(item_name, 10))
				btn_box.add_child(sell10)
			var sellall := _make_button("Sell %dx" % [sell_qty], Vector2(70, 30))
			sellall.pressed.connect(_sell_item.bind(item_name, sell_qty))
			btn_box.add_child(sellall)
			row.add_child(btn_box)


func _buy_item(item_name: String) -> void:
	GameState.buy(item_name)
	_rebuild_shop()
	_refresh_inventory()


func _sell_item(item_name: String, qty: int = 1) -> void:
	GameState.sell(item_name, qty)
	_rebuild_shop()
	_refresh_inventory()


# ---------------------------------------------------------------------------
# Dialogue, death, stage select
# ---------------------------------------------------------------------------
func show_dialogue(npc_name: String, text: String) -> void:
	dialogue_name_label.text = npc_name
	dialogue_text_label.text = text if text.strip_edges() != "" else "Hello there, adventurer."
	_open_panel(dialogue_panel)


func show_death(lost_gold: int) -> void:
	death_label.text = "You dropped %s gold. Respawning restores your health." % GameState.format_number(lost_gold)
	death_panel.visible = true
	_set_paused(true)


func _on_respawn_pressed() -> void:
	death_panel.visible = false
	_set_paused(false)
	if stage != null:
		stage.respawn_player()


func _open_stage_panel() -> void:
	_clear(stage_list)
	var unlocked := GameState.unlocked_stage
	var stages := []
	for stage_data in GameData.stage_list():
		var number := int(stage_data.get("number", 0))
		if number <= 0 or number > unlocked:
			continue
		stages.append({"number": number, "name": str(stage_data.get("name", "?"))})
	stages.sort_custom(func(a, b):
		return a["number"] < b["number"]
	)
	for s in stages:
		var button := _make_button("#%d   %s" % [s["number"], s["name"]], Vector2(140, 30))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", 12)
		if s["number"] == GameState.current_stage:
			button.theme_type_variation = "PrimaryButton"
		button.pressed.connect(_travel_to.bind(s["number"]))
		stage_list.add_child(button)
	_open_panel(stage_panel)


func _travel_to(number: int) -> void:
	_close_panels()
	if stage != null:
		stage.go_to_stage(number)


func _go_to_menu() -> void:
	_set_paused(false)
	GameState.save_game()
	GameState.flush_cloud_save()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


# ---------------------------------------------------------------------------
# Panels / input / toasts
# ---------------------------------------------------------------------------
func _open_panel(panel: PanelContainer) -> void:
	for other in [inventory_panel, shop_panel, pause_panel, stage_panel, dialogue_panel, character_panel, skills_panel, monsterpedia_panel, settings_panel]:
		if other != null and other != panel:
			other.visible = false
	panel.visible = true
	_set_paused(true)


func _close_panels() -> void:
	for panel in [inventory_panel, shop_panel, pause_panel, stage_panel, dialogue_panel, character_panel, skills_panel, monsterpedia_panel, settings_panel]:
		if panel != null:
			panel.visible = false
	_close_item_context()
	_selected_item = ""
	_set_paused(false)


func _set_paused(value: bool) -> void:
	# Menus open over the game but do not stop it — the world keeps running
	# (monsters, timers, movement) while a panel is visible.
	paused = value
	_sync_touch_controls()


## Hides the virtual controls while a blocking panel (or the death screen) is
## open so they don't overlap menus or keep driving the player. Shows them
## again as soon as gameplay is unobstructed.
func _sync_touch_controls() -> void:
	if _touch_controls == null or not is_instance_valid(_touch_controls):
		return
	var blocked := _any_panel_visible() or (death_panel != null and death_panel.visible)
	_touch_controls.visible = not blocked


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Clicking anywhere outside a popup dismisses it.
		if _item_context_popup != null and _item_context_popup.visible:
			if not _item_context_popup.get_global_rect().has_point(event.position):
				_close_item_context()
		if _sort_popup != null and _sort_popup.visible:
			if not _sort_popup.get_global_rect().has_point(event.position):
				_sort_popup.visible = false


func _unhandled_input(event: InputEvent) -> void:
	# Ignore gameplay hotkeys if typing in chat or another input field
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			focus_owner.release_focus()
			get_viewport().set_input_as_handled()
		return

	# Chat hotkeys: Enter or / to open/focus chat
	if event is InputEventKey and event.pressed and not event.echo and not paused:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if chat_box != null and is_instance_valid(chat_box):
				chat_box.focus_chat_input()
				get_viewport().set_input_as_handled()
				return
		elif event.keycode == KEY_SLASH:
			if chat_box != null and is_instance_valid(chat_box):
				chat_box.focus_chat_input("/")
				get_viewport().set_input_as_handled()
				return

	if event.is_action_pressed("pause"):
		if death_panel.visible:
			return
		_toggle_pause_panel()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("inventory"):
		if death_panel.visible:
			return
		if inventory_panel.visible:
			_close_panels()
		else:
			_rebuild_inventory()
			_open_panel(inventory_panel)
		get_viewport().set_input_as_handled()
		return

	if paused:
		return

	for i in range(5):
		if event.is_action_pressed("use_%d" % (i + 1)):
			_use_hotbar(i)
			get_viewport().set_input_as_handled()
			return

	# --- Single-key skill activation: press the skill's key to use it ---
	if event is InputEventKey and event.pressed and not event.echo and not paused:
		var skill_name := ""
		match event.keycode:
			KEY_B:
				skill_name = "Circular Magic Attack"
			KEY_C:
				skill_name = "Charged Arrow Barrage"
			KEY_F:
				skill_name = "Grenade Attack"
			KEY_H:
				skill_name = "Self Heal"
			KEY_G:
				skill_name = "Guild/Pet Heal"
			KEY_L:
				skill_name = "Light Beam"
			KEY_M:
				skill_name = "Thunder Attack"
			KEY_N:
				skill_name = "Shotgun Attack"
			KEY_P:
				skill_name = "Power Attack"
			KEY_Y:
				skill_name = "Guild Rage"
			KEY_V:
				pass  # Block is a toggle hold, handled in Player
			KEY_R:
				pass  # Rage is handled in Player
		if skill_name != "":
			if GameState.can_activate_skill(skill_name):
				_activate_skill(skill_name)
			else:
				var remaining := float(GameState.skill_cooldowns.get(skill_name, 0))
				if remaining > 0.0:
					GameState.message.emit("%s on cooldown (%.1fs)" % [skill_name, remaining])
				else:
					GameState.message.emit("%s is not ready." % skill_name)
			get_viewport().set_input_as_handled()


func _any_panel_visible() -> bool:
	return inventory_panel.visible or shop_panel.visible or pause_panel.visible \
		or stage_panel.visible or dialogue_panel.visible \
		or character_panel.visible or skills_panel.visible \
		or monsterpedia_panel.visible or settings_panel.visible


func show_toast(text: String) -> void:
	if toast_box == null:
		return
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _chip_style())
	pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := _make_label(text, 15, Color(1.0, 0.92, 0.8))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pill.add_child(label)
	toast_box.add_child(pill)
	var tween := create_tween()
	tween.tween_interval(2.2)
	tween.tween_property(pill, "modulate:a", 0.0, 0.5)
	tween.tween_callback(pill.queue_free)


# ---------------------------------------------------------------------------
# Character panel
# ---------------------------------------------------------------------------
func _toggle_character_panel() -> void:
	if character_panel.visible:
		_close_panels()
	else:
		_rebuild_character_panel()
		_open_panel(character_panel)


func _rebuild_character_panel() -> void:
	_clear(char_stats_box)
	if char_help_panel != null:
		char_help_panel.visible = false
	var s := GameState.stats()
	ability_points_label.text = "Stat Points: %d   |   Skill Points: %d" % [GameState.skill_points, GameState.special_skill_points]

	# Class row
	var class_row := HBoxContainer.new()
	class_row.add_theme_constant_override("separation", 10)
	char_stats_box.add_child(class_row)
	var class_lbl := _make_label("Class: %s" % GameState.player_class, 16, Color(1.0, 0.88, 0.45))
	class_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	class_row.add_child(class_lbl)
	var switch_class_btn := _make_button("Switch Class", Vector2(120, 28))
	switch_class_btn.add_theme_font_size_override("font_size", 12)
	switch_class_btn.pressed.connect(_cycle_class)
	class_row.add_child(switch_class_btn)

	# Top info
	var info := _make_label("Level: %d          HP: %d/%d          MP: %d/%d" % [
		GameState.level, GameState.current_hp, int(s["max_hp"]),
		GameState.current_mp, int(s["max_mp"])], 15)
	char_stats_box.add_child(info)

	char_stats_box.add_child(HSeparator.new())

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 24)
	char_stats_box.add_child(cols)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	cols.add_child(left)
	cols.add_child(VSeparator.new())
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	cols.add_child(right)
	left.add_child(_make_label("COMBAT", 13, Color(0.65, 0.65, 0.7)))
	right.add_child(_make_label("ATTRIBUTES", 13, Color(0.65, 0.65, 0.7)))

	# ---- Final stats (include equipment + skill bonuses) ----
	_stat_row(left, "Damage", "%.0f - %.0f" % [s["damage_min"], s["damage_max"]],
		"Damage dealt per melee swing. A random value between min and max.\nIncreased by your equipped weapon and by your stats (Power/Strength for melee, Range/Dexterity for ranged, Magic for magic, Artillery for artillery).\nAlso multiplied by the Power Attack skill.")
	_stat_row(left, "Defense", "%.0f" % s["defense"],
		"Reduces incoming physical damage. Higher defense means you take less damage from each hit.\nBased on your Defense attribute and equipped armor / shield (Shield Mastery skill boosts shield defense).")
	_stat_row(left, "Crit Rate", "%.1f%%" % (s["crit_chance"] * 100.0),
		"Chance to deal a critical hit on each attack.\nBase 5%, increased by your Luck and Dexterity attributes.")
	_stat_row(left, "Crit Damage", "x%.2f" % s["crit_mult"],
		"Multiplier applied to damage when a critical hit lands.\nBase 1.75x, increased by the Increased Critical Damage skill.")
	_stat_row(left, "Speed", "%.0f px/s" % s.get("speed", 230.0),
		"Movement speed in pixels per second.\nBased on your Dexterity, equipment speed bonus, and the Speed Dash skill.")
	_stat_row(left, "HP", "%d / %d" % [GameState.current_hp, int(s["max_hp"])],
		"Your health points. Reaching 0 HP defeats you.\nBased on your Level, bonus HP, and equipment health.")
	_stat_row(left, "MP", "%d / %d" % [GameState.current_mp, int(s["max_mp"])],
		"Your mana points, used by some skills.\nBased on your Level, bonus MP, and equipment mana.")
	_stat_row(left, "Attack Speed", "%.0f RPM" % s.get("rpm", 0.0),
		"Attacks per minute. Determines the cooldown between swings.\nSet by your equipped weapon (0 uses the default melee swing rate).")
	_stat_row(left, "Range", "%.1f" % s.get("range", 1.0),
		"Your Range attribute. Increases damage with ranged weapons and contributes to attack reach for some weapon types.")
	_stat_row(left, "Drop Rate", "%.1f%%" % (float(s.get("luck", 1)) * 0.1),
		"Chance for defeated monsters to drop items.\nDerived from your Luck attribute (each point adds 0.1% drop rate).")

	# Allocatable base attributes
	var stat_names := ["strength", "power", "dexterity", "defense", "magic", "artillery", "range", "luck"]
	var stat_labels := ["Strength", "Power", "Dexterity", "Defense", "Magic", "Artillery", "Range", "Luck"]
	for i in range(stat_names.size()):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		right.add_child(row)

		var name_lbl := _make_label(stat_labels[i], 15, Color(0.9, 0.95, 0.85))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)

		var base_val := int(GameState.attributes.get(stat_names[i], 1))
		var total_val := int(s.get(stat_names[i], base_val))
		var val_text := str(total_val)
		if total_val != base_val:
			val_text = "%d (%d%+d)" % [total_val, base_val, total_val - base_val]

		var val_lbl := _make_label(val_text, 15, Color(1.0, 1.0, 0.8))
		val_lbl.custom_minimum_size = Vector2(80, 0)
		val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(val_lbl)

		var help_btn := Button.new()
		help_btn.text = "?"
		help_btn.custom_minimum_size = Vector2(24, 24)
		help_btn.add_theme_font_size_override("font_size", 13)
		help_btn.tooltip_text = _stat_help_text(stat_labels[i])
		help_btn.pressed.connect(_show_char_help.bind(_stat_help_text(stat_labels[i])))
		help_btn.mouse_filter = Control.MOUSE_FILTER_STOP
		row.add_child(help_btn)

		var plus_btn := _make_button("+", Vector2(32, 28))
		plus_btn.add_theme_font_size_override("font_size", 14)
		plus_btn.theme_type_variation = "PrimaryButton"
		if GameState.skill_points > 0:
			plus_btn.pressed.connect(_allocate_stat.bind(stat_names[i]))
		else:
			plus_btn.disabled = true
		row.add_child(plus_btn)

	char_stats_box.add_child(HSeparator.new())

	# Skills button row
	var skill_footer := HBoxContainer.new()
	skill_footer.add_theme_constant_override("separation", 12)
	char_stats_box.add_child(skill_footer)

	var skills_btn := _make_button("SKILLS", Vector2(100, 32))
	skills_btn.add_theme_font_size_override("font_size", 14)
	skills_btn.pressed.connect(_open_skills_panel)
	skill_footer.add_child(skills_btn)

	var spec_points_lbl := _make_label("Skill Points: %d" % GameState.special_skill_points, 15, Color(0.4, 0.95, 0.5))
	skill_footer.add_child(spec_points_lbl)


## Builds one stat row: name | value | [? help button].
## The ? button shows a tooltip explaining what the stat does and how it's calculated.
func _stat_row(parent: VBoxContainer, name: String, value: String, help: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var name_lbl := _make_label(name, 14, Color(0.9, 0.95, 0.85))
	name_lbl.custom_minimum_size = Vector2(110, 0)
	row.add_child(name_lbl)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var val_lbl := _make_label(value, 14, Color(1.0, 1.0, 0.8))
	val_lbl.custom_minimum_size = Vector2(120, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_lbl)

	var help_btn := Button.new()
	help_btn.text = "?"
	help_btn.custom_minimum_size = Vector2(24, 24)
	help_btn.add_theme_font_size_override("font_size", 13)
	help_btn.tooltip_text = help
	help_btn.pressed.connect(_show_char_help.bind(help))
	help_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_child(help_btn)


## Shows a stat's explanation under the character stat list. Clicking the same
## "?" button again hides it. Works with mouse and touch.
func _show_char_help(text: String) -> void:
	if char_help_panel == null or char_help_label == null:
		return
	if char_help_panel.visible and char_help_label.text == text:
		char_help_panel.visible = false
		return
	char_help_label.text = text
	char_help_panel.visible = true


## Returns a short "what this stat does" description for an allocatable
## base attribute, shown on the ? button next to its + button.
func _stat_help_text(label: String) -> String:
	match label:
		"Strength":
			return "Melee damage and carrying capacity. Adds to melee damage bonus."
		"Power":
			return "Melee damage. Adds to melee damage bonus."
		"Dexterity":
			return "Movement speed, critical hit chance and attack speed."
		"Defense":
			return "Reduces incoming physical damage. Also contributes to the Defense stat."
		"Magic":
			return "Magic damage. Adds to magic damage bonus."
		"Artillery":
			return "Artillery / explosive damage. Adds to artillery damage bonus."
		"Range":
			return "Ranged damage and attack reach. Adds to ranged damage bonus."
		"Luck":
			return "Critical hit chance and drop rate from defeated monsters."
		_:
			return ""


func _cycle_class() -> void:
	var classes: Array = GameState.CLASSES
	var cur_idx := classes.find(GameState.player_class)
	var next_idx := (cur_idx + 1) % classes.size()
	GameState.set_class(classes[next_idx])
	_rebuild_character_panel()


func _allocate_stat(stat_name: String) -> void:
	if GameState.allocate_stat(stat_name):
		_rebuild_character_panel()


# ---------------------------------------------------------------------------
# Skills panel
# ---------------------------------------------------------------------------
func _toggle_skills_panel() -> void:
	if skills_panel.visible:
		_close_panels()
	else:
		_rebuild_skills_panel()
		_open_panel(skills_panel)


func _open_skills_panel() -> void:
	_rebuild_skills_panel()
	_open_panel(skills_panel)


func _set_skills_tab(tab: String) -> void:
	skills_tab = tab
	_rebuild_skills_panel()


## Returns a short "Current: ..." string for a skill based on its current level
## and the player's derived stats, or an empty string when there's no single
## numeric current value to show.
func _skill_current_value(sname: String, cur_lvl: int, stats: Dictionary) -> String:
	var cm := float(stats.get("crit_mult", 1.75))
	var avoid := float(stats.get("avoidance", 0.0))
	var jump_vel := float(stats.get("jump_velocity", -560.0))
	match sname:
		"Increased Critical Damage":
			return "Current: crit damage x%.2f" % cm
		"Avoidance":
			return "Current: dodge %.1f%%" % (avoid * 100.0)
		"Block":
			return "Current: damage reduction %d%%" % (51 + cur_lvl)
		"Speed Dash":
			return "Current: dash speed %.1fx" % (1.6 + cur_lvl * 0.1)
		"MP Restoration":
			var mp := 1
			if cur_lvl >= 1:
				mp = 2 + (cur_lvl - 1) / 2
			return "Current: %d MP / 10 sec" % mp
		"Self Rage", "Guild Rage":
			return "Current: duration %d sec" % (4 + cur_lvl)
		"Self Heal":
			return "Current: heals %d HP" % (35 + cur_lvl * 5)
		"Guild/Pet Heal":
			return "Current: heals %d HP" % (25 + cur_lvl * 5)
		"Power Attack":
			return "Current: %d%% damage" % (132 + cur_lvl * 2)
		"Down Crush":
			return "Current: %d%% damage" % (103 + cur_lvl * 3)
		"Air Power Slash":
			return "Current: %d%% damage" % (103 + cur_lvl * 3)
		"Spinning Cutter":
			return "Current: %d%% damage" % (16 + cur_lvl)
		"Jump Grenade":
			return "Current: %d%% damage" % (110 + cur_lvl * 10)
		"Charged Arrow Barrage":
			return "Current: %d arrows" % (1 + cur_lvl)
		"Arrow Rain Attack":
			return "Current: %d arrows" % (1 + cur_lvl / 4)
		"Grenade Attack":
			return "Current: %d grenades" % (1 + cur_lvl)
		"Shotgun Attack":
			return "Current: %d bullets" % (1 + cur_lvl)
		"Magic Shots":
			return "Current: %d projectiles" % (2 + cur_lvl)
		"Circular Magic Attack":
			return "Current: %d projectiles" % (1 + cur_lvl / 3)
		"Thunder Attack":
			return "Current: %d clouds" % (1 + cur_lvl / 4)
		"Multi-Attack":
			return "Current: %d enemies" % (2 + cur_lvl / 3)
		"Piercing Arrow Attack":
			return "Current: %d enemies" % (1 + cur_lvl / 2)
		"Magic Distance Increase":
			return "Current: %d ft range" % (8 + cur_lvl)
		"Bullet Distance Increase":
			return "Current: %d ft range" % (70 + cur_lvl)
		"Arrow Knockback Bonus":
			return "Current: %.2f ft knockback" % (0.3 + cur_lvl * 0.03)
		"Melee Knockback":
			return "Current: %.2f ft knockback" % (0.8 + cur_lvl * 0.03)
		"Bullet Knockback":
			return "Current: %.2f ft knockback" % (0.32 + (cur_lvl / 2) * 0.03)
		"Multi-Attack Distance":
			return "Current: %.1f ft chain" % (2.7 + cur_lvl * 0.6)
		"Triple Shot Attack":
			return "Current: %d ft" % (7 + cur_lvl / 2)
		"Increased Jump Height":
			return "Current: jump %.0f" % abs(jump_vel)
		"Downward Acceleration":
			return "Current: +%d%% down accel" % (150 + cur_lvl * 10)
		"Shield Mastery":
			return "Current: shield bonus %d%%" % (102 + cur_lvl * 2)
		"Expert Warrior":
			return "Current: +%d power" % cur_lvl
		"Expert Archer":
			return "Current: +%d range" % cur_lvl
		"Expert Wizard":
			return "Current: +%d magic" % cur_lvl
		"Expert Cowboy":
			return "Current: +%d artillery" % cur_lvl
		"Rigorous Training":
			return "Current: +%d all stats" % cur_lvl
		_:
			return ""


func _rebuild_skills_panel() -> void:
	_clear(skills_list)
	_skill_status_labels.clear()
	_skill_rows.clear()
	_active_skill_name = ""
	skills_points_label.text = "Class: %s  |  Skill Points: %d" % [GameState.player_class, GameState.special_skill_points]

	var stats := GameState.stats()
	var all_skills: Array = GameData.skill_list()
	for sdata in all_skills:
		var sname: String = str(sdata.get("name", ""))
		if sname == "":
			continue
		var sclass: String = GameData.skill_class(sname)
		var cur_lvl := int(GameState.skills.get(sname, 0))
		if skills_tab == "General" and sclass != "General":
			continue
		elif skills_tab == "Class":
			if sclass != GameState.player_class and sclass != "General":
				continue
			# Only show skills the player has already unlocked (level > 0).
			if cur_lvl <= 0:
				continue

		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _card_style())
		skills_list.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		card.add_child(row)

		var info_box := VBoxContainer.new()
		info_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_box.add_theme_constant_override("separation", 2)
		row.add_child(info_box)

		var max_lvl := str(sdata.get("max_level", "Infinite"))
		var cost := int(sdata.get("points_required", 1))

		var class_color := Color(0.85, 0.9, 0.95)
		match sclass:
			"Warrior":
				class_color = Color(1.0, 0.65, 0.45)
			"Archer":
				class_color = Color(0.65, 1.0, 0.45)
			"Mage":
				class_color = Color(0.65, 0.8, 1.0)
			"Cowboy":
				class_color = Color(1.0, 0.85, 0.45)

		var title_row := HBoxContainer.new()
		title_row.add_theme_constant_override("separation", 8)
		info_box.add_child(title_row)

		var title_lbl := _make_label("%s  [%s]" % [sname, sclass], 15, class_color)
		title_row.add_child(title_lbl)

		var lvl_lbl := _make_label("Lv %d / %s  (Cost: %d pts)" % [cur_lvl, max_lvl, cost], 13, Color(0.75, 0.85, 0.8))
		title_row.add_child(lvl_lbl)

		var desc_lbl := _make_label(str(sdata.get("description", "")), 12, Color(0.82, 0.86, 0.84))
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info_box.add_child(desc_lbl)

		var cur_val := _skill_current_value(sname, cur_lvl, stats)
		if cur_val != "":
			var cur_val_lbl := _make_label(cur_val, 12, Color(0.9, 1.0, 0.8))
			cur_val_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			info_box.add_child(cur_val_lbl)

		var mana_cost := int(sdata.get("mana_cost", 0))
		var cooldown := float(sdata.get("cooldown", 0))
		if mana_cost > 0 or cooldown > 0:
			var cost_lbl := _make_label("Mana: %d MP   Cooldown: %.1fs" % [mana_cost, cooldown], 12, Color(0.8, 0.85, 1.0))
			cost_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			info_box.add_child(cost_lbl)

		var upgrade_btn := _make_button("+ Upgrade", Vector2(110, 34))
		upgrade_btn.add_theme_font_size_override("font_size", 12)
		upgrade_btn.theme_type_variation = "PrimaryButton"
		upgrade_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var is_max := max_lvl != "Infinite" and cur_lvl >= max_lvl.to_int()
		if not is_max and GameState.special_skill_points >= cost:
			upgrade_btn.pressed.connect(_on_upgrade_skill_pressed.bind(sname))
		else:
			upgrade_btn.disabled = true
			if is_max:
				upgrade_btn.text = "MAX"
		row.add_child(upgrade_btn)

		# Status label: shows "CD: X.Xs" while on cooldown or "ACTIVE: X.Xs" while active.
		var status_lbl := _make_label("", 12, Color(0.8, 0.85, 0.8))
		status_lbl.custom_minimum_size = Vector2(120, 0)
		status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(status_lbl)
		_skill_status_labels[sname] = status_lbl
		_skill_rows[sname] = card


func _on_upgrade_skill_pressed(skill_name: String) -> void:
	if GameState.upgrade_skill(skill_name):
		_rebuild_skills_panel()


## Refreshes each skill row's cooldown/active status label while the skills
## panel is open, and highlights the single currently-active skill row.
func _refresh_skill_status() -> void:
	var active := GameState.get_active_skills()

	# Determine the single active skill to highlight (first one found).
	var active_name := ""
	for key in active.keys():
		active_name = key
		break

	if _active_skill_name != active_name:
		_clear_skill_highlight()
		_active_skill_name = active_name
		if active_name != "":
			_apply_skill_highlight(active_name)

	# Update each skill's cooldown / active label.
	for sname in _skill_status_labels.keys():
		var label: Label = _skill_status_labels[sname]
		if not is_instance_valid(label):
			continue
		var remaining_cd := float(GameState.skill_cooldowns.get(sname, 0))
		if remaining_cd > 0.0:
			label.text = "CD: %.1fs" % remaining_cd
			label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		elif active.has(sname):
			var remaining := float(active[sname])
			label.text = "ACTIVE: %.1fs" % remaining
			label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		else:
			label.text = ""
			label.add_theme_color_override("font_color", Color(0.8, 0.85, 0.8))


## Applies the active-skill highlight style to the given skill's row.
func _apply_skill_highlight(sname: String) -> void:
	var row: Node = _skill_rows.get(sname, null)
	if row != null and is_instance_valid(row):
		var style := _selection_style()
		row.add_theme_stylebox_override("panel", style)


## Removes the active-skill highlight style from every skill row.
func _clear_skill_highlight() -> void:
	for row in _skill_rows.values():
		if row is Node and is_instance_valid(row):
			row.add_theme_stylebox_override("panel", _card_style())


# ---------------------------------------------------------------------------
# Inventory toggle from top-right button
# ---------------------------------------------------------------------------
func _toggle_inventory() -> void:
	if inventory_panel.visible:
		_close_panels()
	else:
		_rebuild_inventory()
		_open_panel(inventory_panel)


## Opens/closes the pause menu. Shared by Esc and the mobile Pause button.
func _toggle_pause_panel() -> void:
	if _any_panel_visible():
		_close_panels()
	else:
		_open_panel(pause_panel)


# ---------------------------------------------------------------------------
# Monsterpedia
# ---------------------------------------------------------------------------
func _toggle_monsterpedia() -> void:
	if monsterpedia_panel.visible:
		_close_panels()
	else:
		_rebuild_monsterpedia()
		_open_panel(monsterpedia_panel)


func _rebuild_monsterpedia() -> void:
	_clear(monsterpedia_list)
	var monster_names: Array = GameData.monster_list() if GameData.has_method("monster_list") else []
	if monster_names.is_empty():
		monsterpedia_list.add_child(_make_label("No monster data available.", 15, Color(0.8, 0.85, 0.8)))
		return
	var idx := 0
	for mname in monster_names:
		var m: Dictionary = GameData.monster(str(mname))
		if m.is_empty():
			continue
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", _box(Color(1, 1, 1, 0.04 if idx % 2 == 0 else 0.0), Color(0, 0, 0, 0), 0, 6, Vector2(10, 5)))
		monsterpedia_list.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		card.add_child(row)
		var name_lbl := _make_label(str(mname), 14, Color(0.95, 0.9, 0.7))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_lbl)
		var hp_lbl := _make_label("HP  %s" % _fmt_stat(m.get("health", "?")), 13, Color(0.9, 0.5, 0.5))
		hp_lbl.custom_minimum_size = Vector2(120, 0)
		hp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(hp_lbl)
		var pwr_lbl := _make_label("Pwr  %s" % _fmt_stat(m.get("power", "?")), 13, Color(0.95, 0.72, 0.4))
		pwr_lbl.custom_minimum_size = Vector2(120, 0)
		pwr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(pwr_lbl)
		idx += 1


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


# ---------------------------------------------------------------------------
# Settings & Graphics
# ---------------------------------------------------------------------------
func _toggle_settings() -> void:
	if settings_panel.visible:
		_close_panels()
	else:
		_refresh_settings_ui()
		_open_panel(settings_panel)


func _refresh_settings_ui() -> void:
	if zoom_label != null:
		zoom_label.text = "Camera Zoom: %.2fx" % GameState.camera_zoom
	if zoom_slider != null:
		zoom_slider.value = GameState.camera_zoom
	if fps_btn != null:
		fps_btn.text = "Show FPS: %s" % ( "On" if show_fps else "Off" )
	if fps_label != null:
		fps_label.visible = show_fps


func _on_zoom_slider_changed(val: float) -> void:
	GameState.set_camera_zoom(val)
	if zoom_label != null:
		zoom_label.text = "Camera Zoom: %.2fx" % val


func _apply_zoom(val: float) -> void:
	GameState.set_camera_zoom(val)
	_refresh_settings_ui()


func _toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		show_toast("Windowed Mode")
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		show_toast("Fullscreen Mode")


func _toggle_vsync() -> void:
	var mode := DisplayServer.window_get_vsync_mode()
	if mode == DisplayServer.VSYNC_ENABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		show_toast("V-Sync Disabled")
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		show_toast("V-Sync Enabled")


func _toggle_show_fps() -> void:
	show_fps = not show_fps
	GameState.show_fps = show_fps
	GameState.save_game()
	_refresh_settings_ui()
	if show_fps:
		show_toast("FPS counter enabled")
	else:
		show_toast("FPS counter disabled")
