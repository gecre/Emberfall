extends Control
class_name GameUpdater

## Launcher updater scene: checks the server for updates, downloads
## patch.pck if a newer version exists, hotloads it, and starts the game.

const MAIN_MENU_SCENE := "res://Emberfall/scenes/interface/main_menu.tscn"
const LOCAL_VERSION_PATH := "user://version.json"
const PATCH_PATH := "user://patch.pck"
const TEMP_PATCH_PATH := "user://patch_temp.pck"
const DEFAULT_VERSION := "1.0.0"

var _current_version := DEFAULT_VERSION
var _new_version := ""
var _download_url := ""
var _is_downloading := false

var _status_label: Label = null
var _progress_bar: ProgressBar = null
var _progress_label: Label = null
var _skip_button: Button = null
var _http_check: HTTPRequest = null
var _http_download: HTTPRequest = null

func _ready() -> void:
	_load_current_version()
	_mount_existing_patch()
	_build_ui()
	_start_check()

func _process(_delta: float) -> void:
	if not _is_downloading or _http_download == null:
		return
	var body_size := _http_download.get_body_size()
	var downloaded := _http_download.get_downloaded_bytes()
	if body_size > 0:
		var pct := clampf(float(downloaded) / float(body_size) * 100.0, 0.0, 100.0)
		_progress_bar.value = pct
		_progress_label.text = "%.2f MB / %.2f MB (%d%%)" % [
			downloaded / (1024.0 * 1024.0),
			body_size / (1024.0 * 1024.0),
			int(pct)
		]
	elif downloaded > 0:
		_progress_label.text = "%.2f MB downloaded" % [downloaded / (1024.0 * 1024.0)]

func _load_current_version() -> void:
	if FileAccess.file_exists(LOCAL_VERSION_PATH):
		var f := FileAccess.open(LOCAL_VERSION_PATH, FileAccess.READ)
		if f:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary and parsed.has("version"):
				_current_version = str(parsed["version"])

func _save_current_version(ver: String) -> void:
	_current_version = ver
	var f := FileAccess.open(LOCAL_VERSION_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"version": ver}))

func _mount_existing_patch() -> void:
	if FileAccess.file_exists(PATCH_PATH):
		var ok := ProjectSettings.load_resource_pack(PATCH_PATH, true)
		print("[updater] mounted existing patch: %s (success=%s)" % [PATCH_PATH, ok])

func _build_ui() -> void:
	# Background gradient matching Emberfall theme
	var bg := TextureRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.20, 0.09, 0.05), Color(0.05, 0.04, 0.06)])
	var grad_tex := GradientTexture2D.new()
	grad_tex.gradient = grad
	grad_tex.fill_from = Vector2(0.5, 0.0)
	grad_tex.fill_to = Vector2(0.5, 1.0)
	bg.texture = grad_tex
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(460, 260)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.11, 0.95)
	style.border_color = Color(0.25, 0.20, 0.18, 1.0)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.content_margin_left = 32
	style.content_margin_right = 32
	style.content_margin_top = 28
	style.content_margin_bottom = 28
	card.add_theme_stylebox_override("panel", style)
	center.add_child(card)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	card.add_child(vbox)

	var title := Label.new()
	title.text = "EmberFalls"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 42)
	title.add_theme_color_override("font_color", Color(1.0, 0.5, 0.2))
	title.add_theme_color_override("font_outline_color", Color(0.35, 0.1, 0.02, 0.9))
	title.add_theme_constant_override("outline_size", 8)
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "CHECKING FOR UPDATES"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Color(0.75, 0.70, 0.68))
	vbox.add_child(subtitle)

	_status_label = Label.new()
	_status_label.text = "Connecting to server..."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.92))
	vbox.add_child(_status_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(0, 18)
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_bar.show_percentage = false
	var pb_bg := StyleBoxFlat.new()
	pb_bg.bg_color = Color(0.06, 0.06, 0.08, 1.0)
	pb_bg.set_corner_radius_all(6)
	var pb_fg := StyleBoxFlat.new()
	pb_fg.bg_color = Color(0.95, 0.45, 0.15, 1.0)
	pb_fg.set_corner_radius_all(6)
	_progress_bar.add_theme_stylebox_override("background", pb_bg)
	_progress_bar.add_theme_stylebox_override("fill", pb_fg)
	vbox.add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.text = "Current version: v%s" % _current_version
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_progress_label.add_theme_font_size_override("font_size", 12)
	_progress_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.70))
	vbox.add_child(_progress_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)

	_skip_button = Button.new()
	_skip_button.text = "Skip"
	_skip_button.custom_minimum_size = Vector2(100, 32)
	var btn_style := StyleBoxFlat.new()
	btn_style.bg_color = Color(0.18, 0.16, 0.18, 1.0)
	btn_style.set_corner_radius_all(6)
	_skip_button.add_theme_stylebox_override("normal", btn_style)
	_skip_button.pressed.connect(_launch_game)
	btn_row.add_child(_skip_button)

