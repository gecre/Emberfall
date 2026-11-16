extends Control
class_name MainMenu

## Title screen styled like Helmet Heroes: login then play. No single-player,
## no multiplayer. On successful sign-in the existing GameState save (stats and
## items) is loaded so the character carries over.

const WORLD_SCENE := "res://Emberfall/scenes/world/world.tscn"

## Where remembered credentials are stored so they persist across launches.
const REMEMBER_FILE := "user://emberfall_remember.json"

## Classes a new character can be created with.
const CHARACTER_CLASSES := ["Warrior", "Archer", "Mage", "Cowboy"]

var username_input: LineEdit = null
var password_input: LineEdit = null
var remember_checkbox: CheckButton = null
var login_status_label: Label = null
## Server address editor, hidden until the player opens it.
var _server_button: Button = null
var _server_box: VBoxContainer = null
var _server_input: LineEdit = null
var _server_hint: Label = null
## Guards against double scene changes when several API signals fire.
var _entering_world := false
## The sign-in card, hidden while the character list is open.
var _signin_card: PanelContainer = null

## Drag state for the account creation panel.
var _drag_active := false
var _drag_panel: PanelContainer = null
var _drag_start: Vector2 = Vector2.ZERO
var _drag_ol: float = 0.0
var _drag_ot: float = 0.0
var _drag_or: float = 0.0
var _drag_ob: float = 0.0

## Account creation UI (draggable register menu).
var _acct_panel: Control = null
var _acct_user_input: LineEdit = null
var _acct_pass_input: LineEdit = null
var _acct_pass_confirm_input: LineEdit = null
var _acct_status_label: Label = null
## True while the register request is on its way.
var _acct_pending := false

## Character selection UI (shown after a successful login).
var _chars_panel: Control = null
var _chars_list_box: VBoxContainer = null
var _chars_status_label: Label = null
var _new_char_box: VBoxContainer = null
var _new_char_name_input: LineEdit = null
var _new_char_class_option: OptionButton = null
var _new_char_status_label: Label = null
var _delete_confirm_box: HBoxContainer = null
var _delete_confirm_label: Label = null
## Character id waiting for a delete confirmation (0 = none).
var _pending_delete_id := 0
## Character id whose name is shown in the delete confirmation.
var _pending_delete_name := ""
## Alternative names used when the automatic character name is already taken.
var _auto_name_candidates: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_build_account_creation()
	_build_character_select()
	_load_remembered()
	Api.logged_in.connect(_on_login_success)
	Api.registered.connect(_on_register_success)
	Api.auth_failed.connect(_on_auth_failed)
	Api.characters_loaded.connect(_on_characters_loaded)
	Api.character_loaded.connect(_on_character_ready)
	Api.character_created.connect(_on_character_ready)
	Api.character_create_failed.connect(_on_character_create_failed)
	Api.character_deleted.connect(_on_character_deleted)
	Api.request_failed.connect(_on_request_failed)
	Api.server_discovered.connect(_on_server_discovered)
	Api.discovery_failed.connect(_on_discovery_failed)
	queue_redraw()
	# Coming back from the world keeps the session, so go straight to the
	# character list instead of asking for the password again.
	if Api.has_session():
		login_status_label.text = "Loading character..."
		Api.list_characters()


func _style(color: Color, radius: int = 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	return style


## Dark background style for username/password input fields.
func _input_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.14, 0.16, 1.0)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.border_color = Color(0.3, 0.3, 0.35, 1.0)
	style.set_border_width_all(1)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	return style


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


func _make_button(text: String, width: float = 320.0) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(width, 44)
	button.add_theme_font_size_override("font_size", 18)
	return button


