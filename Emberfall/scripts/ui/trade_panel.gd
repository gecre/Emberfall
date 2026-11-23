extends CanvasLayer

## Mobile & Desktop Player-to-Player Trade Window
signal trade_finished

var partner_id := 0
var partner_name := "Player"

var my_items: Array = []  # Array of inventory items: [{name, qty, ...}]
var my_gold := 0
var my_locked := false
var my_confirmed := false

var their_items: Array = []
var their_gold := 0
var their_locked := false
var their_confirmed := false

var _panel: PanelContainer
var _partner_title_lbl: Label
var _my_slots_box: HBoxContainer
var _their_slots_box: HBoxContainer
var _my_gold_label: Label
var _their_gold_label: Label
var _my_status_label: Label
var _their_status_label: Label
var _lock_button: Button
var _trade_button: Button
var _status_banner: Label
var _backpack_container: GridContainer


func _ready() -> void:
	layer = 95
	_build_ui()
	_connect_network()


func open(target_id: int, target_name: String) -> void:
	partner_id = target_id
	partner_name = target_name
	my_items.clear()
	my_gold = 0
	my_locked = false
	my_confirmed = false
	their_items.clear()
	their_gold = 0
	their_locked = false
	their_confirmed = false
	if _partner_title_lbl != null:
		_partner_title_lbl.text = "Trading with: %s" % partner_name
	_refresh_ui()
	_panel.visible = true


func close() -> void:
	if partner_id > 0:
		Network.cancel_trade(partner_id)
	partner_id = 0
	_panel.visible = false
	trade_finished.emit()


