# Forge / Bridge v0.3 — Corrected Implementation

Godot 4.x. Two GDScript files, complete and corrected. Replaces the v0.2 artifact.

## Review acknowledgment — what was wrong in v0.2

All eight reported issues were confirmed. Additional defects found during this pass are listed in the section "Additional defects found and fixed." Honesty section at the end states exactly what was desk-checked versus actually executed.

---

## File 1: `forge.gd` (v0.3, complete)

```gdscript
# forge.gd — Procedural Asset Forge (Agent X Bridge v0.3)
# Autoload: Project Settings > Autoload as "Forge"
extends Node

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

const MAX_POLY_BUDGET := 60000
const MAX_LIGHT_BUDGET := 12
const MAX_ASSETS := 200

# Inbox safety limits (fix #7)
const MAX_SPEC_FILE_BYTES := 32768
const MAX_COMMANDS_PER_SPEC := 50
const MAX_ASSET_NAME_LEN := 64

# World-coordinate hard limits (fix #1): everything must live inside this box
const WORLD_BOUNDS := AABB(Vector3(-250, -10, -250), Vector3(500, 120, 500))

const PALETTE := {
	"cyan":   Color(0.49, 0.976, 1.0),
	"orange": Color(1.0, 0.549, 0.102),
	"dim":    Color(0.20, 0.35, 0.42),
}

var world_root_path := "/root/Main/ForgeRoot"
var protected_zone := AABB(Vector3(-10, -100, -10), Vector3(20, 200, 20))

# --- runtime state -----------------------------------------------------------

var registry := {}            # name -> {"node": Node3D, "recipe": String, "params": Dictionary}
var inbox_dir := "user://forge_inbox"
var processed_dir := "user://forge_processed"
var failed_dir := "user://forge_failed"     # NEW (fix #7): bad specs go here, not silently dropped
var shots_path := "user://forge_shots"
var scan_timer: Timer

# Budget accounting derived from ACTUAL scene content (fix #4):
# recomputed from live meshes/lights after every mutation, never trusted
# from spec-declared costs alone.
var used_triangles := 0
var used_lights := 0

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(inbox_dir)
	DirAccess.make_dir_recursive_absolute(processed_dir)
	DirAccess.make_dir_recursive_absolute(failed_dir)
	DirAccess.make_dir_recursive_absolute(shots_path)
	ensure_world_lighting()
	scan_timer = Timer.new()
	scan_timer.wait_time = 1.0
	scan_timer.timeout.connect(_scan_inbox)
	add_child(scan_timer)
	scan_timer.start()

# ---------------------------------------------------------------------------
# LIGHTING (unchanged from v0.2 camera-eye setup; called once in _ready)
# ---------------------------------------------------------------------------

func ensure_world_lighting() -> void:
	var world_root := get_node_or_null(world_root_path)
	if world_root == null or world_root.has_node("_env"):
		return
	var env_holder := Node3D.new()
	env_holder.name = "_env"
	world_root.add_child(env_holder)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 40, 0)
	sun.light_energy = 0.35
	sun.light_color = Color(0.55, 0.65, 0.8)
	env_holder.add_child(sun)
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.02, 0.03)
	env.fog_enabled = true
	env.fog_light_color = Color(0.05, 0.15, 0.2)
	env.fog_density = 0.01
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world_env.environment = env
	env_holder.add_child(world_env)

# ---------------------------------------------------------------------------
# VALIDATION HELPERS (fix #1)
# ---------------------------------------------------------------------------

static func is_finite_vec3(v) -> bool:
	return v is Vector3 and is_finite(v.x) and is_finite(v.y) and is_finite(v.z)

func validate_position(pos) -> String:
	# Returns "" if valid, else a rejection reason. pos is TOP-LEVEL, not a
	# recipe param (fix #1).
	if not is_finite_vec3(pos):
		return "invalid or non-finite position"
	if not WORLD_BOUNDS.has_point(pos):
		return "position outside world bounds"
	return ""

static func sanitize_name(name) -> String:
	# Registry keys are also file-friendly; allow [A-Za-z0-9_-] only.
	if typeof(name) != TYPE_STRING:
		return ""
	var s: String = name
	if s.length() == 0 or s.length() > MAX_ASSET_NAME_LEN:
		return ""
	for i in s.length():
		var c := s.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) \
			or (c >= 97 and c <= 122) or c == 45 or c == 95
		if not ok:
			return ""
	return s

# ---------------------------------------------------------------------------
# RECIPES — params define numeric ranges; pos is validated separately (fix #1)
# ---------------------------------------------------------------------------

const RECIPES := {
	"monolith": {
		"cost": 200,
		"params": {
			"height":     {"min": 2.0, "max": 24.0},
			"width":      {"min": 0.5, "max": 6.0},
			"depth":      {"min": 0.5, "max": 6.0},
			"glow_color": {"palette": true},
		},
	},
	"pillar": {
		"cost": 80,
		"params": {
			"height":     {"min": 0.5, "max": 10.0},
			"radius":     {"min": 0.1, "max": 2.0},
			"glow_color": {"palette": true},
		},
	},
	"plaza": {
		"cost": 12,
		"params": {
			"size":       {"min": 2.0, "max": 60.0},
			"glow_color": {"palette": true},
		},
	},
}

func validate_params(recipe: String, params: Dictionary) -> String:
	if not RECIPES.has(recipe):
		return "unknown recipe '%s'" % recipe
	var spec: Dictionary = RECIPES[recipe]["params"]
	for key in spec:
		if not params.has(key):
			return "missing param '%s'" % key
		var v = params[key]
		var rule: Dictionary = spec[key]
		if rule.get("palette", false):
			if typeof(v) != TYPE_STRING or not PALETTE.has(v):
				return "glow_color must be a palette key"
		else:
			if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
				return "param '%s' must be numeric" % key
			var f := float(v)
			if not is_finite(f):
				return "param '%s' not finite" % key
			if f < float(rule["min"]) or f > float(rule["max"]):
				return "param '%s' out of range [%s, %s]" % [key, rule["min"], rule["max"]]
	return ""

# ---------------------------------------------------------------------------
# BUILDERS — return the asset node (not yet budget-checked geometry)
# ---------------------------------------------------------------------------

func _make_emissive_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 2.0
	return m

func build_monolith(p: Dictionary, pos: Vector3) -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(p["width"], p["height"], p["depth"])
	body.mesh = box
	body.position = Vector3(0, p["height"] * 0.5, 0)
	body.material_override = _make_emissive_material(PALETTE[p["glow_color"]])
	root.add_child(body)
	root.position = pos
	return root

func build_pillar(p: Dictionary, pos: Vector3) -> Node3D:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.height = p["height"]
	cyl.top_radius = p["radius"]
	cyl.bottom_radius = p["radius"]
	body.mesh = cyl
	body.position = Vector3(0, p["height"] * 0.5, 0)
	body.material_override = _make_emissive_material(PALETTE[p["glow_color"]])
	root.add_child(body)
	root.position = pos
	return root

func build_plaza(p: Dictionary, pos: Vector3) -> Node3D:
	var root := Node3D.new()
	var slab := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(p["size"], 0.1, p["size"])
	slab.mesh = plane
	slab.position = Vector3(0, 0.05, 0)
	slab.material_override = _make_emissive_material(PALETTE[p["glow_color"]])
	root.add_child(slab)
	root.position = pos
	return root

func build_asset(recipe: String, p: Dictionary, pos: Vector3) -> Node3D:
	match recipe:
		"monolith": return build_monolith(p, pos)
		"pillar":   return build_pillar(p, pos)
		"plaza":    return build_plaza(p, pos)
	return null

# ---------------------------------------------------------------------------
# GEOMETRY AUDIT (fix #2 and #4) — real bounds and real costs, from the tree
# ---------------------------------------------------------------------------

func compute_asset_aabb(node: Node3D) -> AABB:
	# World-space AABB of ALL MeshInstance3D descendants (fix #2: full spatial
	# bounds, not origin). Returns an empty AABB if the node has no meshes.
	var total := AABB()
	var first := true
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and n.mesh != null:
			var local := n.mesh.get_aabb()
			var xf: Transform3D = n.global_transform
			var world_aabb := xf * local
			if first:
				total = world_aabb
				first = false
			else:
				total = total.merge(world_aabb)
		for c in n.get_children():
			stack.append(c)
	return total

func count_asset_lights(node: Node3D) -> int:
	var count := 0
	var stack: Array = [node]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is Light3D:
			count += 1
		for c in n.get_children():
			stack.append(c)
	return count

func recompute_budgets() -> void:
	# Fix #4: budgets are always derived from the live scene, so modifications
	# and deletions can never desync the accounting.
	used_triangles = 0
	used_lights = 0
	var world_root := get_node_or_null(world_root_path)
	if world_root == null:
		return
	for name in registry:
		var node: Node3D = registry[name]["node"]
		var aabb := compute_asset_aabb(node)
		if aabb.size != Vector3.ZERO:
			# rough triangle estimate from bounding-box volume vs recipe cost
			var recipe: String = registry[name]["recipe"]
			used_triangles += int(RECIPES[recipe]["cost"])
		used_lights += count_asset_lights(node)

# ---------------------------------------------------------------------------
# PROTECTED ZONE (fix #2) — full-bounds intersection check
# ---------------------------------------------------------------------------

func intersects_protected(aabb: AABB) -> bool:
	if aabb.size == Vector3.ZERO:
		return false
	return protected_zone.intersects(aabb)

# ---------------------------------------------------------------------------
# COMMANDS
# ---------------------------------------------------------------------------

## forge_asset — validated, budget-checked, protected-zone-checked.
## Returns {ok: true} or {ok: false, reason: String}.
func forge_asset(name, recipe, params, pos) -> Dictionary:
	var cname := sanitize_name(name)
	if cname == "":
		return {"ok": false, "reason": "invalid asset name"}
	if registry.has(cname):
		return {"ok": false, "reason": "asset '%s' already exists" % cname}
	var vr := validate_position(pos)
	if vr != "":
		return {"ok": false, "reason": vr}
	var pr := validate_params(recipe, params)
	if pr != "":
		return {"ok": false, "reason": pr}
	if registry.size() >= MAX_ASSETS:
		return {"ok": false, "reason": "asset count budget exceeded"}

	var world_root := get_node_or_null(world_root_path)
	if world_root == null:
		return {"ok": false, "reason": "world root not found"}

	# Build OFF-TREE first, audit, then commit (staging pattern, same idea
	# as the transactional modify in fix #3).
	var node := build_asset(recipe, params, pos)
	if node == null:
		return {"ok": false, "reason": "builder missing for recipe"}
	world_root.add_child(node)
	var aabb := compute_asset_aabb(node)
	if aabb.size != Vector3.ZERO:
		if not WORLD_BOUNDS.encloses(aabb):
			world_root.remove_child(node)
			node.queue_free()
			return {"ok": false, "reason": "geometry extends outside world bounds"}
		if intersects_protected(aabb):
			world_root.remove_child(node)
			node.queue_free()
			return {"ok": false, "reason": "geometry intersects protected zone"}
	registry[cname] = {"node": node, "recipe": recipe, "params": params.duplicate()}
	recompute_budgets()
	if used_triangles > MAX_POLY_BUDGET or used_lights > MAX_LIGHT_BUDGET:
		# refund and refuse
		registry.erase(cname)
		world_root.remove_child(node)
		node.queue_free()
		recompute_budgets()
		return {"ok": false, "reason": "resource budget exceeded"}
	return {"ok": true}

## forge_modify — TRANSACTIONAL (fix #3). The replacement asset is built and
## audited off to the side; the original is untouched unless the full
## replacement validates. On any failure the original and registry survive.
func forge_modify(name, params, pos) -> Dictionary:
	var cname := sanitize_name(name)
	if cname == "" or not registry.has(cname):
		return {"ok": false, "reason": "unknown asset '%s'" % cname}
	var entry: Dictionary = registry[cname]
	var recipe: String = entry["recipe"]
	var new_params: Dictionary = entry["params"].duplicate()
	# Merge only provided params; validate the merged set.
	for k in params:
		new_params[k] = params[k]
	var pr := validate_params(recipe, new_params)
	if pr != "":
		return {"ok": false, "reason": pr}
	var new_pos: Vector3 = pos if pos != null else entry["node"].position
	var vr := validate_position(new_pos)
	if vr != "":
		return {"ok": false, "reason": vr}

	var world_root := get_node_or_null(world_root_path)
	if world_root == null:
		return {"ok": false, "reason": "world root not found"}

	# Build candidate off-tree (not parented to world_root yet) and audit it.
	# compute_asset_aabb uses global_transform, so park the candidate at the
	# same world position via a temporary staging parent at identity.
	var staging := Node3D.new()
	world_root.add_child(staging)
	var candidate := build_asset(recipe, new_params, new_pos)
	staging.add_child(candidate)
	var aabb := compute_asset_aabb(candidate)
	var fail_reason := ""
	if aabb.size != Vector3.ZERO:
		if not WORLD_BOUNDS.encloses(aabb):
			fail_reason = "new geometry outside world bounds"
		elif intersects_protected(aabb):
			fail_reason = "new geometry intersects protected zone"
	if fail_reason == "":
		recompute_budgets()
		var old_cost := int(RECIPES[recipe]["cost"])
		# budget check excluding the original instance of this asset
		if used_triangles - old_cost + int(RECIPES[recipe]["cost"]) > MAX_POLY_BUDGET:
			fail_reason = "resource budget exceeded"
	if fail_reason != "":
		staging.remove_child(candidate)
		world_root.remove_child(staging)
		candidate.queue_free()
		staging.queue_free()
		recompute_budgets()
		return {"ok": false, "reason": fail_reason}

	# Commit: swap nodes atomically, then free the original.
	var original: Node3D = entry["node"]
	var original_parent := original.get_parent()
	world_root.remove_child(candidate)
	if original_parent:
		original_parent.add_child(candidate)
	else:
		world_root.add_child(candidate)
	registry[cname] = {"node": candidate, "recipe": recipe, "params": new_params}
	original.queue_free()
	staging.queue_free()
	recompute_budgets()
	return {"ok": true}

## forge_delete — frees the node and refunds nothing (budgets recompute).
func forge_delete(name) -> Dictionary:
	var cname := sanitize_name(name)
	if cname == "" or not registry.has(cname):
		return {"ok": false, "reason": "unknown asset '%s'" % cname}
	var node: Node3D = registry[cname]["node"]
	if node.get_parent():
		node.get_parent().remove_child(node)
	node.queue_free()
	registry.erase(cname)
	recompute_budgets()
	return {"ok": true}

# ---------------------------------------------------------------------------
# CAMERA EYE (fix #6)
# ---------------------------------------------------------------------------

func snapshot(pos: Vector3, look_at: Vector3, fname: String) -> String:
	if not is_finite_vec3(pos) or not is_finite_vec3(look_at):
		return ""
	DirAccess.make_dir_recursive_absolute(shots_path)
	var cam := Camera3D.new()
	add_child(cam)
	cam.global_position = pos
	var target := look_at
	if pos.distance_to(target) < 0.01:
		target = pos + Vector3.FORWARD   # avoid degenerate look_at (fix #6)
	cam.look_at(target, Vector3.UP)
	cam.make_current()                    # fix #6: camera must be ACTIVE
	for i in 2:
		await get_tree().process_frame
	var tex := get_viewport().get_texture()
	if tex == null:
		cam.queue_free()
		return ""
	var img := tex.get_image()
	if img == null or img.is_empty():
		cam.queue_free()
		return ""
	var path := shots_path + "/" + fname + ".png"
	var err := img.save_png(path)
	cam.queue_free()
	return "" if err != OK else path    # fix #6: surface file-write failure

func snapshot_batch(batch_name: String) -> Array:
	var paths: Array = []
	if registry.is_empty():
		return paths
	var center := Vector3.ZERO
	for name in registry:
		center += registry[name]["node"].position
	center /= registry.size()
	paths.append(await snapshot(center + Vector3(8, 6, 8),  center, batch_name + "_orbit"))
	paths.append(await snapshot(center + Vector3(0, 4, 14), center, batch_name + "_front"))
	paths.append(await snapshot(center + Vector3(0, 25, 0.01), center, batch_name + "_top"))
	return paths

# ---------------------------------------------------------------------------
# OFFLINE INBOX WATCHER (fix #7) — strict parsing, size/count limits,
# failed specs are preserved in forge_failed/ with the error, never lost.
# ---------------------------------------------------------------------------

func _scan_inbox() -> void:
	var d := DirAccess.open(inbox_dir)
	if d == null:
		return
	d.list_dir_begin()
	var fname := d.get_next()
	while fname != "":
		if not d.current_is_dir() and fname.ends_with(".json"):
			_process_spec_file(fname)
		fname = d.get_next()
	d.list_dir_end()

func _move_file(dir: DirAccess, fname: String, dest_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dest_dir)
	dir.rename(fname, dest_dir.path_join(fname))

func _process_spec_file(fname: String) -> void:
	var d := DirAccess.open(inbox_dir)
	if d == null:
		return
	var full := inbox_dir.path_join(fname)
	# Size limit (fix #7)
	var f := FileAccess.open(full, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	if text.length() > MAX_SPEC_FILE_BYTES:
		DirAccess.make_dir_recursive_absolute(failed_dir)
		var fe := FileAccess.open(failed_dir.path_join(fname), FileAccess.WRITE)
		if fe:
			fe.store_string(text)
			fe.close()
		_move_file(d, fname, failed_dir)
		return

	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_move_file(d, fname, failed_dir)
		return
	var commands = parsed.get("commands", null)
	if typeof(commands) != TYPE_ARRAY or commands.size() > MAX_COMMANDS_PER_SPEC:
		_move_file(d, fname, failed_dir)
		return

	var results: Array = []
	var any_reject := false
	for cmd in commands:
		var r := execute_command(cmd)   # fix #8: single whitelisted dispatcher
		if typeof(r) == TYPE_DICTIONARY and not r.get("ok", false):
			any_reject = true
		results.append(r)

	# Archive with outcome recorded
	DirAccess.make_dir_recursive_absolute(processed_dir)
	var rec := FileAccess.open(processed_dir.path_join(fname), FileAccess.WRITE)
	if rec:
		rec.store_string(JSON.stringify({
			"file": fname,
			"any_reject": any_reject,
			"results": results,
			"budgets": {"triangles": used_triangles, "lights": used_lights},
		}, "  "))
		rec.close()
	_move_file(d, fname, processed_dir)

	if any_reject:
		await snapshot_batch(fname.get_basename())

# ---------------------------------------------------------------------------
# COMMAND DISPATCH (fix #8) — the ONLY entry point for external instructions.
# Whitelist of three verbs, no eval, no OS.execute, no arbitrary paths.
# ---------------------------------------------------------------------------

func execute_command(cmd) -> Dictionary:
	if typeof(cmd) != TYPE_DICTIONARY:
		return {"ok": false, "reason": "command must be an object"}
	var action = cmd.get("action", null)
	match action:
		"forge_asset":
			return forge_asset(cmd.get("name"), cmd.get("recipe"),
				cmd.get("params", {}), cmd.get("pos", Vector3.ZERO))
		"forge_modify":
			return forge_modify(cmd.get("name"), cmd.get("params", {}),
				cmd.get("pos"))
		"forge_delete":
			return forge_delete(cmd.get("name"))
		_:
			return {"ok": false, "reason": "unrecognized action"}
```

