extends Node
## Reproduces the "two accounts" problem: create an account, then create a
## second account, then log into each of them and see which hero shows up.
##
## Run: Godot --headless --path . res://tools/two_accounts_test.tscn
## Or use server/test/run_godot_online_test.ps1, which boots a throwaway server.

const MAIN_MENU_SCENE := "res://Emberfall/scenes/interface/main_menu.tscn"
const TEST_SAVE := "user://two_accounts_test_save.json"
const TEST_PENDING := "user://two_accounts_test_pending.json"
const PASSWORD := "testpassword"

var _failures := 0
var _finished := false


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		print("FAIL: ", message)


func _info(message: String) -> void:
	print("INFO: ", message)


func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	print("FAIL: ", message)
	_cleanup()
	get_tree().quit(1)


func _cleanup() -> void:
	GameState.online_mode = false
	GameState.save_path = GameState.SAVE_PATH
	GameState.pending_save_path = GameState.PENDING_SAVE_PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PENDING))
	Api.logout()


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void: _fail("test timed out"))

	Api.auth_failed.connect(func(error: String) -> void: _info("auth failed: " + error))
	Api.request_failed.connect(func(error: String) -> void: _info("request failed: " + error))

	if OS.get_environment("EMBERFALL_API_URL").is_empty():
		Api.set_base_url("http://127.0.0.1:7599/api")

	GameState.online_mode = false
	GameState.save_path = TEST_SAVE
	GameState.pending_save_path = TEST_PENDING
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PENDING))

	await get_tree().process_frame
	await _run()


func _menu() -> Node:
	var scene: Node = get_tree().current_scene
	if scene != null and scene.has_method("_on_create_account_confirm"):
		return scene
	return null


func _wait_for_menu(frames: int = 600) -> Node:
	for _i in range(frames):
		await get_tree().process_frame
		var menu := _menu()
		if menu != null:
			return menu
	return null


func _wait_for_world(frames: int = 1200) -> bool:
	for _i in range(frames):
		await get_tree().process_frame
		var scene: Node = get_tree().current_scene
		if scene != null and scene.name == "World":
			return true
	return false


func _wait_for_character_list(menu: Node, frames: int = 600) -> bool:
	for _i in range(frames):
		await get_tree().process_frame
		if menu._chars_panel != null and menu._chars_panel.visible:
			return true
	return false


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## Registers an account through the real create-account panel.
func _register(menu: Node, user: String) -> void:
	menu._on_create_account()
	menu._acct_user_input.text = user
	menu._acct_pass_input.text = PASSWORD
	menu._acct_pass_confirm_input.text = PASSWORD
	menu._on_create_account_confirm()


## Signs in through the real sign-in card.
func _login(menu: Node, user: String) -> void:
	menu.username_input.text = user
	menu.password_input.text = PASSWORD
	menu._on_login()


## The names shown in the character list.
func _listed_names(menu: Node) -> Array:
	var names: Array = []
	for child in menu._chars_list_box.get_children():
		var label := _first_label(child)
		if label != null:
			names.append(label.text)
	return names


func _first_label(node: Node) -> Label:
	if node is Label:
		return node
	for child in node.get_children():
		var found := _first_label(child)
		if found != null:
			return found
	return null


## Goes back to the menu and ends the session.
func _back_to_menu_and_log_out() -> Node:
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	var menu := await _wait_for_menu()
	if menu != null:
		menu._on_logout()
		await _wait_frames(10)
	return menu


func _run() -> void:
	# ---- First account: Bento ----
	var menu := await _wait_for_menu()
	if menu == null:
		_fail("the main menu never appeared")
		return

	_register(menu, "Bento")
	if not await _wait_for_world():
		_fail("registering Bento never reached the world")
		return
	_check(GameState.player_name == "Bento", "the first account plays the hero named after it")
	_info("Bento: hero=%s level=%d gold=%d" % [GameState.player_name, GameState.level, GameState.gold])

	# Make the local save clearly different so we can see which one is used.
	GameState.gold = 123456
	GameState.level = 42
	GameState.save_game()
	await _wait_frames(10)

	# ---- Second account: Bento1, created while Bento is the active hero ----
	menu = await _back_to_menu_and_log_out()
	if menu == null:
		_fail("the main menu did not come back")
		return
	_register(menu, "Bento1")
	if not await _wait_for_world():
		_fail("registering Bento1 never reached the world")
		return
	_info("Bento1: hero=%s level=%d gold=%d" % [GameState.player_name, GameState.level, GameState.gold])
	_check(
		GameState.level != 42 or GameState.gold != 123456,
		"a new account does not inherit the previous account's progress",
	)
	_check(GameState.player_name != "Bento", "a new account does not reuse the previous hero name")

	# ---- Log into Bento1 ----
	menu = await _back_to_menu_and_log_out()
	if menu == null:
		_fail("the main menu did not come back")
		return
	_login(menu, "Bento1")
	var listed := false
	for _i in range(600):
		await get_tree().process_frame
		if menu._chars_panel != null and menu._chars_panel.visible:
			listed = true
			break
	_info("Bento1 login -> account=%s characters=%s" % [Api.username, str(_listed_names(menu))])
	if not listed:
		_fail("logging into Bento1 did not show the character list")
		return
	_check(Api.username == "Bento1", "logging in as Bento1 keeps that account")
	var names := _listed_names(menu)
	_check(names.size() == 1 and str(names[0]) == "Bento1", "Bento1 sees only its own hero", str(names))

	# ---- Log into Bento ----
	menu = await _back_to_menu_and_log_out()
	if menu == null:
		_fail("the main menu did not come back")
		return
	_login(menu, "Bento")
	listed = false
	for _i in range(600):
		await get_tree().process_frame
		if menu._chars_panel != null and menu._chars_panel.visible:
			listed = true
			break
	_info("Bento login -> account=%s characters=%s" % [Api.username, str(_listed_names(menu))])
	if not listed:
		_fail("logging into Bento did not show the character list")
		return
	_check(Api.username == "Bento", "logging in as Bento keeps that account")
	names = _listed_names(menu)
	_check(names.size() == 1 and str(names[0]) == "Bento", "Bento sees only its own hero", str(names))

	if _finished:
		return
	_finished = true
	_cleanup()
	print("CHECKS COMPLETE, FAILURES: ", _failures)
	get_tree().quit(0 if _failures == 0 else 1)