func _connect_network() -> void:
	Network.trade_offer_updated.connect(_on_trade_offer_updated)
	Network.trade_confirmed_by_partner.connect(_on_trade_confirmed_by_partner)
	Network.trade_cancelled_by_partner.connect(_on_trade_cancelled_by_partner)


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	# Dimmed backdrop
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(bg)

	# Main center box
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(740, 530)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.11, 0.17, 0.98)
	style.set_corner_radius_all(14)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(1.0, 0.78, 0.3)
	style.shadow_color = Color(0, 0, 0, 0.8)
	style.shadow_size = 24
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	frame.add_theme_stylebox_override("panel", style)
	center.add_child(frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	# Title bar
	var header_box := VBoxContainer.new()
	header_box.add_theme_constant_override("separation", 2)
	vbox.add_child(header_box)

	var title := Label.new()
	title.text = "🤝  PLAYER-TO-PLAYER TRADE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	header_box.add_child(title)

	_partner_title_lbl = Label.new()
	_partner_title_lbl.text = "Trading with: Player"
	_partner_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_partner_title_lbl.add_theme_font_size_override("font_size", 12)
	_partner_title_lbl.add_theme_color_override("font_color", Color(0.65, 0.8, 0.95))
	header_box.add_child(_partner_title_lbl)

	# Columns (Left: You, Right: Partner)
	var cols := HBoxContainer.new()
	cols.alignment = BoxContainer.ALIGNMENT_CENTER
	cols.add_theme_constant_override("separation", 16)
	vbox.add_child(cols)

	# --- Left column: Your Offer ---
	var left_panel := PanelContainer.new()
	left_panel.custom_minimum_size = Vector2(340, 185)
	var left_style := StyleBoxFlat.new()
	left_style.bg_color = Color(0.05, 0.08, 0.13, 0.9)
	left_style.set_corner_radius_all(10)
	left_style.set_border_width_all(1)
	left_style.border_color = Color(0.2, 0.45, 0.75, 0.6)
	left_style.content_margin_left = 12
	left_style.content_margin_right = 12
	left_style.content_margin_top = 10
	left_style.content_margin_bottom = 10
	left_panel.add_theme_stylebox_override("panel", left_style)
	cols.add_child(left_panel)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left_panel.add_child(left)

	var my_lbl := Label.new()
	my_lbl.text = "YOUR OFFER"
	my_lbl.add_theme_font_size_override("font_size", 12)
	my_lbl.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	left.add_child(my_lbl)

	_my_slots_box = HBoxContainer.new()
	_my_slots_box.add_theme_constant_override("separation", 6)
	left.add_child(_my_slots_box)

	for i in range(4):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(72, 54)
		btn.text = "Empty"
		btn.clip_text = true
		btn.add_theme_font_size_override("font_size", 10)
		btn.pressed.connect(_on_my_slot_clicked.bind(i))
		_my_slots_box.add_child(btn)

	var gold_row := HBoxContainer.new()
	gold_row.add_theme_constant_override("separation", 4)
	left.add_child(gold_row)

	_my_gold_label = Label.new()
	_my_gold_label.text = "🪙 0"
	_my_gold_label.custom_minimum_size = Vector2(85, 0)
	_my_gold_label.add_theme_font_size_override("font_size", 12)
	_my_gold_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
	gold_row.add_child(_my_gold_label)

	var add_10k := Button.new()
	add_10k.text = "+10K"
	add_10k.custom_minimum_size = Vector2(44, 28)
	add_10k.add_theme_font_size_override("font_size", 10)
	add_10k.pressed.connect(func(): _add_gold(10000))
	gold_row.add_child(add_10k)

	var add_100k := Button.new()
	add_100k.text = "+100K"
	add_100k.custom_minimum_size = Vector2(50, 28)
	add_100k.add_theme_font_size_override("font_size", 10)
	add_100k.pressed.connect(func(): _add_gold(100000))
	gold_row.add_child(add_100k)

	var add_1m := Button.new()
	add_1m.text = "+1M"
	add_1m.custom_minimum_size = Vector2(44, 28)
	add_1m.add_theme_font_size_override("font_size", 10)
	add_1m.pressed.connect(func(): _add_gold(1000000))
	gold_row.add_child(add_1m)

	var clr_gold := Button.new()
	clr_gold.text = "Clr"
	clr_gold.custom_minimum_size = Vector2(36, 28)
	clr_gold.add_theme_font_size_override("font_size", 10)
	clr_gold.pressed.connect(func(): _set_gold(0))
	gold_row.add_child(clr_gold)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	left.add_child(status_row)

	_my_status_label = Label.new()
	_my_status_label.text = "Editing offer..."
	_my_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_my_status_label.add_theme_font_size_override("font_size", 11)
	_my_status_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
	status_row.add_child(_my_status_label)

	_lock_button = Button.new()
	_lock_button.text = "🔒 LOCK OFFER"
	_lock_button.custom_minimum_size = Vector2(105, 32)
	_lock_button.add_theme_font_size_override("font_size", 11)
	_lock_button.pressed.connect(_toggle_lock)
	status_row.add_child(_lock_button)

	# --- Right column: Partner Offer ---
	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(340, 185)
	var right_style := StyleBoxFlat.new()
	right_style.bg_color = Color(0.08, 0.07, 0.10, 0.9)
	right_style.set_corner_radius_all(10)
	right_style.set_border_width_all(1)
	right_style.border_color = Color(0.75, 0.55, 0.2, 0.6)
	right_style.content_margin_left = 12
	right_style.content_margin_right = 12
	right_style.content_margin_top = 10
	right_style.content_margin_bottom = 10
	right_panel.add_theme_stylebox_override("panel", right_style)
	cols.add_child(right_panel)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right_panel.add_child(right)

	var their_lbl := Label.new()
	their_lbl.text = "THEIR OFFER"
	their_lbl.add_theme_font_size_override("font_size", 12)
	their_lbl.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	right.add_child(their_lbl)

	_their_slots_box = HBoxContainer.new()
	_their_slots_box.add_theme_constant_override("separation", 6)
	right.add_child(_their_slots_box)

	for i in range(4):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(72, 54)
		btn.disabled = true
		btn.text = "Empty"
		btn.clip_text = true
		btn.add_theme_font_size_override("font_size", 10)
		_their_slots_box.add_child(btn)

	_their_gold_label = Label.new()
	_their_gold_label.text = "🪙 0"
	_their_gold_label.custom_minimum_size = Vector2(0, 28)
	_their_gold_label.add_theme_font_size_override("font_size", 12)
	_their_gold_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
	right.add_child(_their_gold_label)

	_their_status_label = Label.new()
	_their_status_label.text = "Waiting for partner..."
	_their_status_label.add_theme_font_size_override("font_size", 11)
	_their_status_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	right.add_child(_their_status_label)

	# --- Middle Divider: Backpack Picker ---
	var inv_header := Label.new()
	inv_header.text = "🎒  YOUR BACKPACK (Tap an item to add to offer):"
	inv_header.add_theme_font_size_override("font_size", 12)
	inv_header.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	vbox.add_child(inv_header)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(700, 110)
	vbox.add_child(scroll)

	_backpack_container = GridContainer.new()
	_backpack_container.columns = 6
	_backpack_container.add_theme_constant_override("h_separation", 6)
	_backpack_container.add_theme_constant_override("v_separation", 6)
	scroll.add_child(_backpack_container)

	# --- Bottom action bar ---
	_status_banner = Label.new()
	_status_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_banner.add_theme_font_size_override("font_size", 12)
	_status_banner.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	vbox.add_child(_status_banner)

	var bot_actions := HBoxContainer.new()
	bot_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	bot_actions.add_theme_constant_override("separation", 18)
	vbox.add_child(bot_actions)

	_trade_button = Button.new()
	_trade_button.text = "CONFIRM TRADE"
	_trade_button.custom_minimum_size = Vector2(190, 42)
	_trade_button.add_theme_font_size_override("font_size", 13)
	_trade_button.disabled = true
	var trade_style := StyleBoxFlat.new()
	trade_style.bg_color = Color(0.16, 0.52, 0.28, 1.0)
	trade_style.set_corner_radius_all(8)
	_trade_button.add_theme_stylebox_override("normal", trade_style)
	_trade_button.pressed.connect(_on_confirm_trade_pressed)
	bot_actions.add_child(_trade_button)

	var cancel_btn := Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(130, 42)
	cancel_btn.add_theme_font_size_override("font_size", 13)
	var cancel_style := StyleBoxFlat.new()
	cancel_style.bg_color = Color(0.35, 0.15, 0.15, 1.0)
	cancel_style.set_corner_radius_all(8)
	cancel_btn.add_theme_stylebox_override("normal", cancel_style)
	cancel_btn.pressed.connect(close)
	bot_actions.add_child(cancel_btn)


func _on_my_slot_clicked(slot_idx: int) -> void:
	if my_locked:
		return
	if slot_idx < my_items.size():
		my_items.remove_at(slot_idx)
		_sync_my_offer()
		_refresh_ui()


func _on_inventory_item_clicked(inv_item: Dictionary) -> void:
	if my_locked:
		return
	if my_items.size() >= 4:
		GameState.message.emit("You can only offer up to 4 items at a time.")
		return
	for offered in my_items:
		if offered.get("name") == inv_item.get("name"):
			GameState.message.emit("Item is already in your offer.")
			return
	my_items.append({"name": inv_item.name, "qty": 1})
	_sync_my_offer()
	_refresh_ui()


func _add_gold(amount: int) -> void:
	if my_locked:
		return
	my_gold = mini(GameState.gold, my_gold + amount)
	_sync_my_offer()
	_refresh_ui()


func _set_gold(amount: int) -> void:
	if my_locked:
		return
	my_gold = clampi(amount, 0, GameState.gold)
	_sync_my_offer()
	_refresh_ui()


func _toggle_lock() -> void:
	my_locked = not my_locked
	if not my_locked:
		my_confirmed = false
	_sync_my_offer()
	_refresh_ui()


func _sync_my_offer() -> void:
	if partner_id > 0:
		Network.send_trade_offer(partner_id, my_items, my_gold, my_locked)


func _on_trade_offer_updated(from_id: int, items: Array, gold: int, locked: bool) -> void:
	if from_id != partner_id:
		return
	their_items = items
	their_gold = gold
	their_locked = locked
	if not their_locked:
		their_confirmed = false
		my_confirmed = false
	_refresh_ui()


func _on_confirm_trade_pressed() -> void:
	if not my_locked or not their_locked:
		return
	my_confirmed = true
	_trade_button.disabled = true
	_trade_button.text = "ACCEPTED ✓"
	Network.confirm_trade(partner_id)
	if their_confirmed:
		_execute_trade()


func _on_trade_confirmed_by_partner(from_id: int) -> void:
	if from_id != partner_id:
		return
	their_confirmed = true
	_their_status_label.text = "Partner Accepted! ✓"
	_their_status_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
	if my_confirmed:
		_execute_trade()
	else:
		_trade_button.disabled = false


func _on_trade_cancelled_by_partner(from_id: int) -> void:
	if from_id != partner_id:
		return
	GameState.message.emit("%s cancelled the trade." % partner_name)
	close()


func _execute_trade() -> void:
	for it in my_items:
		GameState.remove_item(str(it.get("name")), int(it.get("qty", 1)))
	if my_gold > 0:
		GameState.gold = maxi(0, GameState.gold - my_gold)

	for it in their_items:
		GameState.add_item(str(it.get("name")), int(it.get("qty", 1)))
	if their_gold > 0:
		GameState.gold += their_gold

	GameState.gold_changed.emit()
	GameState.inventory_changed.emit()
	GameState.save_game()
	GameState.message.emit("Trade completed successfully!")
	close()


func _refresh_ui() -> void:
	# 1. My slots
	for i in range(4):
		var btn: Button = _my_slots_box.get_child(i)
		if i < my_items.size():
			btn.text = my_items[i].get("name", "Item")
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.12, 0.22, 0.35, 0.95)
			sb.set_border_width_all(1)
			sb.border_color = Color(0.35, 0.7, 1.0, 0.9)
			sb.set_corner_radius_all(6)
			btn.add_theme_stylebox_override("normal", sb)
		else:
			btn.text = "Empty"
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.06, 0.08, 0.12, 0.5)
			sb.set_border_width_all(1)
			sb.border_color = Color(0.2, 0.25, 0.35, 0.35)
			sb.set_corner_radius_all(6)
			btn.add_theme_stylebox_override("normal", sb)

	# 2. Their slots
	for i in range(4):
		var btn: Button = _their_slots_box.get_child(i)
		if i < their_items.size():
			btn.text = their_items[i].get("name", "Item")
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.22, 0.16, 0.10, 0.95)
			sb.set_border_width_all(1)
			sb.border_color = Color(1.0, 0.75, 0.3, 0.9)
			sb.set_corner_radius_all(6)
			btn.add_theme_stylebox_override("disabled", sb)
		else:
			btn.text = "Empty"
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.06, 0.08, 0.12, 0.5)
			sb.set_border_width_all(1)
			sb.border_color = Color(0.2, 0.25, 0.35, 0.35)
			sb.set_corner_radius_all(6)
			btn.add_theme_stylebox_override("disabled", sb)

	_my_gold_label.text = "🪙 %s" % _format_number(my_gold)
	_their_gold_label.text = "🪙 %s" % _format_number(their_gold)

	if my_locked:
		_lock_button.text = "🔓 UNLOCK"
		_my_status_label.text = "Offer Locked ✓"
		_my_status_label.add_theme_color_override("font_color", Color(0.35, 0.88, 0.45))
		var lsb := StyleBoxFlat.new()
		lsb.bg_color = Color(0.15, 0.45, 0.25, 0.9)
		lsb.set_corner_radius_all(6)
		_lock_button.add_theme_stylebox_override("normal", lsb)
	else:
		_lock_button.text = "🔒 LOCK OFFER"
		_my_status_label.text = "Editing offer..."
		_my_status_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9))
		var lsb := StyleBoxFlat.new()
		lsb.bg_color = Color(0.15, 0.25, 0.4, 0.9)
		lsb.set_corner_radius_all(6)
		_lock_button.add_theme_stylebox_override("normal", lsb)

	if their_locked:
		_their_status_label.text = "Partner Locked ✓"
		_their_status_label.add_theme_color_override("font_color", Color(0.35, 0.88, 0.45))
	else:
		_their_status_label.text = "Partner is choosing items..."
		_their_status_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))

	if my_locked and their_locked:
		_trade_button.disabled = my_confirmed
		_status_banner.text = "✔ Both offers locked! Click Confirm Trade to finalize."
		_status_banner.add_theme_color_override("font_color", Color(0.35, 0.9, 0.45))
	else:
		_trade_button.disabled = true
		_status_banner.text = "⏳ Both players must lock their offers before confirming."
		_status_banner.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))

	# 3. Refresh backpack item grid
	for child in _backpack_container.get_children():
		child.queue_free()

	for inv_item in GameState.inventory:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(105, 34)
		btn.text = inv_item.name
		btn.clip_text = true
		btn.add_theme_font_size_override("font_size", 11)

		var already_offered := false
		for off in my_items:
			if off.get("name") == inv_item.name:
				already_offered = true
				break

		var issb := StyleBoxFlat.new()
		issb.set_corner_radius_all(6)
		issb.set_border_width_all(1)

		if already_offered or my_locked or inv_item.get("locked", false):
			btn.disabled = true
			issb.bg_color = Color(0.08, 0.1, 0.14, 0.4)
			issb.border_color = Color(0.18, 0.2, 0.25, 0.3)
			btn.add_theme_stylebox_override("disabled", issb)
		else:
			issb.bg_color = Color(0.10, 0.14, 0.20, 0.85)
			issb.border_color = Color(0.28, 0.38, 0.55, 0.6)
			btn.add_theme_stylebox_override("normal", issb)
			btn.pressed.connect(_on_inventory_item_clicked.bind(inv_item))

		_backpack_container.add_child(btn)


func _format_number(n: int) -> String:
	var s := str(n)
	var res := ""
	var cnt := 0
	for i in range(s.length() - 1, -1, -1):
		res = s[i] + res
		cnt += 1
		if cnt % 3 == 0 and i > 0:
			res = "," + res
	return res