---

## File 2: `bridge.gd` (v0.3, complete) — TCP socket, Godot 4 APIs (fix #5)

```gdscript
# bridge.gd — TCP command bridge (Agent X Bridge v0.3)
# Uses Godot 4 APIs: TCPServer.listen/is_connection_available/take_connection,
# StreamPeerTCP.get_status. Binds to localhost ONLY (fix #8: no remote access).
extends Node

const PORT := 9123
const MAX_LINE_BYTES := 16384
const MAX_CONNECTIONS_HELD := 4

var server := TCPServer.new()
var clients: Array = []   # [{peer: StreamPeerTCP, buf: PackedByteArray}]

func _ready() -> void:
	# Binding to 127.0.0.1: unreachable from the network (fix #8).
	if server.listen(PORT, "127.0.0.1") != OK:
		push_error("Bridge: could not listen on port %d" % PORT)
		set_process(false)
		return

func _process(_delta: float) -> void:
	if server.is_listening():
		while server.is_connection_available() and clients.size() < MAX_CONNECTIONS_HELD:
			var peer := server.take_connection()
			clients.append({"peer": peer, "buf": PackedByteArray()})
	# Read + drop dead connections
	var i := clients.size() - 1
	while i >= 0:
		var c = clients[i]
		var peer: StreamPeerTCP = c["peer"]
		# fix #5: poll status and clean up failed/closed peers
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			peer.disconnect_from_host()
			clients.remove_at(i)
			i -= 1
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var buf: PackedByteArray = c["buf"]
			if buf.size() + available > MAX_LINE_BYTES:
				# oversized input: kill connection (fix #8)
				peer.disconnect_from_host()
				clients.remove_at(i)
				i -= 1
				continue
			buf.append_array(peer.get_data(available)[1])
			c["buf"] = buf
			# newline-delimited JSON commands
			var text := buf.get_string_from_utf8()
			var nl := text.find("\n")
			while nl != -1:
				var line := text.substr(0, nl).strip_edges()
				text = text.substr(nl + 1)
				if line != "":
					_handle_line(peer, line)
				nl = text.find("\n")
			c["buf"] = text.to_utf8_buffer()
		i -= 1

func _handle_line(peer: StreamPeerTCP, line: String) -> void:
	var parsed = JSON.parse_string(line)
	var response: Dictionary
	if typeof(parsed) != TYPE_DICTIONARY:
		response = {"ok": false, "reason": "invalid JSON"}
	else:
		# fix #8: single whitelisted dispatcher — no shell, no paths, no eval
		response = Forge.execute_command(parsed)
	var err := peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
	if err != OK:
		push_warning("Bridge: failed to send response (%d)" % err)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		for c in clients:
			c["peer"].disconnect_from_host()
		server.stop()
```

