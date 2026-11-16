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

	# Semi-transparent backdrop
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.76)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(bg)

	# Main center box
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(720, 520)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.12, 0.18, 0.98)
	style.set_corner_radius_all(10)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.85, 0.65, 0.25)
	frame.add_theme_stylebox_override("panel", style)
	center.add_child(frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	frame.add_child(vbox)

	# Title bar
	var title := Label.new()
	title.text = "PLAYER-TO-PLAYER TRADE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	vbox.add_child(title)

	# Columns (Left: You, Right: Partner)
	var cols := HBoxContainer.new()
	cols.alignment = BoxContainer.ALIGNMENT_CENTER
	cols.add_theme_constant_override("separation", 24)
	vbox.add_child(cols)

	# --- Left column: Your Offer ---
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(320, 180)
	cols.add_child(left)

	var my_lbl := Label.new()
	my_lbl.text = "YOUR OFFER"
	my_lbl.add_theme_font_size_override("font_size", 13)
	my_lbl.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	left.add_child(my_lbl)

	_my_slots_box = HBoxContainer.new()
	_my_slots_box.add_theme_constant_override("separation", 6)
	left.add_child(_my_slots_box)

	for i in range(4):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(74, 56)
		btn.text = "Empty"
		btn.pressed.connect(_on_my_slot_clicked.bind(i))
		_my_slots_box.add_child(btn)

	var gold_row := HBoxContainer.new()
	gold_row.add_theme_constant_override("separation", 4)
	left.add_child(gold_row)

	_my_gold_label = Label.new()
	_my_gold_label.text = "Gold: 0"
	_my_gold_label.custom_minimum_size = Vector2(90, 0)
	gold_row.add_child(_my_gold_label)

	var add_10k := Button.new()
	add_10k.text = "+10K"
	add_10k.custom_minimum_size = Vector2(46, 32)
	add_10k.pressed.connect(func(): _add_gold(10000))
	gold_row.add_child(add_10k)

	var add_100k := Button.new()
	add_100k.text = "+100K"
	add_100k.custom_minimum_size = Vector2(50, 32)
	add_100k.pressed.connect(func(): _add_gold(100000))
	gold_row.add_child(add_100k)

	var add_1m := Button.new()
	add_1m.text = "+1M"
	add_1m.custom_minimum_size = Vector2(46, 32)
	add_1m.pressed.connect(func(): _add_gold(1000000))
	gold_row.add_child(add_1m)

	var clr_gold := Button.new()
	clr_gold.text = "Clr"
	clr_gold.custom_minimum_size = Vector2(40, 32)
	clr_gold.pressed.connect(func(): _set_gold(0))
	gold_row.add_child(clr_gold)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	left.add_child(status_row)

	_my_status_label = Label.new()
	_my_status_label.text = "Editing offer..."
	_my_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_my_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	status_row.add_child(_my_status_label)

	_lock_button = Button.new()
	_lock_button.text = "LOCK OFFER"
	_lock_button.custom_minimum_size = Vector2(110, 36)
	_lock_button.pressed.connect(_toggle_lock)
	status_row.add_child(_lock_button)

	# --- Right column: Partner Offer ---
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(320, 180)
	cols.add_child(right)

	var their_lbl := Label.new()
	their_lbl.text = "THEIR OFFER"
	their_lbl.add_theme_font_size_override("font_size", 13)
	their_lbl.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	right.add_child(their_lbl)

	_their_slots_box = HBoxContainer.new()
	_their_slots_box.add_theme_constant_override("separation", 6)
	right.add_child(_their_slots_box)

	for i in range(4):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(74, 56)
		btn.disabled = true
		btn.text = "Empty"
		_their_slots_box.add_child(btn)

	_their_gold_label = Label.new()
	_their_gold_label.text = "Gold: 0"
	_their_gold_label.custom_minimum_size = Vector2(0, 32)
	right.add_child(_their_gold_label)

	_their_status_label = Label.new()
	_their_status_label.text = "Waiting for partner..."
	_their_status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	right.add_child(_their_status_label)

	# --- Middle Divider: Backpack Picker ---
	var inv_header := Label.new()
	inv_header.text = "YOUR BACKPACK (Tap any item to add to your trade offer):"
	inv_header.add_theme_font_size_override("font_size", 12)
	inv_header.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	vbox.add_child(inv_header)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(680, 120)
	vbox.add_child(scroll)

	_backpack_container = GridContainer.new()
	_backpack_container.columns = 6
	_backpack_container.add_theme_constant_override("h_separation", 6)
	_backpack_container.add_theme_constant_override("v_separation", 6)
	scroll.add_child(_backpack_container)

	# --- Bottom action bar ---
	_status_banner = Label.new()
	_status_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_banner.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	vbox.add_child(_status_banner)

	var bot_actions := HBoxContainer.new()
	bot_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	bot_actions.add_theme_constant_override("separation", 16)
	vbox.add_child(bot_actions)

	_trade_button = Button.new()
	_trade_button.text = "CONFIRM TRADE"
	_trade_button.custom_minimum_size = Vector2(180, 44)
	_trade_button.disabled = true
	_trade_button.pressed.connect(_on_confirm_trade_pressed)
	bot_actions.add_child(_trade_button)

	var cancel_btn := Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(120, 44)
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
		GameState.remove_inventory_item(str(it.get("name")), int(it.get("qty", 1)))
	if my_gold > 0:
		GameState.gold = maxi(0, GameState.gold - my_gold)

	for it in their_items:
		GameState.add_inventory_item(str(it.get("name")), int(it.get("qty", 1)))
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
		else:
			btn.text = "Empty"

	# 2. Their slots
	for i in range(4):
		var btn: Button = _their_slots_box.get_child(i)
		if i < their_items.size():
			btn.text = their_items[i].get("name", "Item")
		else:
			btn.text = "Empty"

	_my_gold_label.text = "Gold: %s" % Number(my_gold).toLocaleString()
	_their_gold_label.text = "Gold: %s" % Number(their_gold).toLocaleString()

	if my_locked:
		_lock_button.text = "UNLOCK"
		_my_status_label.text = "Offer Locked ✓"
		_my_status_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.4))
	else:
		_lock_button.text = "LOCK OFFER"
		_my_status_label.text = "Editing offer..."
		_my_status_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))

	if their_locked:
		_their_status_label.text = "Partner Locked ✓"
		_their_status_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.4))
	else:
		_their_status_label.text = "Partner is choosing items..."
		_their_status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))

	if my_locked and their_locked:
		_trade_button.disabled = my_confirmed
		_status_banner.text = "Both offers locked! Click Confirm to finalize trade."
		_status_banner.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
	else:
		_trade_button.disabled = true
		_status_banner.text = "Both players must lock their offers."
		_status_banner.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))

	# 3. Refresh backpack item grid
	for child in _backpack_container.get_children():
		child.queue_free()

	for inv_item in GameState.inventory:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(105, 36)
		btn.text = inv_item.name
		btn.clip_text = true

		var already_offered := false
		for off in my_items:
			if off.get("name") == inv_item.name:
				already_offered = true
				break

		if already_offered or my_locked or inv_item.get("locked", false):
			btn.disabled = true
		else:
			btn.pressed.connect(_on_inventory_item_clicked.bind(inv_item))

		_backpack_container.add_child(btn)
