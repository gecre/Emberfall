extends Control
class_name ChatBox

## In-Game Chat System for Emberfall
## Supports:
## - Global: broadcast to all online players across the server
## - Stage: local chat with players in the current stage
## - Whisper: private direct messaging with /w <player> <msg>
## - Channel filter tabs: [All], [Global], [Stage], [Whisper]
## - Quick channel cycle button: [Global] / [Stage] / [Whisper]
## - Clickable player names in chat to whisper directly
## - Slash commands: /g, /s, /w, /r, /help, /clear
## - Draggable and minimizable for mobile & desktop

const MAX_MESSAGES := 150
const DEFAULT_SIZE := Vector2(330, 160)
const MINIMIZED_SIZE := Vector2(140, 28)

var current_channel := "stage" # "stage" | "global" | "whisper"
var whisper_target := ""
var last_whisper_from := ""
var current_tab := "all" # "all" | "global" | "stage" | "whisper"

var is_minimized := false
var unread_count := 0

var _messages: Array = []

# UI Nodes
var _main_panel: PanelContainer
var _header_bar: HBoxContainer
var _title_label: Label
var _tabs_container: HBoxContainer
var _minimize_btn: Button

var _content_box: VBoxContainer
var _rich_text: RichTextLabel
var _input_row: HBoxContainer
var _channel_btn: Button
var _input_line: LineEdit
var _send_btn: Button

# Draggable state
var _dragging := false
var _drag_start := Vector2.ZERO
var _drag_initial_pos := Vector2.ZERO


func _ready() -> void:
	name = "ChatBox"
	custom_minimum_size = DEFAULT_SIZE
	size = DEFAULT_SIZE
	_build_ui()
	_connect_signals()

	# Add welcome system message
	add_system_message("Welcome to Emberfall! Type /help for chat commands.")


func _build_ui() -> void:
	_main_panel = PanelContainer.new()
	_main_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_main_panel)

	_content_box = VBoxContainer.new()
	_content_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content_box.add_theme_constant_override("separation", 4)
	_main_panel.add_child(_content_box)

	# --- Header: Title/Drag Handle, Tabs, Minimize Button ---
	_header_bar = HBoxContainer.new()
	_header_bar.add_theme_constant_override("separation", 6)
	_header_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_content_box.add_child(_header_bar)

	_title_label = Label.new()
	_title_label.text = "💬 Chat"
	_title_label.add_theme_font_size_override("font_size", 12)
	_title_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.5))
	_header_bar.add_child(_title_label)

	_tabs_container = HBoxContainer.new()
	_tabs_container.add_theme_constant_override("separation", 4)
	_tabs_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_bar.add_child(_tabs_container)

	_add_tab_button("All", "all")
	_add_tab_button("Global", "global")
	_add_tab_button("Stage", "stage")
	_add_tab_button("Whisper", "whisper")

	_minimize_btn = Button.new()
	_minimize_btn.text = "—"
	_minimize_btn.custom_minimum_size = Vector2(26, 22)
	_minimize_btn.flat = true
	_minimize_btn.add_theme_font_size_override("font_size", 11)
	_minimize_btn.pressed.connect(_toggle_minimize)
	_header_bar.add_child(_minimize_btn)

	# Setup dragging via header
	_header_bar.gui_input.connect(_on_header_gui_input)

	# --- Chat Log: RichTextLabel ---
	_rich_text = RichTextLabel.new()
	_rich_text.bbcode_enabled = true
	_rich_text.scroll_following = true
	_rich_text.selection_enabled = true
	_rich_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rich_text.add_theme_font_size_override("normal_font_size", 12)
	_rich_text.add_theme_stylebox_override("normal", _log_style())
	_rich_text.meta_clicked.connect(_on_meta_clicked)
	_content_box.add_child(_rich_text)

	# --- Input Row: Channel Button, LineEdit, Send Button ---
	_input_row = HBoxContainer.new()
	_input_row.add_theme_constant_override("separation", 4)
	_content_box.add_child(_input_row)

	_channel_btn = Button.new()
	_channel_btn.custom_minimum_size = Vector2(74, 28)
	_channel_btn.add_theme_font_size_override("font_size", 11)
	_channel_btn.pressed.connect(_cycle_channel)
	_update_channel_button()
	_input_row.add_child(_channel_btn)

	_input_line = LineEdit.new()
	_input_line.placeholder_text = "Press Enter or tap to chat... (/g, /s, /w)"
	_input_line.max_length = 140
	_input_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_line.custom_minimum_size = Vector2(0, 28)
	_input_line.add_theme_font_size_override("font_size", 12)
	_input_line.add_theme_stylebox_override("normal", _input_style())
	_input_line.add_theme_stylebox_override("focus", _input_focus_style())
	_input_line.text_submitted.connect(_on_text_submitted)
	_input_row.add_child(_input_line)

	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.custom_minimum_size = Vector2(50, 28)
	_send_btn.add_theme_font_size_override("font_size", 11)
	_style_primary_button(_send_btn)
	_send_btn.pressed.connect(_on_send_pressed)
	_input_row.add_child(_send_btn)

	_update_tab_highlights()


