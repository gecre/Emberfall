extends PanelContainer
class_name StatsPanel

## Reusable stats HUD panel matching the Helmet Heroes style:
## header (Lv 536 Hero (Mage)), HP/MP bars with centered text, XP bar,
## and a gold + XP row. Reads live values from GameState.

var level_label: Label = null
var hp_bar: ProgressBar = null
var hp_text: Label = null
var mp_bar: ProgressBar = null
var mp_text: Label = null
var xp_bar: ProgressBar = null
var gold_label: Label = null
var xp_label: Label = null

var _cached_hp := -1
var _cached_max_hp := -1.0
var _cached_mp := -1
var _cached_max_mp: float = -1.0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_theme_stylebox_override("panel", _panel_style())
	_build_ui()
	_refresh()
	# Live updates.
	GameState.stats_changed.connect(_refresh)
	GameState.gold_changed.connect(_refresh)

func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, 0.92)
	style.set_corner_radius_all(14)
	style.border_color = Color(0.25, 0.2, 0.18, 1.0)
	style.set_border_width_all(1)
	style.border_width_left = 4
	style.border_color = Color(0.93, 0.42, 0.12, 1.0)
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 8
	style.content_margin_left = 18
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style

func _build_ui() -> void:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	# Header
	level_label = _make_label("Lv 1 Hero (Warrior)", 20, Color(1.0, 0.85, 0.7))
	level_label.add_theme_color_override("font_outline_color", Color(0.2, 0.08, 0.02, 0.9))
	level_label.add_theme_constant_override("outline_size", 4)
	vbox.add_child(level_label)

	# HP / MP
	hp_bar = _make_bar(Color(0.88, 0.27, 0.25), 20)
	vbox.add_child(hp_bar)
	hp_text = _bar_text(hp_bar)

	mp_bar = _make_bar(Color(0.25, 0.52, 0.95), 20)
	vbox.add_child(mp_bar)
	mp_text = _bar_text(mp_bar)

	# XP (thin)
	xp_bar = _make_bar(Color(1.0, 0.6, 0.2), 6)
	xp_bar.max_value = 1.0
	vbox.add_child(xp_bar)

	# Gold left, XP right
	var bottom := HBoxContainer.new()
	vbox.add_child(bottom)
	gold_label = _make_label("0 gold", 14, Color(1.0, 0.82, 0.3))
	bottom.add_child(gold_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	xp_label = _make_label("0 / 0 XP", 12, Color(0.65, 0.65, 0.7))
	bottom.add_child(xp_label)

func _bar_text(bar: ProgressBar) -> Label:
	var t := _make_label("0 / 0", 12, Color.WHITE)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	t.add_theme_constant_override("outline_size", 3)
	bar.add_child(t)
	return t

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

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

func _refresh() -> void:
	if level_label == null:
		return
	var stats := GameState.stats()
	var hp := GameState.current_hp
	var mp := GameState.current_mp
	var max_hp := float(stats["max_hp"])
	var max_mp := float(stats["max_mp"])

	level_label.text = "Lv %d %s (%s)" % [GameState.level, GameState.player_name, GameState.player_class]

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

	xp_bar.value = GameState.xp_progress()
	gold_label.text = "%s gold" % GameState.format_number(GameState.gold)
	xp_label.text = "%d / %d XP" % [GameState.xp, GameState.xp_to_next()]