func _build_ui() -> void:
	# ---- Background: warm radial glow ----
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.20, 0.09, 0.05), Color(0.05, 0.04, 0.06)])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill = GradientTexture2D.FILL_RADIAL
	grad_tex.fill_from = Vector2(0.5, 0.3)
	grad_tex.fill_to = Vector2(1.0, 1.0)
	var bg := TextureRect.new()
	bg.texture = grad_tex
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center_container := CenterContainer.new()
	center_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center_container)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	center_container.add_child(column)

	# ---- Header ----
	var title := _make_label("EmberFalls", 64, Color(1.0, 0.5, 0.2))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.35, 0.1, 0.02, 0.9))
	title.add_theme_constant_override("outline_size", 10)
	title.add_theme_color_override("font_shadow_color", Color(1.0, 0.4, 0.1, 0.35))
	title.add_theme_constant_override("shadow_offset_y", 4)
	column.add_child(title)

	var subtitle := _make_label("THE ADVENTURE BEGINS", 14, Color(0.75, 0.7, 0.68))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 18)
	column.add_child(gap)

	# ---- Card ----
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(400, 0)
	card.add_theme_stylebox_override("panel", _box(Color(0.09, 0.09, 0.11, 0.92), Color(0.25, 0.2, 0.18), 1, 14, Vector2(28, 26)))
	column.add_child(card)
	_signin_card = card

	var form := VBoxContainer.new()
	form.add_theme_constant_override("separation", 12)
	card.add_child(form)

	var signin_label := _make_label("Sign in", 20, Color(1, 1, 1))
	form.add_child(signin_label)

	username_input = _make_input("username")
	form.add_child(username_input)

	password_input = _make_input("password")
	password_input.secret = true
	form.add_child(password_input)
	username_input.text_submitted.connect(func(_t: String) -> void: password_input.grab_focus())
	password_input.text_submitted.connect(func(_t: String) -> void: _on_login())

	# ---- Remember me / Forgot password ----
	var row := HBoxContainer.new()
	form.add_child(row)

	remember_checkbox = CheckButton.new()
	remember_checkbox.text = "Remember me"
	remember_checkbox.add_theme_font_size_override("font_size", 13)
	remember_checkbox.add_theme_color_override("font_color", Color(0.75, 0.75, 0.78))
	row.add_child(remember_checkbox)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var forgot := Button.new()
	forgot.text = "Forgot password?"
	forgot.flat = true
	forgot.add_theme_font_size_override("font_size", 13)
	_style_button(forgot, "ghost")
	forgot.pressed.connect(func() -> void: login_status_label.text = "Password reset: contact support.")
	row.add_child(forgot)

	# ---- Primary action ----
	var signin_btn := Button.new()
	signin_btn.text = "SIGN IN"
	signin_btn.custom_minimum_size = Vector2(0, 46)
	signin_btn.add_theme_font_size_override("font_size", 16)
	_style_button(signin_btn, "primary")
	signin_btn.pressed.connect(_on_login)
	form.add_child(signin_btn)

	login_status_label = _make_label("", 13, Color(1.0, 0.55, 0.45))
	login_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	form.add_child(login_status_label)

	# ---- Divider ----
	var divider := HSeparator.new()
	divider.modulate = Color(1, 1, 1, 0.15)
	form.add_child(divider)

	# ---- Secondary actions ----
	var create_acct_btn := Button.new()
	create_acct_btn.text = "CREATE ACCOUNT"
	create_acct_btn.custom_minimum_size = Vector2(0, 42)
	create_acct_btn.add_theme_font_size_override("font_size", 14)
	_style_button(create_acct_btn, "secondary")
	create_acct_btn.pressed.connect(_on_create_account)
	form.add_child(create_acct_btn)

	var offline_btn := Button.new()
	offline_btn.text = "PLAY OFFLINE"
	offline_btn.custom_minimum_size = Vector2(0, 36)
	offline_btn.add_theme_font_size_override("font_size", 13)
	_style_button(offline_btn, "ghost")
	offline_btn.pressed.connect(_on_play_offline)
	form.add_child(offline_btn)

	# ---- Server address ----
	# A phone cannot reach 127.0.0.1, so the address has to be editable.
	_server_button = Button.new()
	_server_button.text = "Server: %s" % Api.base_url
	_server_button.clip_text = true
	_server_button.add_theme_font_size_override("font_size", 11)
	_style_button(_server_button, "secondary")
	_server_button.pressed.connect(_toggle_server_editor)
	form.add_child(_server_button)

	_server_box = VBoxContainer.new()
	_server_box.add_theme_constant_override("separation", 6)
	_server_box.visible = false
	form.add_child(_server_box)

	var server_row := HBoxContainer.new()
	server_row.add_theme_constant_override("separation", 8)
	_server_box.add_child(server_row)

	_server_input = _make_input("http://192.168.1.10:7575/api")
	_server_input.text = Api.base_url
	_server_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	server_row.add_child(_server_input)

	var save_server_btn := Button.new()
	save_server_btn.text = "SAVE"
	save_server_btn.custom_minimum_size = Vector2(0, 44)
	save_server_btn.add_theme_font_size_override("font_size", 13)
	_style_button(save_server_btn, "secondary")
	save_server_btn.pressed.connect(_on_save_server)
	server_row.add_child(save_server_btn)

	var reset_server_btn := Button.new()
	reset_server_btn.text = "DEFAULT"
	reset_server_btn.custom_minimum_size = Vector2(0, 44)
	reset_server_btn.add_theme_font_size_override("font_size", 13)
	_style_button(reset_server_btn, "ghost")
	reset_server_btn.pressed.connect(_on_reset_server)
	server_row.add_child(reset_server_btn)

	var find_server_btn := Button.new()
	find_server_btn.text = "FIND SERVER"
	find_server_btn.custom_minimum_size = Vector2(0, 44)
	find_server_btn.add_theme_font_size_override("font_size", 13)
	_style_button(find_server_btn, "ghost")
	find_server_btn.pressed.connect(_on_find_server)
	server_row.add_child(find_server_btn)

	_server_hint = _make_label("", 11, Color(0.5, 0.5, 0.56))
	_server_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_server_box.add_child(_server_hint)

	var links := HBoxContainer.new()
	links.alignment = BoxContainer.ALIGNMENT_CENTER
	links.add_theme_constant_override("separation", 24)
	form.add_child(links)

	for label_text in ["Credits", "Options"]:
		var b := Button.new()
		b.text = label_text
		b.flat = true
		b.add_theme_font_size_override("font_size", 13)
		_style_button(b, "ghost")
		links.add_child(b)


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