func _connect_signals() -> void:
	if not Network.chat_message_received.is_connected(_on_chat_message_received):
		Network.chat_message_received.connect(_on_chat_message_received)


func _add_tab_button(label: String, tab_id: String) -> void:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(46, 20)
	btn.add_theme_font_size_override("font_size", 10)
	btn.pressed.connect(func() -> void: _set_active_tab(tab_id))
	_tabs_container.add_child(btn)


func _set_active_tab(tab_id: String) -> void:
	current_tab = tab_id
	_update_tab_highlights()
	_refresh_display()


func _update_tab_highlights() -> void:
	for child in _tabs_container.get_children():
		if child is Button:
			var btn := child as Button
			var is_active := btn.text.to_lower() == current_tab
			if is_active:
				btn.add_theme_color_override("font_color", Color(1.0, 0.65, 0.2))
				btn.add_theme_stylebox_override("normal", _tab_active_style())
			else:
				btn.add_theme_color_override("font_color", Color(0.7, 0.72, 0.75))
				btn.add_theme_stylebox_override("normal", _tab_inactive_style())


func _cycle_channel() -> void:
	match current_channel:
		"stage":
			current_channel = "global"
		"global":
			if not whisper_target.is_empty():
				current_channel = "whisper"
			else:
				current_channel = "stage"
		"whisper":
			current_channel = "stage"
		_:
			current_channel = "stage"
	_update_channel_button()


func _set_channel(ch: String) -> void:
	current_channel = ch
	_update_channel_button()


func _update_channel_button() -> void:
	if _channel_btn == null:
		return
	match current_channel:
		"stage":
			_channel_btn.text = "[Stage]"
			_channel_btn.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
			_style_channel_btn(_channel_btn, Color(0.12, 0.22, 0.35, 0.9), Color(0.3, 0.6, 0.9, 0.8))
		"global":
			_channel_btn.text = "[Global]"
			_channel_btn.add_theme_color_override("font_color", Color(1.0, 0.65, 0.2))
			_style_channel_btn(_channel_btn, Color(0.32, 0.18, 0.1, 0.9), Color(0.9, 0.5, 0.15, 0.8))
		"whisper":
			var tname := whisper_target if not whisper_target.is_empty() else "Select"
			if tname.length() > 8:
				tname = tname.substr(0, 8) + ".."
			_channel_btn.text = "[W:%s]" % tname
			_channel_btn.add_theme_color_override("font_color", Color(1.0, 0.45, 0.8))
			_style_channel_btn(_channel_btn, Color(0.3, 0.12, 0.25, 0.9), Color(0.9, 0.35, 0.75, 0.8))


func _toggle_minimize() -> void:
	is_minimized = not is_minimized
	if is_minimized:
		_rich_text.visible = false
		_input_row.visible = false
		_tabs_container.visible = false
		_minimize_btn.text = "▢"
		custom_minimum_size = MINIMIZED_SIZE
		size = MINIMIZED_SIZE
		_update_minimized_title()
	else:
		_rich_text.visible = true
		_input_row.visible = true
		_tabs_container.visible = true
		_minimize_btn.text = "—"
		custom_minimum_size = DEFAULT_SIZE
		size = DEFAULT_SIZE
		unread_count = 0
		_title_label.text = "💬 Chat"
		_refresh_display()


func _update_minimized_title() -> void:
	if unread_count > 0:
		_title_label.text = "💬 Chat (%d)" % unread_count
	else:
		_title_label.text = "💬 Chat"


