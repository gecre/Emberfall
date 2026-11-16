class_name UITheme

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

func _make_theme() -> Theme:
	var t := Theme.new()
	var orange := Color(0.93, 0.42, 0.12)
	var glow := Color(1.0, 0.5, 0.2)
	var none := Color(0, 0, 0, 0)

	# Default button
	t.set_stylebox("normal", "Button", _box(Color(0.13, 0.13, 0.16, 0.95), Color(0.3, 0.3, 0.35), 1, 8, Vector2(12, 6)))
	t.set_stylebox("hover", "Button", _box(Color(0.18, 0.15, 0.15, 0.98), glow, 1, 8, Vector2(12, 6)))
	t.set_stylebox("pressed", "Button", _box(Color(0.10, 0.10, 0.12), Color(0.8, 0.4, 0.15), 1, 8, Vector2(12, 6)))
	t.set_stylebox("disabled", "Button", _box(Color(0.09, 0.09, 0.11, 0.8), Color(0.18, 0.18, 0.22), 1, 8, Vector2(12, 6)))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.9, 0.9, 0.92))
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", glow)
	t.set_color("font_disabled_color", "Button", Color(0.4, 0.4, 0.45))

	# Primary (orange)
	t.set_type_variation("PrimaryButton", "Button")
	t.set_stylebox("normal", "PrimaryButton", _box(orange, none, 0, 8, Vector2(12, 6)))
	t.set_stylebox("hover", "PrimaryButton", _box(Color(1.0, 0.52, 0.2), none, 0, 8, Vector2(12, 6)))
	t.set_stylebox("pressed", "PrimaryButton", _box(Color(0.75, 0.32, 0.08), none, 0, 8, Vector2(12, 6)))
	t.set_stylebox("disabled", "PrimaryButton", _box(Color(0.25, 0.15, 0.10, 0.7), none, 0, 8, Vector2(12, 6)))
	t.set_color("font_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_hover_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_pressed_color", "PrimaryButton", Color.WHITE)
	t.set_color("font_disabled_color", "PrimaryButton", Color(0.6, 0.5, 0.45))

	# Top-right nav pills
	t.set_type_variation("NavButton", "Button")
	t.set_stylebox("normal", "NavButton", _box(Color(0.07, 0.07, 0.09, 0.85), Color(0.25, 0.2, 0.18), 1, 16, Vector2(14, 5)))
	t.set_stylebox("hover", "NavButton", _box(Color(0.15, 0.09, 0.06, 0.95), glow, 1, 16, Vector2(14, 5)))
	t.set_stylebox("pressed", "NavButton", _box(orange, none, 0, 16, Vector2(14, 5)))

	# Hotbar / skill slots
	t.set_type_variation("SlotButton", "Button")
	t.set_stylebox("normal", "SlotButton", _box(Color(0.07, 0.07, 0.09, 0.8), Color(0.28, 0.24, 0.22), 2, 10, Vector2(6, 4)))
	t.set_stylebox("hover", "SlotButton", _box(Color(0.12, 0.09, 0.07, 0.9), glow, 2, 10, Vector2(6, 4)))
	t.set_stylebox("pressed", "SlotButton", _box(Color(0.25, 0.12, 0.05, 0.95), orange, 2, 10, Vector2(6, 4)))
	t.set_stylebox("disabled", "SlotButton", _box(Color(0.05, 0.05, 0.07, 0.6), Color(0.16, 0.16, 0.2), 2, 10, Vector2(6, 4)))

	# Separator
	var sep := StyleBoxLine.new()
	sep.color = Color(1, 1, 1, 0.10)
	sep.thickness = 1
	t.set_stylebox("separator", "HSeparator", sep)
	t.set_constant("separation", "HSeparator", 12)

	# Scrollbar
	t.set_stylebox("scroll", "VScrollBar", _box(Color(0, 0, 0, 0.25), none, 0, 4, Vector2(5, 0)))
	t.set_stylebox("grabber", "VScrollBar", _box(Color(0.35, 0.3, 0.28), none, 0, 4, Vector2(5, 0)))
	t.set_stylebox("grabber_highlight", "VScrollBar", _box(Color(0.93, 0.42, 0.12, 0.9), none, 0, 4, Vector2(5, 0)))
	t.set_stylebox("grabber_pressed", "VScrollBar", _box(Color(1.0, 0.52, 0.2), none, 0, 4, Vector2(5, 0)))

	# Slider
	t.set_stylebox("slider", "HSlider", _box(Color(0.03, 0.03, 0.04), Color(0.2, 0.2, 0.24), 1, 4, Vector2(0, 3)))
	t.set_stylebox("grabber_area", "HSlider", _box(orange, none, 0, 4, Vector2(0, 3)))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(Color(1.0, 0.52, 0.2), none, 0, 4, Vector2(0, 3)))

	# Tooltip
	t.set_stylebox("panel", "TooltipPanel", _box(Color(0.06, 0.06, 0.08, 0.97), Color(0.93, 0.42, 0.12, 0.8), 1, 8, Vector2(10, 8)))
	t.set_color("font_color", "TooltipLabel", Color(0.92, 0.94, 0.95))
	t.set_font_size("font_size", "TooltipLabel", 13)
	return t