func _make_input(placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.custom_minimum_size = Vector2(0, 44)
	le.add_theme_font_size_override("font_size", 16)
	le.add_theme_color_override("caret_color", Color(1.0, 0.5, 0.2))
	le.add_theme_color_override("font_placeholder_color", Color(0.5, 0.5, 0.55))
	le.add_theme_stylebox_override("normal", _box(Color(0.06, 0.06, 0.08), Color(0.22, 0.22, 0.26), 1, 8, Vector2(14, 8)))
	le.add_theme_stylebox_override("focus", _box(Color(0.06, 0.06, 0.08), Color(1.0, 0.5, 0.2), 2, 8, Vector2(14, 8)))
	return le


func _style_button(btn: Button, kind: String) -> void:
	var normal: StyleBoxFlat
	var hover: StyleBoxFlat
	var pressed: StyleBoxFlat
	var font := Color(1, 1, 1)
	var font_hover := Color(1, 1, 1)
	match kind:
		"primary":
			normal = _box(Color(0.93, 0.42, 0.12), Color(0, 0, 0, 0), 0, 8)
			hover = _box(Color(1.0, 0.52, 0.2), Color(0, 0, 0, 0), 0, 8)
			pressed = _box(Color(0.75, 0.32, 0.08), Color(0, 0, 0, 0), 0, 8)
		"secondary":
			normal = _box(Color(0.13, 0.13, 0.16), Color(0.3, 0.3, 0.35), 1, 8)
			hover = _box(Color(0.17, 0.15, 0.16), Color(1.0, 0.5, 0.2), 1, 8)
			pressed = _box(Color(0.1, 0.1, 0.12), Color(0.8, 0.4, 0.15), 1, 8)
			font = Color(0.9, 0.9, 0.92)
		_: # ghost
			normal = _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 6, Vector2(6, 4))
			hover = normal
			pressed = normal
			font = Color(0.6, 0.6, 0.66)
			font_hover = Color(1.0, 0.55, 0.25)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("focus", hover)
	btn.add_theme_color_override("font_color", font)
	btn.add_theme_color_override("font_hover_color", font_hover)
	btn.add_theme_color_override("font_pressed_color", font_hover)
	btn.add_theme_color_override("font_focus_color", font)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


## Loads the remembered username (if remember me was checked last time).
func _load_remembered() -> void:
	var path := REMEMBER_FILE
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	username_input.text = str(data.get("username", ""))
	remember_checkbox.button_pressed = str(data.get("remember", false)).to_lower() == "true"
	# Older builds stored the password in plain text; rewrite the file without it.
	if data.has("password"):
		_save_remembered()


