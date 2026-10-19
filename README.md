# Bridge v0.3 — as-is review snapshot

This repository preserves the Bridge v0.3 implementation authored by Fetch.ai Agent X, including its bugs. `forge.gd`, `bridge.gd`, and `tests/test_forge.gd` are extracted verbatim from the three GDScript fences in `docs/Bridge-v0.3-Corrected-Implementation.md`. The original document is included unchanged. No v0.2 implementation or wider DGE project is included. No fixes, refactoring, or formatting changes were applied to the extracted code.

## Module map

`forge.gd` contains `execute_command` (external action dispatch), `_scan_inbox` / `_process_spec_file` (JSON file ingestion), `validate_position` / `validate_params` (validation), `forge_asset`, `forge_modify` (candidate staging, parent removal and replacement), `forge_delete`, the primitive mesh builders, `compute_asset_aabb`, and `recompute_budgets` (recipe-cost accounting rather than actual mesh triangle counting). `bridge.gd` contains the loopback TCP listener, newline framing in `_process`, JSON parsing in `_handle_line`, and dispatch to Forge. `tests/test_forge.gd` contains the supplied GUT tests. The original document contains the manual integration checks and author-stated limitations. There is no JSON-array-to-Vector3 decoder in the supplied v0.3 code.

## Dependencies and exact test commands

Install Godot 4.3 (standard build, available as `godot` on PATH) and Git. The original source says only Godot 4.x and GUT, without pinning versions; Godot 4.3 plus GUT v9.3.0 is a review harness choice, not an upstream-tested dependency claim. From this repository root:

```sh
git clone --depth 1 --branch v9.3.0 https://github.com/bitwes/Gut.git .gut-dependency
```

Copy `.gut-dependency/addons/gut` into this repository's `addons/gut` directory. On PowerShell:

```powershell
New-Item -ItemType Directory -Force addons | Out-Null
Copy-Item -Recurse .gut-dependency/addons/gut addons/gut
```

Then run:

```sh
godot --headless --editor --path . --import
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://tests -gexit
```

The minimal `project.godot` and `.gutconfig.json` are newly added review harness configuration. They register the original Forge and Bridge scripts as autoloads and discover the supplied tests. Compilation errors or failing tests are review results; do not patch the snapshot merely to make it green. Godot and GUT were not run when packaging this repository. The original author also explicitly reports no executed tests.

## JSON review fixtures

The original v0.3 document contains no standalone JSON fixture files or harness config. `tests/fixtures/cases.json` is newly added review material, not original source and not automatically consumed by the supplied GUT suite. It separates expected contract behavior from static predictions of current behavior. The source document's original manual checklist is preserved in full.

For manual TCP checks, open a Godot project scene with a Node named `Main` and Node3D child named `ForgeRoot`, then run that scene. The project has no default scene; the automated tests create their own root. The bridge binds `127.0.0.1:9123`. Send each fixture's `command` as one JSON line. For inbox checks, wrap a command in `{"commands":[COMMAND]}` and place it in `user://forge_inbox/` (Project > Open User Data Folder). The correct v0.3 wrapper is `commands`, not the older `cmds` wrapper.

The positive-position fixture is expected to be rejected by the current implementation because JSON arrays are not Vector3 values. To review the modify parent-removal defect independently, use the supplied direct GUT success test and inspect node validity after deferred deletion. The test itself is intentionally unchanged.

## Provenance and scope

Only the original document and its three code blocks are upstream material. README, project configuration, ignore rules, fixture cases and extraction manifest are packaging additions. `EXTRACTION.json` records SHA-256 hashes of the exact original bytes and extracted script bytes. No license was supplied, so this snapshot does not invent a license grant. This repository is a review artifact, not a claim that v0.3 works or is secure.