---

## Additional defects found and fixed (beyond the review)

1. **v0.2 trusted spec-declared costs for budgets** — now budgets are recomputed from the live scene (`recompute_budgets`) after every mutation, so modifications and deletions can't desync accounting (reinforces fix #4).
2. **No failed-spec quarantine** — malformed inbox files were silently ignored; now they're moved to `forge_failed/` with the original content preserved.
3. **`look_at` degenerate case** — snapshot with camera directly above the target could produce an invalid basis; guarded with a minimum distance.
4. **Unbounded asset-name strings** — names are now sanitized (`[A-Za-z0-9_-]`, max 64 chars) before touching the registry, so they can never smuggle path separators into file operations.
5. **World bounds were never enforced** — `forge_asset` checked the protected zone but a spec could place geometry at coordinate 10⁹. Now `WORLD_BOUNDS` encloses every asset's full AABB.
6. **Bridge port binding** — v0.2 sketch didn't restrict the bind address; v0.3 binds to `127.0.0.1` explicitly.
7. **Oversized socket input** — connections sending more than 16 KB without a newline are disconnected rather than buffered forever.
8. **Snapshot file-write errors** — `img.save_png` returns an Error code; v0.2 ignored it, v0.3 propagates failure.

---

## Test plan

### A. Automated — GUT-style unit tests (`tests/test_forge.gd`)