## Saves the remembered username (no password) when remember me is checked,
## clears when unchecked. Passwords are never stored locally.
func _save_remembered() -> void:
	var data: Dictionary = {
		"remember": remember_checkbox.button_pressed,
		"username": username_input.text.strip_edges(),
	}
	var file := FileAccess.open(REMEMBER_FILE, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()


func _on_login() -> void:
	var user := username_input.text.strip_edges()
	var pwd := password_input.text
	if user == "" or pwd == "":
		login_status_label.text = "Enter username and password."
		return
	login_status_label.text = "Signing in..."
	_entering_world = false
	# Credentials go to the account server; only a session token is kept.
	Api.login(user, pwd)


## Shows or hides the server address editor.
func _toggle_server_editor() -> void:
	_server_box.visible = not _server_box.visible
	if not _server_box.visible:
		return
	_server_input.text = Api.base_url
	_server_input.grab_focus()
	_server_hint.text = _server_help_text()


## Stores the typed address and uses it from now on.
func _on_save_server() -> void:
	var url := _server_input.text.strip_edges()
	if url.is_empty():
		_server_hint.text = "Enter the address of the server, for example http://192.168.1.10:7575/api"
		return
	Api.set_base_url(url)
	Api.save_base_url()
	_server_button.text = "Server: %s" % Api.base_url
	_server_box.visible = false
	_server_hint.text = ""


## Goes back to the built-in address (this computer).
func _on_reset_server() -> void:
	Api.set_base_url(Api.DEFAULT_BASE_URL)
	Api.save_base_url()
	_server_input.text = Api.base_url
	_server_button.text = "Server: %s" % Api.base_url
	_server_hint.text = _server_help_text()


## Looks for the server on the local network.
func _on_find_server() -> void:
	_server_hint.text = "Looking for the server..."
	Api.discover_server()


## A server was found on the network.
func _on_server_discovered(url: String) -> void:
	_server_button.text = "Server: %s" % url
	_server_input.text = url
	_server_hint.text = "Found the server."


## No server answered.
func _on_discovery_failed() -> void:
	_server_hint.text = "No server found. Is it running and on this network?"


## Explains which address has to be typed.
func _server_help_text() -> String:
	return "Official server: https://emberfall-production-4a8bfbd3.up.railway.app/api"


func _on_login_success(_token: String, _account: Dictionary) -> void:
	login_status_label.text = "Loading character..."
	_save_remembered()
	Api.list_characters()


func _on_register_success(_token: String, _account: Dictionary) -> void:
	_acct_pending = false
	_show_account_creation(false)
	_acct_status_label.text = ""
	login_status_label.text = "Creating character..."
	_save_remembered()
	Api.list_characters()


## Characters are listed after a successful login. An account without a
## character gets one created from the local save so existing progress is
## carried over; accounts with characters get the selection screen.
func _on_characters_loaded(characters: Array) -> void:
	if _entering_world:
		return
	if characters.is_empty():
		_create_first_character()
		return
	_show_character_select(characters)


## Builds the account's first character from the local save (if any).
func _create_first_character() -> void:
	GameState.online_mode = false
	var has_local := GameState.has_save()
	if has_local:
		GameState.load_game()
	else:
		GameState.reset_progress(false)
	# An existing local save keeps the hero name the player picked; a fresh
	# account starts with a character named after the account.
	var preferred := GameState.player_name.strip_edges()
	if not has_local or not _is_valid_character_name(preferred) or preferred.to_lower() == Api.username.to_lower():
		preferred = _account_character_name()
	# Fall back to other names when the preferred one is already taken.
	_auto_name_candidates = []
	var fallback := _account_character_name()
	if fallback.to_lower() != preferred.to_lower():
		_auto_name_candidates.append(fallback)
	_auto_name_candidates.append("%s%d" % [fallback.substr(0, 13), Time.get_ticks_msec() % 10000])
	_send_first_character(preferred)


## A character name derived from the account name.
func _account_character_name() -> String:
	var account_name := Api.username.strip_edges()
	var cleaned := ""
	for i in range(account_name.length()):
		var ch := account_name[i]
		if _is_name_char(ch) and ch != " " and ch != "." and ch != "-":
			cleaned += ch
		else:
			cleaned += "_"
	if cleaned.length() < 2:
		cleaned = "Hero"
	if cleaned.length() > 20:
		cleaned = cleaned.substr(0, 20)
	return cleaned


## The characters the server accepts in a character name.
func _is_name_char(ch: String) -> bool:
	if ch >= "a" and ch <= "z":
		return true
	if ch >= "A" and ch <= "Z":
		return true
	if ch >= "0" and ch <= "9":
		return true
	return ch == "_" or ch == " " or ch == "." or ch == "-"


func _is_valid_character_name(name: String) -> bool:
	if name.length() < 2 or name.length() > 20:
		return false
	for i in range(name.length()):
		if not _is_name_char(name[i]):
			return false
	return true


func _send_first_character(character_name: String) -> void:
	GameState.player_name = character_name
	GameState.save_game()
	login_status_label.text = "Creating character..."
	Api.create_character(character_name, GameState.player_class, GameState.export_save_data())


## A character that failed to be created (for example because the name is
## taken) falls back to another name.
func _on_character_create_failed(error: String) -> void:
	if not _auto_name_candidates.is_empty():
		var retry := str(_auto_name_candidates.pop_front())
		_send_first_character(retry)
		return
	if _new_char_status_label != null:
		_new_char_status_label.text = error
	login_status_label.text = error


func _on_character_ready(character: Dictionary) -> void:
	if _entering_world:
		return
	_entering_world = true
	_auto_name_candidates = []
	GameState.online_mode = true
	if not GameState.apply_character(character):
		_entering_world = false
		login_status_label.text = "Could not load that character."
		return
	Network.go_online(Api.token, int(character.get("id", 0)))
	login_status_label.text = ""
	get_tree().change_scene_to_file(WORLD_SCENE)


## Local-only play: keeps the existing save file and never contacts the server.
func _on_play_offline() -> void:
	Api.logout()
	Network.go_offline()
	GameState.online_mode = false
	if GameState.has_save():
		GameState.load_game()
	else:
		GameState.reset_progress(false)
		GameState.save_game()
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_auth_failed(error: String) -> void:
	_acct_pending = false
	login_status_label.text = error
	if _acct_panel != null and _acct_panel.visible:
		_acct_status_label.text = error


func _on_request_failed(error: String) -> void:
	login_status_label.text = error
	if _acct_panel != null and _acct_panel.visible:
		_acct_status_label.text = error
	if _chars_panel != null and _chars_panel.visible:
		_chars_status_label.text = error
	# An expired session cannot recover, so drop it and let the player log in.
	if error.to_lower().contains("session"):
		Api.logout()
		_chars_panel.visible = false
		if _signin_card != null:
			_signin_card.visible = true
		login_status_label.text = "Session expired. Please sign in again."


# ---------------------------------------------------------------------------
# Character selection
# ---------------------------------------------------------------------------

## Builds the character list overlay shown after a successful login.
func _build_character_select() -> void:
	_chars_panel = Control.new()
	_chars_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_chars_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_chars_panel)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chars_panel.add_child(dim)

	var panel := _centered_panel_in(_chars_panel, Vector2(560, 600))
	panel.add_theme_stylebox_override("panel", _box(Color(0.07, 0.07, 0.09, 0.98), Color(0.28, 0.22, 0.19), 1, 14))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 20)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := _make_label("Choose your hero", 28, Color(1.0, 0.5, 0.2))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_chars_status_label = _make_label("", 13, Color(1.0, 0.55, 0.45))
	_chars_status_label.custom_minimum_size = Vector2(0, 22)
	_chars_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(_chars_status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_chars_list_box = VBoxContainer.new()
	_chars_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chars_list_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_chars_list_box)

	_build_new_character_form(vbox)
	_build_delete_confirmation(vbox)
	_build_character_footer(vbox)

	_chars_panel.visible = false