func _start_check() -> void:
	_http_check = HTTPRequest.new()
	_http_check.timeout = 5.0
	add_child(_http_check)
	_http_check.request_completed.connect(_on_check_completed)

	var check_url: String = _get_api_url("/version")
	_status_label.text = "Checking for updates..."
	var err := _http_check.request(check_url)
	if err != OK:
		_status_label.text = "Update check skipped (network error)."
		_finish_and_launch(1.0)

func _on_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_status_label.text = "Starting game..."
		_finish_and_launch(0.6)
		return

	var text := body.get_string_from_utf8()
	var json: Variant = JSON.parse_string(text)
	if not (json is Dictionary):
		_status_label.text = "Starting game..."
		_finish_and_launch(0.6)
		return

	var remote_ver := str(json.get("version", "")).strip_edges()
	var pck_path := str(json.get("pck_url", "")).strip_edges()

	if not remote_ver.is_empty() and _is_newer(remote_ver, _current_version) and not pck_path.is_empty():
		_new_version = remote_ver
		_download_url = _resolve_url(pck_path)
		_status_label.text = "New update found: v%s" % _new_version
		_skip_button.text = "Cancel"
		_start_download()
	else:
		_status_label.text = "Game is up to date (v%s)." % _current_version
		_progress_bar.value = 100.0
		_finish_and_launch(0.8)

func _start_download() -> void:
	_http_download = HTTPRequest.new()
	_http_download.use_threads = true
	_http_download.download_file = TEMP_PATCH_PATH
	add_child(_http_download)
	_http_download.request_completed.connect(_on_download_completed)

	_is_downloading = true
	_status_label.text = "Downloading update v%s..." % _new_version
	var err := _http_download.request(_download_url)
	if err != OK:
		_is_downloading = false
		_status_label.text = "Download failed to start. Starting game..."
		_finish_and_launch(1.0)

func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_is_downloading = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_status_label.text = "Download failed (code %d). Starting game..." % response_code
		if FileAccess.file_exists(TEMP_PATCH_PATH):
			DirAccess.remove_absolute(TEMP_PATCH_PATH)
		_finish_and_launch(1.5)
		return

	# Replace patch file with newly downloaded patch
	if FileAccess.file_exists(PATCH_PATH):
		DirAccess.remove_absolute(PATCH_PATH)

	var ren_err := DirAccess.rename_absolute(TEMP_PATCH_PATH, PATCH_PATH)
	if ren_err != OK:
		var src := FileAccess.open(TEMP_PATCH_PATH, FileAccess.READ)
		var dst := FileAccess.open(PATCH_PATH, FileAccess.WRITE)
		if src and dst:
			dst.store_buffer(src.get_buffer(src.get_length()))
			src.close()
			dst.close()
		if FileAccess.file_exists(TEMP_PATCH_PATH):
			DirAccess.remove_absolute(TEMP_PATCH_PATH)

	_save_current_version(_new_version)
	_status_label.text = "Update installed! Loading game..."
	_progress_bar.value = 100.0

	var ok := ProjectSettings.load_resource_pack(PATCH_PATH, true)
	print("[updater] mounted new patch %s (success=%s)" % [_new_version, ok])

	_finish_and_launch(1.0)

func _finish_and_launch(delay_sec: float) -> void:
	await get_tree().create_timer(delay_sec).timeout
	_launch_game()

func _launch_game() -> void:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)

func _get_api_url(endpoint: String) -> String:
	var base := "http://localhost:3000/api"
	var tree := get_tree()
	if tree != null and tree.root.has_node("Api"):
		var api_node = tree.root.get_node("Api")
		if "base_url" in api_node and not str(api_node.base_url).is_empty():
			base = str(api_node.base_url)
	return base.rstrip("/") + endpoint

func _resolve_url(path_or_url: String) -> String:
	if path_or_url.begins_with("http://") or path_or_url.begins_with("https://"):
		return path_or_url
	var base := _get_api_url("")
	if base.ends_with("/api") and path_or_url.begins_with("/api/"):
		base = base.trim_suffix("/api")
	return base.rstrip("/") + "/" + path_or_url.lstrip("/")

func _is_newer(remote: String, local: String) -> bool:
	if remote == local:
		return false
	var r_parts := remote.split(".")
	var l_parts := local.split(".")
	var max_len := maxi(r_parts.size(), l_parts.size())
	for i in range(max_len):
		var r := int(r_parts[i]) if i < r_parts.size() else 0
		var l := int(l_parts[i]) if i < l_parts.size() else 0
		if r > l:
			return true
		elif r < l:
			return false
	return false
