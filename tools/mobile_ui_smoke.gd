extends Node
## Temporary headless smoke test for desktop/mobile HUD interaction paths.
## Run: godot --headless --path . res://tools/_mobile_ui_smoke.tscn

var _failures := 0

class MobileHUD extends HUD:
	func _is_mobile_platform() -> bool:
		return true

class DummyStage extends Node:
	var stage_number := 1


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		print("FAIL: ", message)


func _mouse_event(button_index: int) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	event.position = Vector2(10, 10)
	return event


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null


func _first_inventory_button(hud: HUD) -> Button:
	if hud.inventory_grid == null or hud.inventory_grid.get_child_count() == 0:
		return null
	return hud.inventory_grid.get_child(0) as Button


func _ready() -> void:
	await get_tree().process_frame

	var stage := DummyStage.new()
	add_child(stage)

	# ---------------- Mobile ----------------
	var mobile := MobileHUD.new()
	add_child(mobile)
	mobile.bind(stage, null)

	_check(mobile._touch_controls != null, "mobile: TouchControls spawned")
	_check(mobile._touch_controls != null and mobile._touch_controls.visible,
		"mobile: TouchControls visible during gameplay")
	var mobile_pause := _find_button(mobile.root, "Pause")
	_check(mobile_pause != null and mobile_pause.visible, "mobile: Pause button visible")

	mobile._toggle_inventory()
	_check(mobile.inventory_panel.visible, "mobile: inventory opened from nav")
	_check(mobile._touch_controls != null and not mobile._touch_controls.visible,
		"mobile: TouchControls hidden while inventory open")
	_check(mobile._inventory_hint().find("Tap an item") >= 0, "mobile: touch hint text used")
	_check(mobile._compare_label != null and mobile._compare_label.text.find("Tap an item") >= 0,
		"mobile: compare label uses touch wording")

	var mobile_item := _first_inventory_button(mobile)
	_check(mobile_item != null, "mobile: inventory has an item to tap")
	if mobile_item != null:
		mobile_item.gui_input.emit(_mouse_event(MOUSE_BUTTON_LEFT))
		var item_name := str(mobile_item.get_meta("item_name", ""))
		_check(mobile._item_context_popup.visible, "mobile: tap opens context action menu")
		_check(mobile._context_item == item_name, "mobile: context menu targets tapped item")
		_check(mobile._compare_label.text.find(item_name) >= 0,
			"mobile: tap still shows item comparison")
		var use_btn := mobile._item_context_popup.get_node_or_null("VBoxContainer/Use") as Button
		_check(use_btn != null and use_btn.visible, "mobile: Use action visible for consumable")

	mobile._close_panels()
	_check(not mobile.inventory_panel.visible, "mobile: inventory closed")
	_check(not mobile._item_context_popup.visible, "mobile: context menu closed")
	_check(mobile._touch_controls != null and mobile._touch_controls.visible,
		"mobile: TouchControls restored after closing panel")

	mobile._toggle_pause_panel()
	_check(mobile.pause_panel.visible, "mobile: Pause button path opens pause panel")
	_check(mobile._touch_controls != null and not mobile._touch_controls.visible,
		"mobile: TouchControls hidden while pause open")
	mobile._toggle_pause_panel()
	_check(not mobile.pause_panel.visible, "mobile: Pause button path closes pause panel")
	_check(mobile._touch_controls != null and mobile._touch_controls.visible,
		"mobile: TouchControls restored after pause closes")

	# ---------------- Desktop ----------------
	var desktop := HUD.new()
	add_child(desktop)
	desktop.bind(stage, null)

	_check(desktop._touch_controls == null, "desktop: no TouchControls")
	var desktop_pause := _find_button(desktop.root, "Pause")
	_check(desktop_pause == null or not desktop_pause.visible, "desktop: Pause nav button hidden")

	desktop._toggle_inventory()
	_check(desktop.inventory_panel.visible, "desktop: inventory opens")
	_check(desktop._inventory_hint() == "Left-click: compare  \u00b7  Right-click: menu",
		"desktop: original backpack hint unchanged")

	var desktop_item := _first_inventory_button(desktop)
	_check(desktop_item != null, "desktop: inventory has an item")
	if desktop_item != null:
		var item_name := str(desktop_item.get_meta("item_name", ""))
		desktop_item.gui_input.emit(_mouse_event(MOUSE_BUTTON_LEFT))
		_check(not desktop._item_context_popup.visible,
			"desktop: left-click does not open context menu")
		_check(desktop._selected_item == item_name, "desktop: left-click selects/compares item")

		desktop_item.gui_input.emit(_mouse_event(MOUSE_BUTTON_RIGHT))
		_check(desktop._item_context_popup.visible,
			"desktop: right-click opens context menu")
		_check(desktop._context_item == item_name, "desktop: right-click targets item")

	desktop._close_panels()

	var esc_event := InputEventAction.new()
	esc_event.action = "pause"
	esc_event.pressed = true
	desktop._unhandled_input(esc_event)
	_check(desktop.pause_panel.visible, "desktop: Esc opens pause panel")
	desktop._unhandled_input(esc_event)
	_check(not desktop.pause_panel.visible, "desktop: Esc closes pause panel")

	print("CHECKS COMPLETE, FAILURES: ", _failures)
	get_tree().quit(0 if _failures == 0 else 1)