## Form used to create an additional character.
func _build_new_character_form(parent: VBoxContainer) -> void:
	_new_char_box = VBoxContainer.new()
	_new_char_box.add_theme_constant_override("separation", 8)
	_new_char_box.visible = false
	parent.add_child(_new_char_box)

	var new_title := _make_label("New character", 18, Color(1, 1, 1))
	_new_char_box.add_child(new_title)

	_new_char_name_input = _make_input("character name")
	_new_char_box.add_child(_new_char_name_input)

	_new_char_class_option = OptionButton.new()
	for cls_name in CHARACTER_CLASSES:
		_new_char_class_option.add_item(cls_name)
	_new_char_class_option.selected = 0
	_new_char_box.add_child(_new_char_class_option)

	_new_char_status_label = _make_label("", 12, Color(1.0, 0.55, 0.45))
	_new_char_status_label.custom_minimum_size = Vector2(0, 20)
	_new_char_box.add_child(_new_char_status_label)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 12)
	_new_char_box.add_child(actions)

	var create_btn := Button.new()
	create_btn.text = "CREATE"
	create_btn.custom_minimum_size = Vector2(150, 40)
	_style_button(create_btn, "primary")
	create_btn.pressed.connect(_on_create_new_character)
	actions.add_child(create_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(150, 40)
	_style_button(cancel_btn, "secondary")
	cancel_btn.pressed.connect(func() -> void: _show_new_character_form(false))
	actions.add_child(cancel_btn)


## Confirmation strip shown before a character is deleted.
func _build_delete_confirmation(parent: VBoxContainer) -> void:
	_delete_confirm_box = HBoxContainer.new()
	_delete_confirm_box.add_theme_constant_override("separation", 10)
	_delete_confirm_box.visible = false
	parent.add_child(_delete_confirm_box)

	_delete_confirm_label = _make_label("", 13, Color(1.0, 0.6, 0.5))
	_delete_confirm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_delete_confirm_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_delete_confirm_box.add_child(_delete_confirm_label)

	var confirm_btn := Button.new()
	confirm_btn.text = "YES"
	confirm_btn.custom_minimum_size = Vector2(80, 34)
	_style_button(confirm_btn, "primary")
	confirm_btn.pressed.connect(_on_delete_confirm)
	_delete_confirm_box.add_child(confirm_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "CANCEL"
	cancel_btn.custom_minimum_size = Vector2(80, 34)
	_style_button(cancel_btn, "secondary")
	cancel_btn.pressed.connect(_on_delete_cancel)
	_delete_confirm_box.add_child(cancel_btn)


## Bottom row of the character panel.
func _build_character_footer(parent: VBoxContainer) -> void:
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 12)
	parent.add_child(footer)

	var new_btn := Button.new()
	new_btn.text = "NEW CHARACTER"
	new_btn.custom_minimum_size = Vector2(200, 42)
	_style_button(new_btn, "secondary")
	new_btn.pressed.connect(func() -> void: _show_new_character_form(true))
	footer.add_child(new_btn)

	var logout_btn := Button.new()
	logout_btn.text = "LOG OUT"
	logout_btn.custom_minimum_size = Vector2(140, 42)
	_style_button(logout_btn, "ghost")
	logout_btn.pressed.connect(_on_logout)
	footer.add_child(logout_btn)


## Shows the character panel and fills it with the account's characters.
func _show_character_select(characters: Array) -> void:
	if _chars_panel == null:
		return
	_populate_character_list(characters)
	_show_new_character_form(false)
	_delete_confirm_box.visible = false
	_pending_delete_id = 0
	_chars_status_label.text = ""
	_chars_panel.visible = true
	if _signin_card != null:
		_signin_card.visible = false


## Rebuilds the list of characters inside the panel.
func _populate_character_list(characters: Array) -> void:
	for child in _chars_list_box.get_children():
		_chars_list_box.remove_child(child)
		child.queue_free()
	if characters.is_empty():
		_chars_list_box.add_child(_make_label("No characters yet.", 14, Color(0.7, 0.7, 0.74)))
		return
	for entry in characters:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		_chars_list_box.add_child(_make_character_row(entry as Dictionary))


## One row of the character list: name, progress summary and the actions.
func _make_character_row(entry: Dictionary) -> Control:
	var character_id := int(entry.get("id", 0))
	var character_name := str(entry.get("name", "Hero"))

	var row_panel := PanelContainer.new()
	row_panel.add_theme_stylebox_override("panel", _box(Color(0.12, 0.11, 0.12, 0.9), Color(0.28, 0.23, 0.2), 1, 10, Vector2(14, 10)))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row_panel.add_child(row)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)

	var name_label := _make_label(character_name, 18, Color(1.0, 0.85, 0.7))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	info.add_child(name_label)

	var detail := "Lv %d   %s   Stage %d   %s gold" % [
		int(entry.get("level", 1)),
		str(entry.get("class", "Warrior")),
		int(entry.get("current_stage", 1)),
		GameState.format_number(int(entry.get("gold", 0))),
	]
	var detail_label := _make_label(detail, 12, Color(0.68, 0.68, 0.72))
	detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	info.add_child(detail_label)

	var play_btn := Button.new()
	play_btn.text = "PLAY"
	play_btn.custom_minimum_size = Vector2(90, 38)
	_style_button(play_btn, "primary")
	play_btn.pressed.connect(func() -> void: _on_play_character(character_id))
	row.add_child(play_btn)

	var del_btn := Button.new()
	del_btn.text = "DELETE"
	del_btn.custom_minimum_size = Vector2(84, 38)
	_style_button(del_btn, "ghost")
	del_btn.pressed.connect(func() -> void: _on_delete_character_request(character_id, character_name))
	row.add_child(del_btn)

	return row_panel


