extends CanvasLayer

## Mobile & Desktop Street Stall (Player Shop) Window
signal stall_closed

var is_owner := false
var seller_id := 0
var seller_name := "Player"
var stall_title := "Player Shop"
var stall_items: Array = []  # [{name, price, qty}]

var _panel: PanelContainer
var _title_label: Label
var _items_container: VBoxContainer
var _owner_controls: VBoxContainer
var _title_input: LineEdit


func _ready() -> void:
	layer = 94
	_build_ui()
	Network.stall_buy_completed.connect(_on_stall_buy_completed)
	Network.stall_item_sold_notification.connect(_on_stall_item_sold)


func open_for_setup() -> void:
	is_owner = true
	seller_id = Network.our_id
	seller_name = GameState.player_name
	stall_title = "%s's Shop" % seller_name
	stall_items.clear()
	_refresh_ui()
	_panel.visible = true


func open_for_browsing(owner_peer_id: int, owner_name: String, stall_data: Dictionary) -> void:
	is_owner = false
	seller_id = owner_peer_id
	seller_name = owner_name
	stall_title = str(stall_data.get("title", "%s's Shop" % owner_name))
	stall_items = stall_data.get("items", []).duplicate(true)
	_refresh_ui()
	_panel.visible = true


func close() -> void:
	_panel.visible = false
	stall_closed.emit()


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.7)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)

	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(580, 440)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.20, 0.98)
	style.set_corner_radius_all(10)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.85, 0.65, 0.25)
	frame.add_theme_stylebox_override("panel", style)
	center.add_child(frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	frame.add_child(vbox)

	_title_label = Label.new()
	_title_label.text = "STREET STALL"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 17)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	vbox.add_child(_title_label)

	_owner_controls = VBoxContainer.new()
	_owner_controls.add_theme_constant_override("separation", 8)
	vbox.add_child(_owner_controls)

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	_owner_controls.add_child(name_row)

	var nl := Label.new()
	nl.text = "Shop Title:"
	name_row.add_child(nl)

	_title_input = LineEdit.new()
	_title_input.custom_minimum_size = Vector2(260, 36)
	_title_input.text = "My Shop"
	name_row.add_child(_title_input)

	var add_btn := Button.new()
	add_btn.text = "+ Put Item For Sale"
	add_btn.custom_minimum_size = Vector2(160, 36)
	add_btn.pressed.connect(_on_add_item_pressed)
	_owner_controls.add_child(add_btn)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(540, 240)
	vbox.add_child(scroll)

	_items_container = VBoxContainer.new()
	_items_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_items_container.add_theme_constant_override("separation", 6)
	scroll.add_child(_items_container)

	var bot_actions := HBoxContainer.new()
	bot_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	bot_actions.add_theme_constant_override("separation", 16)
	vbox.add_child(bot_actions)

	var open_stall_btn := Button.new()
	open_stall_btn.name = "OpenStallBtn"
	open_stall_btn.text = "OPEN STALL"
	open_stall_btn.custom_minimum_size = Vector2(160, 44)
	open_stall_btn.pressed.connect(_on_open_stall_confirmed)
	bot_actions.add_child(open_stall_btn)

	var close_btn := Button.new()
	close_btn.text = "CLOSE"
	close_btn.custom_minimum_size = Vector2(120, 44)
	close_btn.pressed.connect(close)
	bot_actions.add_child(close_btn)


func _refresh_ui() -> void:
	_title_label.text = stall_title
	_owner_controls.visible = is_owner
	var open_btn := _panel.find_child("OpenStallBtn", true, false)
	if open_btn:
		open_btn.visible = is_owner

	for c in _items_container.get_children():
		c.queue_free()

	if stall_items.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No items listed for sale."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_items_container.add_child(empty_lbl)
		return

	for it in stall_items:
		var row := PanelContainer.new()
		var rstyle := StyleBoxFlat.new()
		rstyle.bg_color = Color(0.18, 0.20, 0.28, 0.9)
		rstyle.set_corner_radius_all(6)
		row.add_theme_stylebox_override("panel", rstyle)
		_items_container.add_child(row)

		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 12)
		row.add_child(hbox)

		var iname := str(it.get("name", "Item"))
		var iprice := int(it.get("price", 100))

		var name_lbl := Label.new()
		name_lbl.text = iname
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(name_lbl)

		var price_lbl := Label.new()
		price_lbl.text = "%s Gold" % GameState.format_number(iprice)
		price_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		hbox.add_child(price_lbl)

		if not is_owner:
			var buy_btn := Button.new()
			buy_btn.text = "BUY"
			buy_btn.custom_minimum_size = Vector2(90, 38)
			buy_btn.disabled = GameState.gold < iprice
			buy_btn.pressed.connect(_on_buy_clicked.bind(iname, iprice))
			hbox.add_child(buy_btn)
		else:
			var rm_btn := Button.new()
			rm_btn.text = "Remove"
			rm_btn.custom_minimum_size = Vector2(80, 36)
			rm_btn.pressed.connect(func():
				stall_items.erase(it)
				_refresh_ui()
			)
			hbox.add_child(rm_btn)


func _on_add_item_pressed() -> void:
	if stall_items.size() >= 4:
		GameState.message.emit("Stall holds a maximum of 4 items.")
		return
	for inv in GameState.inventory:
		var already := false
		for listed in stall_items:
			if listed.get("name") == inv.name:
				already = true
				break
		if not already and not inv.get("locked", false):
			var data := GameData.item(inv.name)
			var base_price := int(data.get("price", 500))
			stall_items.append({"name": inv.name, "price": base_price, "qty": 1})
			_refresh_ui()
			return
	GameState.message.emit("No more tradable items in inventory.")


func _on_open_stall_confirmed() -> void:
	if stall_items.is_empty():
		GameState.message.emit("Add at least 1 item to open a stall.")
		return
	var title := _title_input.text.strip_edges()
	if title.is_empty():
		title = "%s's Shop" % GameState.player_name
	Network.open_stall(title, stall_items)
	GameState.message.emit("Street Stall opened! Other players can now browse your shop.")
	close()


func _on_buy_clicked(item_name: String, price: int) -> void:
	if GameState.gold < price:
		GameState.message.emit("Not enough gold!")
		return
	Network.buy_from_stall(seller_id, item_name)


func _on_stall_buy_completed(success: bool, item: Dictionary, price: int, error: String) -> void:
	if not success:
		GameState.message.emit("Purchase failed: %s" % error)
		return
	GameState.gold = maxi(0, GameState.gold - price)
	GameState.add_inventory_item(str(item.get("name")), 1)
	GameState.gold_changed.emit()
	GameState.inventory_changed.emit()
	GameState.save_game()
	GameState.message.emit("Bought %s for %s Gold!" % [item.get("name"), GameState.format_number(price)])
	close()


func _on_stall_item_sold(buyer_name: String, item: Dictionary, price: int) -> void:
	GameState.remove_inventory_item(str(item.get("name")), 1)
	GameState.gold += price
	GameState.gold_changed.emit()
	GameState.inventory_changed.emit()
	GameState.save_game()
	GameState.message.emit("%s bought your %s for %s Gold!" % [buyer_name, item.get("name"), GameState.format_number(price)])