## Public API to toggle open/closed from HUD button
func toggle_window() -> void:
	visible = not visible
	if visible and is_minimized:
		_toggle_minimize()
	if visible:
		unread_count = 0
		_input_line.grab_focus()


## Focuses the chat input directly (e.g. when player hits Enter)
func focus_chat_input(prefill: String = "") -> void:
	if not visible:
		visible = true
	if is_minimized:
		_toggle_minimize()
	_input_line.text = prefill
	_input_line.grab_focus()
	_input_line.caret_column = _input_line.text.length()


## Sets whisper target and switches to whisper channel — called from Friends panel.
func start_whisper(target: String) -> void:
	whisper_target = target
	_set_channel("whisper")
	focus_chat_input()


func _on_header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_start = get_viewport().get_mouse_position()
			_drag_initial_pos = position
			get_viewport().set_input_as_handled()
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		var mouse_pos := get_viewport().get_mouse_position()
		position = _drag_initial_pos + (mouse_pos - _drag_start)
		get_viewport().set_input_as_handled()


func _on_text_submitted(_text: String) -> void:
	_on_send_pressed()


func _on_send_pressed() -> void:
	var raw_text := _input_line.text.strip_edges()
	_input_line.text = ""
	if raw_text.is_empty():
		_input_line.release_focus()
		return

	# Handle Slash Commands
	if raw_text.begins_with("/"):
		_handle_slash_command(raw_text)
	else:
		# Send via currently selected channel
		match current_channel:
			"stage":
				Network.send_chat(raw_text)
			"global":
				Network.send_global_chat(raw_text)
			"whisper":
				if whisper_target.is_empty():
					add_system_message("No whisper target set! Use: /w <player_name> <message>")
				else:
					Network.send_whisper(whisper_target, raw_text)

	# If playing on desktop, release focus so player can walk immediately
	_input_line.release_focus()


func _handle_slash_command(cmd_text: String) -> void:
	var parts := cmd_text.substr(1).split(" ", false, 2)
	var cmd := parts[0].to_lower() if parts.size() > 0 else ""

	match cmd:
		"help", "h", "?":
			add_system_message("--- Chat Commands ---")
			add_system_message("/s <msg> or /stage <msg> : Send to stage")
			add_system_message("/g <msg> or /global <msg> : Send to global server")
			add_system_message("/w <player> <msg> : Whisper player")
			add_system_message("/r <msg> : Reply to last whisper")
			add_system_message("/clear : Clear chat window")

		"clear":
			_messages.clear()
			_rich_text.clear()
			add_system_message("Chat cleared.")

		"s", "stage":
			if parts.size() > 1:
				Network.send_chat(parts[1])
			else:
				_set_channel("stage")
				add_system_message("Switched to [Stage] channel.")

		"g", "global":
			if parts.size() > 1:
				Network.send_global_chat(parts[1])
			else:
				_set_channel("global")
				add_system_message("Switched to [Global] channel.")

		"w", "whisper", "msg", "tell":
			if parts.size() > 1:
				var sub := parts[1].split(" ", false, 1)
				var target := sub[0]
				whisper_target = target
				_set_channel("whisper")
				if sub.size() > 1 and not sub[1].is_empty():
					Network.send_whisper(target, sub[1])
				else:
					add_system_message("Whisper target set to: %s" % target)
			else:
				add_system_message("Usage: /w <player> <message>")

		"r", "reply":
			if last_whisper_from.is_empty():
				add_system_message("No one has whispered you yet.")
			elif parts.size() > 1:
				whisper_target = last_whisper_from
				_set_channel("whisper")
				Network.send_whisper(last_whisper_from, parts[1])
			else:
				whisper_target = last_whisper_from
				_set_channel("whisper")
				add_system_message("Replying to: %s" % last_whisper_from)

		_:
			add_system_message("Unknown command '/%s'. Type /help for commands." % cmd)


func _on_chat_message_received(channel: String, sender: String, whisper_to: String, text: String) -> void:
	var my_name := GameState.player_name
	var is_self := sender.to_lower() == my_name.to_lower()

	if channel == "whisper":
		if not is_self:
			last_whisper_from = sender

	var time_dict := Time.get_time_dict_from_system()
	var time_str := "%02d:%02d" % [time_dict["hour"], time_dict["minute"]]

	var msg_entry := {
		"channel": channel,
		"sender": sender,
		"whisper_to": whisper_to,
		"text": text,
		"time": time_str,
		"is_self": is_self,
	}

	_messages.append(msg_entry)
	if _messages.size() > MAX_MESSAGES:
		_messages.pop_front()

	if is_minimized:
		unread_count += 1
		_update_minimized_title()

	# If the message matches our active filter tab, append it
	if _matches_tab(channel):
		_append_formatted_message(msg_entry)