## Loads the chosen character and enters the world.
func _on_play_character(character_id: int) -> void:
	if character_id <= 0:
		return
	_chars_status_label.text = "Loading..."
	Api.load_character(character_id)


func _show_new_character_form(show: bool) -> void:
	if _new_char_box == null:
		return
	_new_char_box.visible = show
	if show:
		_new_char_status_label.text = ""
		_new_char_name_input.text = ""
		_new_char_name_input.grab_focus()


## Creates an extra character for the account.
func _on_create_new_character() -> void:
	var character_name := _new_char_name_input.text.strip_edges()
	if not _is_valid_character_name(character_name):
		_new_char_status_label.text = "Name must be 2-20 letters, numbers, spaces, dots, dashes or underscores."
		return
	_new_char_status_label.text = "Creating character..."
	var character_class := _new_char_class_option.get_item_text(_new_char_class_option.selected)
	# A brand new character starts from scratch, so the state of the character
	# that is currently loaded is left untouched.
	Api.create_character(character_name, character_class, GameState.default_save_data(character_name, character_class))


func _on_delete_character_request(character_id: int, character_name: String) -> void:
	_pending_delete_id = character_id
	_pending_delete_name = character_name
	_delete_confirm_label.text = "Delete %s? This cannot be undone." % character_name
	_delete_confirm_box.visible = true


