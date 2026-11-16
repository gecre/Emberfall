extends Node

const TEST_SAVE_PATH := "user://test_stats_save.json"

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []

	# Tests trigger GameState.save_game(). Point it at a throwaway file so the
	# player's real save is never overwritten by test data.
	var original_save_path := GameState.save_path
	GameState.save_path = TEST_SAVE_PATH
	if FileAccess.file_exists(TEST_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))

	# --- Test 1: New game starts with stats at 1 (not 0) ---
	GameState.reset_progress()
	print("=== Test 1: Initial stats ===")
	for key in GameState.attributes.keys():
		var val := int(GameState.attributes[key])
		print("  %s = %d" % [key, val])
		if val != 1:
			failures.append("Initial %s should be 1 but is %d" % [key, val])

	print("  skill_points = %d (expect 3)" % GameState.skill_points)
	if GameState.skill_points != 3:
		failures.append("Initial skill_points should be 3 but is %d" % GameState.skill_points)

	print("  special_skill_points = %d (expect 1)" % GameState.special_skill_points)
	if GameState.special_skill_points != 1:
		failures.append("Initial special_skill_points should be 1 but is %d" % GameState.special_skill_points)

	# --- Test 2: Level up awards 3 skill points + 1 special + stats increase ---
	print("\n=== Test 2: Level up ===")
	var old_level := GameState.level
	var old_sp := GameState.skill_points
	var old_ssp := GameState.special_skill_points
	var old_attrs := {}
	for key in GameState.attributes.keys():
		old_attrs[key] = int(GameState.attributes[key])

	# Force a level up by giving enough XP
	var needed := GameState.xp_to_next()
	GameState.add_xp(needed)

	print("  level: %d -> %d" % [old_level, GameState.level])
	if GameState.level != old_level + 1:
		failures.append("Level should be %d but is %d" % [old_level + 1, GameState.level])

	var sp_gained := GameState.skill_points - old_sp
	print("  skill_points gained: %d (expect 3)" % sp_gained)
	if sp_gained != 3:
		failures.append("Should gain 3 skill_points per level but gained %d" % sp_gained)

	var ssp_gained := GameState.special_skill_points - old_ssp
	print("  special_skill_points gained: %d (expect 1)" % ssp_gained)
	if ssp_gained != 1:
		failures.append("Should gain 1 special_skill_point per level but gained %d" % ssp_gained)

	# Check that each attribute went up by 1
	for key in GameState.attributes.keys():
		var new_val := int(GameState.attributes[key])
		var expected: int = int(old_attrs[key]) + 1
		print("  %s: %d -> %d (expect %d)" % [key, old_attrs[key], new_val, expected])
		if new_val != expected:
			failures.append("Attr %s should be %d after level up but is %d" % [key, expected, new_val])

	# --- Test 3: Allocate a stat point ---
	print("\n=== Test 3: Allocate stat ===")
	var sp_before := GameState.skill_points
	var str_before := int(GameState.attributes.get("strength", 1))
	var ok := GameState.allocate_stat("strength")
	print("  allocate_stat('strength') = %s" % str(ok))
	print("  skill_points: %d -> %d" % [sp_before, GameState.skill_points])
	print("  strength: %d -> %d" % [str_before, int(GameState.attributes["strength"])])
	if not ok:
		failures.append("allocate_stat should return true")
	if GameState.skill_points != sp_before - 1:
		failures.append("skill_points should decrease by 1")
	if int(GameState.attributes["strength"]) != str_before + 1:
		failures.append("strength should increase by 1")

	# --- Test 4: stats() includes power from attributes ---
	print("\n=== Test 4: Derived stats ===")
	var s := GameState.stats()
	print("  power = %.1f" % float(s["power"]))
	print("  defense = %.1f" % float(s["defense"]))
	print("  damage_min = %.1f" % float(s["damage_min"]))
	print("  damage_max = %.1f" % float(s["damage_max"]))
	print("  crit_chance = %.3f" % float(s["crit_chance"]))
	print("  skill_points = %d" % int(s.get("skill_points", -1)))
	print("  special_skill_points = %d" % int(s.get("special_skill_points", -1)))

	if float(s["power"]) < 1.0:
		failures.append("Derived power should be >= 1 but is %.1f" % float(s["power"]))
	if float(s["defense"]) < 1.0:
		failures.append("Derived defense should be >= 1 but is %.1f" % float(s["defense"]))

	# --- Test 5: Multi-level up ---
	print("\n=== Test 5: Multi-level up ===")
	GameState.reset_progress()
	var big_xp := 0
	for i in range(5):
		big_xp += GameState.xp_to_next()
		GameState.add_xp(0)  # don't add yet, just sum
	GameState.reset_progress()
	# Now add all at once
	big_xp = 0
	for lvl in range(1, 6):
		big_xp += int(round(60.0 * pow(float(lvl), 1.55)))
	GameState.add_xp(big_xp)
	print("  level after %d XP: %d (expect 6)" % [big_xp, GameState.level])
	print("  skill_points: %d (expect 3 + 5*3 = 18)" % GameState.skill_points)
	print("  special_skill_points: %d (expect 1 + 5*1 = 6)" % GameState.special_skill_points)
	for key in GameState.attributes.keys():
		print("  %s = %d (expect 6)" % [key, int(GameState.attributes[key])])
		if int(GameState.attributes[key]) != 6:
			failures.append("After 5 level-ups, %s should be 6 but is %d" % [key, int(GameState.attributes[key])])

	if GameState.level != 6:
		failures.append("Level should be 6 but is %d" % GameState.level)
	if GameState.skill_points != 18:
		failures.append("skill_points should be 18 but is %d" % GameState.skill_points)
	if GameState.special_skill_points != 6:
		failures.append("special_skill_points should be 6 but is %d" % GameState.special_skill_points)

	# --- Test 6: Save/load round-trip preserves power attribute ---
	print("\n=== Test 6: Save/load round-trip ===")
	GameState.allocate_stat("power")
	var pow_before_save := int(GameState.attributes.get("power", 0))
	GameState.save_game()
	# Wipe
	GameState.reset_progress()
	# Reload
	GameState.load_game()
	var pow_after_load := int(GameState.attributes.get("power", 0))
	print("  power before save: %d  after load: %d" % [pow_before_save, pow_after_load])
	if pow_before_save != pow_after_load:
		failures.append("Power attribute lost on save/load: %d vs %d" % [pow_before_save, pow_after_load])

	# --- Test 7: HUD Character and Skills panel live updates ---
	print("\n=== Test 7: HUD live updates ===")
	var hud_scene: PackedScene = load("res://Emberfall/scenes/interface/hud.tscn")
	var hud = hud_scene.instantiate()
	add_child(hud)
	await get_tree().process_frame

	# Open character panel
	hud._toggle_character_panel()
	print("  character_panel visible: %s" % str(hud.character_panel.visible))
	var sp_before_lvl := GameState.skill_points
	GameState.add_xp(GameState.xp_to_next())
	print("  after level up, skill_points: %d (was %d)" % [GameState.skill_points, sp_before_lvl])
	print("  ability_points_label text: '%s'" % hud.ability_points_label.text)
	if not hud.ability_points_label.text.contains(str(GameState.skill_points)):
		failures.append("Character panel label did not update live on level up: %s" % hud.ability_points_label.text)

	hud.queue_free()

	# --- Test 8: Equipment and Skill stats affect derived stats ---
	print("\n=== Test 8: Equipment and Skill stats ===")
	GameState.reset_progress()
	var s_base := GameState.stats()
	var base_spd: float = float(s_base["speed"])
	var base_jump: float = float(s_base["jump_velocity"])
	var base_dmg: float = float(s_base["damage_min"])

	# Upgrade Speed Dash
	GameState.special_skill_points = 10
	GameState.upgrade_skill("Speed Dash")
	var s_speed := GameState.stats()
	print("  speed after Speed Dash: %.1f -> %.1f" % [base_spd, float(s_speed["speed"])])
	if float(s_speed["speed"]) <= base_spd:
		failures.append("Speed Dash did not increase speed")

	# Upgrade Increased Jump Height
	GameState.upgrade_skill("Increased Jump Height")
	var s_jump := GameState.stats()
	print("  jump_velocity after Increased Jump Height: %.1f -> %.1f" % [base_jump, float(s_jump["jump_velocity"])])
	if float(s_jump["jump_velocity"]) >= base_jump:
		failures.append("Increased Jump Height did not increase jump height (more negative velocity)")

	# Upgrade Power Attack
	GameState.upgrade_skill("Power Attack")
	var s_dmg := GameState.stats()
	print("  damage_min after Power Attack: %.2f -> %.2f" % [base_dmg, float(s_dmg["damage_min"])])
	if float(s_dmg["damage_min"]) <= base_dmg:
		failures.append("Power Attack did not increase damage")

	# Upgrade Avoidance
	GameState.upgrade_skill("Avoidance")
	var s_avoid := GameState.stats()
	print("  avoidance after Avoidance skill: %.3f" % float(s_avoid["avoidance"]))
	if float(s_avoid["avoidance"]) <= 0.0:
		failures.append("Avoidance skill did not increase avoidance chance")

	print("\nRESULT: ", "PASS" if failures.is_empty() else "FAIL " + str(failures))

	GameState.save_path = original_save_path
	if FileAccess.file_exists(TEST_SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))
	get_tree().quit()
