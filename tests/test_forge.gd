extends GutTest

func before_each():
	# fresh world root per test
	var wr := Node3D.new()
	wr.name = "ForgeRoot"
	add_child(wr)
	Forge.world_root_path = wr.get_path()
	Forge.registry = {}
	Forge.recompute_budgets()

func after_each():
	Forge.world_root_path = "/root/Main/ForgeRoot"

func test_reject_non_finite_position():
	var r = Forge.forge_asset("t1", "pillar", {"height": 2, "radius": 0.5, "glow_color": "cyan"}, Vector3(NAN, 0, 0))
	assert_false(r["ok"])

func test_reject_out_of_bounds_position():
	var r = Forge.forge_asset("t2", "pillar", {"height": 2, "radius": 0.5, "glow_color": "cyan"}, Vector3(9999, 0, 9999))
	assert_false(r["ok"])

func test_reject_param_out_of_range():
	var r = Forge.forge_asset("t3", "pillar", {"height": 99, "radius": 0.5, "glow_color": "cyan"}, Vector3.ZERO)
	assert_false(r["ok"])

func test_reject_bad_palette_key():
	var r = Forge.forge_asset("t4", "plaza", {"size": 10, "glow_color": "purple"}, Vector3.ZERO)
	assert_false(r["ok"])

func test_reject_duplicate_name():
	Forge.forge_asset("t5", "plaza", {"size": 10, "glow_color": "cyan"}, Vector3.ZERO)
	var r = Forge.forge_asset("t5", "plaza", {"size": 10, "glow_color": "cyan"}, Vector3.ZERO)
	assert_false(r["ok"])

func test_protected_zone_rejects_full_bounds():
	# plaza slab centered at origin definitely overlaps the protected AABB
	var r = Forge.forge_asset("t6", "plaza", {"size": 30, "glow_color": "cyan"}, Vector3.ZERO)
	assert_false(r["ok"])

func test_modify_transactional_on_failure():
	Forge.forge_asset("t7", "monolith", {"height": 4, "width": 1, "depth": 1, "glow_color": "cyan"}, Vector3(50, 0, 50))
	var before = Forge.registry["t7"]["params"].duplicate()
	# invalid modification: bad palette key
	var r = Forge.forge_modify("t7", {"glow_color": "chartreuse"}, null)
	assert_false(r["ok"])
	assert_eq(Forge.registry["t7"]["params"], before)   # original untouched
	assert_true(is_instance_valid(Forge.registry["t7"]["node"]))

func test_modify_valid_succeeds_and_swaps_node():
	Forge.forge_asset("t8", "pillar", {"height": 2, "radius": 0.5, "glow_color": "cyan"}, Vector3(50, 0, 50))
	var old_node = Forge.registry["t8"]["node"]
	var r = Forge.forge_modify("t8", {"height": 6}, null)
	assert_true(r["ok"])
	assert_ne(Forge.registry["t8"]["node"], old_node)

func test_delete_removes_and_allows_reuse():
	Forge.forge_asset("t9", "plaza", {"size": 10, "glow_color": "cyan"}, Vector3(50, 0, 50))
	assert_true(Forge.forge_delete("t9")["ok"])
	assert_false(Forge.registry.has("t9"))
	var r = Forge.forge_asset("t9", "plaza", {"size": 10, "glow_color": "orange"}, Vector3(50, 0, 50))
	assert_true(r["ok"])

func test_dispatch_whitelist():
	var r = Forge.execute_command({"action": "execute_shell", "cmd": "rm -rf /"})
	assert_false(r["ok"])
	assert_has(r, "reason")

func test_name_sanitization():
	var r = Forge.forge_asset("../etc/passwd", "plaza", {"size": 10, "glow_color": "cyan"}, Vector3(50, 0, 50))
	assert_false(r["ok"])