func _on_delete_confirm() -> void:
	if _pending_delete_id <= 0:
		return
	var character_id := _pending_delete_id
	_pending_delete_id = 0
	_delete_confirm_box.visible = false
	_chars_status_label.text = "Deleting..."
	Api.delete_character(character_id)


func _on_delete_cancel() -> void:
	_pending_delete_id = 0
	_delete_confirm_box.visible = false


func _on_character_deleted(_character_id: int) -> void:
	_chars_status_label.text = "Character deleted."
	Api.list_characters()


## Ends the session and returns to the sign-in card.
func _on_logout() -> void:
	Api.logout()
	Network.go_offline()
	GameState.online_mode = false
	_pending_delete_id = 0
	if _chars_panel != null:
		_chars_panel.visible = false
	if _signin_card != null:
		_signin_card.visible = true
	login_status_label.text = ""
	password_input.text = ""


## Builds the draggable "Create Account" register menu.
func _build_account_creation() -> void:
	_acct_panel = Control.new()
	_acct_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_acct_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_acct_panel)

	# Dim backdrop behind the modal
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_acct_panel.add_child(dim)

	var panel := _centered_panel_in(_acct_panel, Vector2(440, 540))
	panel.add_theme_stylebox_override("panel", _box(Color(0.09, 0.09, 0.11, 0.97), Color(0.25, 0.2, 0.18), 1, 14))

	var margin_container := MarginContainer.new()
	margin_container.add_theme_constant_override("margin_left", 28)
	margin_container.add_theme_constant_override("margin_right", 28)
	margin_container.add_theme_constant_override("margin_top", 26)
	margin_container.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin_container)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin_container.add_child(vbox)

	# ---- Header ----
	var title := _make_label("Create Account", 30, Color(1.0, 0.5, 0.2))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.35, 0.1, 0.02, 0.9))
	title.add_theme_constant_override("outline_size", 6)
	vbox.add_child(title)

	var subtitle := _make_label("JOIN THE ADVENTURE", 12, Color(0.75, 0.7, 0.68))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 14)
	vbox.add_child(gap)

	# ---- Fields ----
	var user_label := _make_label("Username", 13, Color(0.75, 0.75, 0.78))
	vbox.add_child(user_label)
	_acct_user_input = _make_input("username")
	vbox.add_child(_acct_user_input)

	var field_gap1 := Control.new()
	field_gap1.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(field_gap1)

	var pass_label := _make_label("Password", 13, Color(0.75, 0.75, 0.78))
	vbox.add_child(pass_label)
	_acct_pass_input = _make_input("password")
	_acct_pass_input.secret = true
	vbox.add_child(_acct_pass_input)

	var field_gap2 := Control.new()
	field_gap2.custom_minimum_size = Vector2(0, 6)
	vbox.add_child(field_gap2)

	var confirm_label := _make_label("Confirm password", 13, Color(0.75, 0.75, 0.78))
	vbox.add_child(confirm_label)
	_acct_pass_confirm_input = _make_input("confirm password")
	_acct_pass_confirm_input.secret = true
	vbox.add_child(_acct_pass_confirm_input)

	# Enter key flow
	_acct_user_input.text_submitted.connect(func(_t: String) -> void: _acct_pass_input.grab_focus())
	_acct_pass_input.text_submitted.connect(func(_t: String) -> void: _acct_pass_confirm_input.grab_focus())
	_acct_pass_confirm_input.text_submitted.connect(func(_t: String) -> void: _on_create_account_confirm())

	_acct_status_label = _make_label("", 13, Color(1.0, 0.55, 0.45))
	_acct_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_acct_status_label.custom_minimum_size = Vector2(0, 28)
	_acct_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(_acct_status_label)

	# ---- Actions ----
	var create_btn := Button.new()
	create_btn.text = "CREATE ACCOUNT"
	create_btn.custom_minimum_size = Vector2(0, 46)
	create_btn.add_theme_font_size_override("font_size", 16)
	_style_button(create_btn, "primary")
	create_btn.pressed.connect(_on_create_account_confirm)
	vbox.add_child(create_btn)

	var back_btn := Button.new()
	back_btn.text = "← Back to sign in"
	back_btn.flat = true
	back_btn.add_theme_font_size_override("font_size", 13)
	_style_button(back_btn, "ghost")
	back_btn.pressed.connect(func(): _show_account_creation(false))
	vbox.add_child(back_btn)

	_acct_panel.visible = false