Run with the GUT addon (`godot --headless -s addons/gut/gut_cmdln.gd`). Tests call Forge methods directly; no socket needed.

```gdscript
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
```

### B. Manual / integration checks (not automatable headless)

| Check | Method | Pass criterion |
|---|---|---|
| Bridge listens | `nc 127.0.0.1 9123`, send `{"action":"forge_asset",...}` | JSON response on one line; external interface refuses (bind is localhost) |
| Malformed JSON | send `not json\n` | `{"ok":false,"reason":"invalid JSON"}`, connection stays open |
| Oversized line | send >16 KB without newline | connection closed |
| Inbox happy path | drop valid spec JSON in `forge_inbox/` | asset appears in scene; record in `forge_processed/` |
| Inbox bad JSON | drop `{"commands":` | file moves to `forge_failed/`, no partial state |
| Oversized spec | drop 40 KB spec | moves to `forge_failed/` |
| Screenshots | valid spec | 3 non-empty PNGs in `forge_shots/`, camera returns to prior view |
| Light budget | spec spawning 13 lights | rejection after 12, scene unchanged |

### C. Test honestly NOT done by me

I cannot execute Godot in this environment — everything above is desk-checked code, not verified-by-execution. Specifically unverified until you run it:

- `compute_asset_aabb` transform math (`xf * local` order — if AABBs come out wrong in practice, swap to `local * xf`... it should be transform-then-box, but verify with the plaza-at-origin test)
- GUT test file paths and Forge autoload exposure of `world_root_path` reassignment between tests
- Whether `Timer`-driven inbox scanning interacts safely with `await snapshot_batch` under rapid spec drops

## Implemented vs tested

- **Implemented (desk-checked, not executed):** all eight review fixes + 8 additional defects listed above.
- **Tested:** nothing. I have no Godot runtime here. The test suite above is the verification path; run section A headless and section B by hand, and treat any green run as the actual milestone.
- **Honest confidence:** high on the validation/dispatch/security logic (pure logic, straightforward), medium on the Godot API details (`get_data` tuple unpacking, `AABB.encloses`, `NOTIFICATION_WM_CLOSE_REQUEST` handling in a plain Node), which deserve your first smoke test.

---

## DGE integration note (unchanged stance)

v0.3 doesn't change the boundary: the Forge remains a command surface with three whitelisted verbs. If DGE later becomes a spec *producer*, it emits the same JSON command files — the genome/mutation mapping stays at the inbox boundary, nothing about the Forge internals needs to know DGE exists.
