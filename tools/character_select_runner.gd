extends Node
## Drives the main menu UI for tools/character_select_test.tscn. Lives outside
## the changing scene so it survives the transitions between menu and world.

const MAIN_MENU_SCENE := "res://Emberfall/scenes/interface/main_menu.tscn"
const TEST_SAVE := "user://character_select_test_save.json"
const TEST_PENDING := "user://character_select_test_pending.json"

## The test creates accounts, so it may only ever talk to the throwaway server
## that server/test/run_godot_online_test.ps1 starts.
const TEST_API_URL := "http://127.0.0.1:7599/api"

var _failures := 0
var _finished := false


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		print("FAIL: ", message)


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
	get_tree().create_timer(60.0).timeout.connect(func() -> void: _fail("test timed out"))

	Api.auth_failed.connect(func(error: String) -> void: _fail("auth failed: " + error))
	Api.request_failed.connect(func(error: String) -> void: _fail("request failed: " + error))

	# This test creates accounts. Pointed at the real server it would fill the
	# database with test rows, so it refuses to run anywhere but the throwaway
	# test server.
	var url := OS.get_environment("EMBERFALL_API_URL").strip_edges()
	if url.is_empty():
		url = TEST_API_URL
	if not url.begins_with("http://127.0.0.1:7599"):
		_fail(
			"this test only runs against the throwaway server %s (got %s). Start it with server/test/run_godot_online_test.ps1" % [TEST_API_URL, url],
		)
		return
	Api.set_base_url(url)

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


func _run() -> void:
	var menu := await _wait_for_menu()
	if menu == null:
		_fail("the main menu never appeared")
		return

	# ---- Register through the real UI ----
	var user := "ui_%d%d" % [int(Time.get_unix_time_from_system()) % 100000, randi() % 100000]
	menu._acct_user_input.text = user
	menu._acct_pass_input.text = "testpassword"
	menu._acct_pass_confirm_input.text = "testpassword"
	menu._on_create_account_confirm()

	if not await _wait_for_world():
		_fail("registration never reached the world")
		return
	_check(GameState.online_mode, "the session is online after registering")
	_check(Api.character_id > 0, "a character was created for the new account")
	var first_character_id := Api.character_id

	# ---- Back to the menu: the character list is shown straight away ----
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	menu = await _wait_for_menu()
	if menu == null:
		_fail("the main menu did not come back")
		return
	await _wait_for_character_list(menu)
	_check(menu._chars_panel != null and menu._chars_panel.visible, "the character list opens without signing in again")
	_check(menu._chars_list_box.get_child_count() == 1, "the character list shows the account's character")

	# ---- Create a second character ----
	menu._show_new_character_form(true)
	_check(menu._new_char_box.visible, "the new character form opens")
	menu._new_char_name_input.text = user + "_two"
	menu._new_char_class_option.selected = 1
	menu._on_create_new_character()
	if not await _wait_for_world():
		_fail("the new character never reached the world")
		return
	_check(GameState.player_name == user + "_two", "the new character is the one that is played")
	_check(GameState.player_class == "Archer", "the new character keeps the chosen class")
	var second_character_id := Api.character_id
	_check(second_character_id != first_character_id, "the new character is a separate character")

	# ---- Back to the menu and delete the second character ----
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	menu = await _wait_for_menu()
	if menu == null:
		_fail("the main menu did not come back")
		return
	await _wait_for_character_list(menu)
	_check(menu._chars_list_box.get_child_count() == 2, "the character list shows both characters")

	menu._on_delete_character_request(second_character_id, user + "_two")
	_check(menu._delete_confirm_box.visible, "deleting asks for a confirmation")
	menu._on_delete_confirm()
	for _i in range(600):
		await get_tree().process_frame
		if menu._chars_list_box.get_child_count() == 1:
			break
	_check(menu._chars_list_box.get_child_count() == 1, "the deleted character disappears from the list")

	# ---- Logging out returns to the sign-in card ----
	menu._on_logout()
	_check(menu._chars_panel == null or not menu._chars_panel.visible, "logging out closes the character list")
	_check(menu._signin_card != null and menu._signin_card.visible, "logging out shows the sign-in card again")
	_check(not Api.has_session(), "logging out clears the session token")

	if _finished:
		return
	_finished = true
	_cleanup()
	print("CHECKS COMPLETE, FAILURES: ", _failures)
	get_tree().quit(0 if _failures == 0 else 1)