## Centers a panel inside a parent Control and makes it draggable by its title area.
func _centered_panel_in(parent: Control, min_size: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color(0.055, 0.075, 0.08, 0.98), 14))
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -min_size.x * 0.5
	panel.offset_right = min_size.x * 0.5
	panel.offset_top = -min_size.y * 0.5
	panel.offset_bottom = min_size.y * 0.5
	panel.custom_minimum_size = min_size
	parent.add_child(panel)

	# Drag by the whole panel (title bar is the top area).
	var handle := panel
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.gui_input.connect(func(event: InputEvent) -> void:
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

	return panel


func _show_account_creation(show: bool) -> void:
	if _acct_panel == null:
		return
	_acct_panel.visible = show


func _on_create_account() -> void:
	_show_account_creation(true)


func _on_create_account_confirm() -> void:
	# Ignore a second tap while the first request is still on its way, or the
	# server answers "name taken" right after it accepted the first one.
	if _acct_pending:
		return
	var user := _acct_user_input.text.strip_edges()
	var password := _acct_pass_input.text
	var confirm := _acct_pass_confirm_input.text

	if user == "" or password == "":
		_acct_status_label.text = "Enter username and password."
		return
	if user.length() < 3 or user.length() > 20:
		_acct_status_label.text = "Username must be 3-20 characters."
		return
	if password.length() < 6:
		_acct_status_label.text = "Password must be at least 6 characters."
		return
	if password != confirm:
		_acct_status_label.text = "Passwords do not match."
		return

	_acct_pending = true
	_acct_status_label.text = "Creating account..."
	username_input.text = user
	# The server hashes the password; nothing is stored on this device.
	Api.register(user, password)