func add_system_message(text: String) -> void:
	var time_dict := Time.get_time_dict_from_system()
	var time_str := "%02d:%02d" % [time_dict["hour"], time_dict["minute"]]

	var msg_entry := {
		"channel": "system",
		"sender": "System",
		"whisper_to": "",
		"text": text,
		"time": time_str,
		"is_self": false,
	}

	_messages.append(msg_entry)
	if _messages.size() > MAX_MESSAGES:
		_messages.pop_front()

	_append_formatted_message(msg_entry)


func _matches_tab(channel: String) -> bool:
	if current_tab == "all":
		return true
	if current_tab == channel:
		return true
	if channel == "system":
		return true
	return false


func _refresh_display() -> void:
	_rich_text.clear()
	for msg in _messages:
		if _matches_tab(str(msg.get("channel", ""))):
			_append_formatted_message(msg)


func _append_formatted_message(msg: Dictionary) -> void:
	var ch := str(msg.get("channel", "stage"))
	var sender := str(msg.get("sender", "Player"))
	var whisper_to := str(msg.get("whisper_to", ""))
	var text := str(msg.get("text", ""))
	var time_str := str(msg.get("time", ""))
	var is_self := bool(msg.get("is_self", false))

	# Clean potential bbcode injection from player messages
	text = text.replace("[", "［").replace("]", "］")

	var line := ""
	match ch:
		"global":
			line = "[color=#7f8c8d][%s][/color] [color=#ffa502][Global][/color] [url=whisper:%s][color=#ffdd59]%s:[/color][/url] [color=#ffffff]%s[/color]" % [time_str, sender, sender, text]
		"stage":
			line = "[color=#7f8c8d][%s][/color] [color=#70a1ff][Stage][/color] [url=whisper:%s][color=#eccc68]%s:[/color][/url] [color=#f1f2f6]%s[/color]" % [time_str, sender, sender, text]
		"whisper":
			if is_self:
				line = "[color=#7f8c8d][%s][/color] [color=#ff78ae][To %s]:[/color] [color=#ffeaa7]%s[/color]" % [time_str, whisper_to, text]
			else:
				line = "[color=#7f8c8d][%s][/color] [url=whisper:%s][color=#ff78ae][From %s]:[/color][/url] [color=#ffeaa7]%s[/color]" % [time_str, sender, sender, text]
		"system":
			line = "[color=#7f8c8d][%s][/color] [color=#2ed573][System][/color] [color=#dfe4ea]%s[/color]" % [time_str, text]

	_rich_text.append_text(line + "\n")


func _on_meta_clicked(meta: Variant) -> void:
	var meta_str := str(meta)
	if meta_str.begins_with("whisper:"):
		var target := meta_str.substr(8)
		if not target.is_empty() and target.to_lower() != GameState.player_name.to_lower():
			whisper_target = target
			_set_channel("whisper")
			focus_chat_input()


# --- UI Styling Helpers ---
func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.65)
	sb.border_color = Color(0.28, 0.32, 0.42, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _log_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.06, 0.40)
	sb.border_color = Color(0.2, 0.22, 0.28, 0.3)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _input_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.9)
	sb.border_color = Color(0.25, 0.25, 0.3, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _input_focus_style() -> StyleBoxFlat:
	var sb := _input_style()
	sb.border_color = Color(1.0, 0.55, 0.2, 1.0)
	sb.set_border_width_all(2)
	return sb


func _tab_active_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.2, 0.16, 0.14, 0.95)
	sb.border_color = Color(1.0, 0.55, 0.2, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


func _tab_inactive_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.13, 0.6)
	sb.border_color = Color(0.2, 0.22, 0.24, 0.4)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


func _style_channel_btn(btn: Button, bg: Color, border: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", sb)
	btn.add_theme_stylebox_override("pressed", sb)


func _style_primary_button(btn: Button) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.9, 0.42, 0.12, 1.0)
	sb.border_color = Color(1.0, 0.6, 0.2, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_color_override("font_color", Color(1, 1, 1))
