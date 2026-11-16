extends Node
## End-to-end client/server smoke test. Requires the API server to be running.
## Run: Godot --headless --path . res://tools/online_test.tscn
## Or use server/test/run_godot_online_test.ps1, which boots a throwaway server.

const TEST_SAVE := "user://online_test_save.json"
const TEST_PENDING := "user://online_test_pending.json"

## The test creates accounts, so it may only ever talk to the throwaway server
## that server/test/run_godot_online_test.ps1 starts.
const TEST_API_URL := "http://127.0.0.1:7599/api"

var _failures := 0
var _finishing := false
var _expect_save_failure := false
var _save_error := ""


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failures += 1
		print("FAIL: ", message)


func _fatal(message: String) -> void:
	if _finishing:
		return
	_finishing = true
	print("FAIL: ", message)
	get_tree().quit(1)


func _on_save_failed(error: String) -> void:
	if _expect_save_failure:
		_expect_save_failure = false
		_save_error = error
	else:
		_fatal("unexpected save failure: " + error)


func _ready() -> void:
	await get_tree().process_frame
	get_tree().create_timer(40.0).timeout.connect(func() -> void: _fatal("test timed out"))

	Api.save_failed.connect(_on_save_failed)
	Api.auth_failed.connect(func(error: String) -> void: _fatal("auth failed: " + error))
	Api.request_failed.connect(func(error: String) -> void: _fatal("request failed: " + error))

	# This test writes accounts and characters. Pointed at the real server it
	# would fill the database with test rows, so it refuses to run anywhere
	# but the throwaway test server.
	var url := OS.get_environment("EMBERFALL_API_URL").strip_edges()
	if url.is_empty():
		url = TEST_API_URL
	if not url.begins_with("http://127.0.0.1:7599"):
		_fatal(
			"this test only runs against the throwaway server %s (got %s). Start it with server/test/run_godot_online_test.ps1" % [TEST_API_URL, url],
		)
		return
	Api.set_base_url(url)

	GameState.online_mode = false
	GameState.save_path = TEST_SAVE
	GameState.pending_save_path = TEST_PENDING
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PENDING))

	var user := "gd_%d%d" % [int(Time.get_unix_time_from_system()) % 100000, randi() % 100000]
	Api.register(user, "testpassword")
	var registration: Array = await Api.registered
	var token := str(registration[0])
	_check(not token.is_empty(), "client registered and received a token")
	_check(Api.token == token, "Api stores the session token")

	Api.list_characters()
	var characters: Array = await Api.characters_loaded
	_check(characters.is_empty(), "new account has no characters")

	GameState.reset_progress(false)
	GameState.player_name = user
	Api.create_character(user, GameState.player_class, GameState.export_save_data())
	var character: Dictionary = await Api.character_created
	var character_id := int(character.get("id", 0))
	_check(character_id > 0, "character created on the server")
	_check(str(character.get("name", "")) == user, "character name round-trips")

	GameState.online_mode = true
	_check(GameState.apply_character(character), "client applies the character")
	var gold_before := GameState.gold

	GameState.add_gold(42)
	GameState.save_game()
	_check(FileAccess.file_exists(TEST_SAVE), "local cache save is still written")
	GameState.flush_cloud_save()
	var saved_at: String = await Api.character_saved
	_check(not saved_at.is_empty(), "cloud save accepted")

	Api.load_character(character_id)
	var reloaded: Dictionary = await Api.character_loaded
	_check(int(reloaded.get("gold", -1)) == gold_before + 42, "server persisted the gold change")

	Api.list_characters()
	characters = await Api.characters_loaded
	_check(characters.size() == 1, "account lists exactly one character")

	_expect_save_failure = true
	var cheat: Dictionary = GameState.export_save_data()
	cheat["gold"] = int(cheat.get("gold", 0)) + 500000
	Api.save_character(cheat)
	await get_tree().create_timer(1.0).timeout
	_check(not _save_error.is_empty(), "server rejects a gold cheat save")

	# ---- A second character can be created and deleted again ----
	var second_name := user + "_b"
	var second_data := GameState.default_save_data(second_name, "Archer")
	_check(str(second_data.get("player_class", "")) == "Archer", "a new character starts in the chosen class")
	_check((second_data.get("inventory", []) as Array).size() == 2, "a new character starts with the starter items")

	Api.create_character(second_name, "Archer", second_data)
	var second: Dictionary = await Api.character_created
	var second_id := int(second.get("id", 0))
	_check(second_id > 0, "a second character is created")
	_check(str(second.get("class", "")) == "Archer", "the second character keeps its class")

	Api.list_characters()
	characters = await Api.characters_loaded
	_check(characters.size() == 2, "the account lists both characters")

	Api.delete_character(second_id)
	var deleted_id: int = await Api.character_deleted
	_check(deleted_id == second_id, "the second character is deleted")

	Api.list_characters()
	characters = await Api.characters_loaded
	_check(characters.size() == 1, "the deleted character is gone")

	# ---- A cloud save that failed is parked on disk and replayed later ----
	var parked: Dictionary = GameState.export_save_data()
	parked["gold"] = gold_before + 77
	GameState.write_pending_cloud_save(parked)
	_check(FileAccess.file_exists(TEST_PENDING), "a failed cloud save is parked on disk")
	_check(not GameState.replay_pending_cloud_save(second_id + 999), "a parked save is not replayed for another character")

	_check(GameState.replay_pending_cloud_save(character_id), "the parked save is replayed for its character")
	await Api.character_saved
	_check(not FileAccess.file_exists(TEST_PENDING), "the parked save is cleared after a successful upload")

	Api.load_character(character_id)
	var after_replay: Dictionary = await Api.character_loaded
	_check(int(after_replay.get("gold", -1)) == gold_before + 77, "the replayed save reached the server")

	GameState.online_mode = false
	GameState.save_path = GameState.SAVE_PATH
	GameState.pending_save_path = GameState.PENDING_SAVE_PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PENDING))
	Api.logout()

	print("CHECKS COMPLETE, FAILURES: ", _failures)
	get_tree().quit(0 if _failures == 0 else 1)
