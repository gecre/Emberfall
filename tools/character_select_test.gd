extends Node
## UI test for the account flow: register through the real main menu, reach
## the world, come back, use the character list (create and delete a second
## character) and log out again.
##
## Run: Godot --headless --path . res://tools/character_select_test.tscn
## Or use server/test/run_godot_online_test.ps1, which boots a throwaway server.

const MAIN_MENU_SCENE := "res://Emberfall/scenes/interface/main_menu.tscn"

var _runner_script := preload("res://tools/character_select_runner.gd")


func _ready() -> void:
	await get_tree().process_frame
	var runner := Node.new()
	runner.set_script(_runner_script)
	get_tree().root.add_child(runner)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)
