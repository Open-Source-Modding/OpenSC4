# OpenSC4

## What it is

OpenSC4 is an open-source **Godot 4.7 (GDScript)** reimplementation of *SimCity 4*. It does
**not** ship game content — instead it loads the ORIGINAL game's proprietary assets
(`.dat` / `.sc4` DBPF archives) at runtime and renders them. Licensed **GNU AGPL v3**
(the copyright headers in the source, e.g. top of `Core.gd`, say "version 3 or, at your
option, any later version"; the full text is in `LICENSE`).

## Assets: bring your own

No SimCity 4 file is tracked — `.gitignore` blocks `*.dat`, `*.DAT`, `*.exe`, `*.dll`,
`*.sgr`, `*.ini`, `*.png`, `*.import`, `readme.txt` and the sim data folders
(`Regions/`, `EULA/`, `fontconfig/`, `Fonts/`, `Plugins/`,
`Radio/Stations/{Mayor,Region}/`, `ReadMe/`, `Sku_Data/`, `Support/`). The boot splash and
window-icon image are user-supplied as well (the repo bundles neither).

- A real **SimCity 4 (Deluxe Edition)** install is required.
- Per `README.md`, the user drops the contents of their SC4 install into the project
  directory — locally only, never committed.
- The chosen game folder is held in `Core.game_dir` and cached in `user://config.ini` under
  `[paths] sc4_files`. On first boot (empty config) a `FileDialog` prompts for the folder
  (see `BootScreen.gd` `_ready()`).
- Godot must be **4.7 or newer** (`project.godot` `config/features=PackedStringArray("4.7")`).

## Run / verify

- Import assets + compile-check scripts: `godot --headless --import`
  (expect **0 SCRIPT ERRORs**).
- Boot the app headless: `timeout -k 5 20 godot --path . --headless`
  — should reach the log line `DBPF files loaded` with zero SCRIPT ERRORs.
- City-load harness (headless): `godot --headless --path . res://tools/HeadlessCity.tscn`
  `[-- "<region>" "<city name>"]` (default Timbuktu / Big City Tutorial). Loads the DATs +
  a real save, builds terrain/buildings, sweeps all building view variants; a clean run
  ends with `SWEEP COMPLETE`.
- Visual harness (windowed): `godot --path . --resolution 1600x900
  res://tools/ScreenshotCity.tscn -- <out_dir> ["<region>" "<city name>"]` — same load
  path, then saves `city_zoom1.png` (whole map) and `city_zoom4.png` (map centre,
  close-up) to `<out_dir>` and quits; ends with `SCREENSHOTS DONE`. Use it to eyeball
  placement/rendering changes.
- Main scene: `BootScreen.tscn`. **There is no test suite.**

## Architecture

### Autoloads (see `project.godot` `[autoload]`)

- `Boot` = `Boot.gd` — tiny global state holder (`current_city`, `load_progress_val`).
- `Core` = `Core.gd` — the central asset registry (see below).
- `Log` = `utils/logger.gd` — vendored KOBUGE godot-logger (`Log.info/warn/error/debug/verbose`).
- `DebugUtils` = `utils/debug_utils.gd` — dev print helpers.

### Boot flow (`BootScreen.gd`)

1. Validate `Core.game_dir` from `user://config.ini`; else pop the FileDialog and save.
2. Start a **single** loader `Thread` running `load_DATs()`, which iterates the hardcoded
   `dat_files` list (`Apps/SimCity 4.ini`, `Sound.dat`, `Intro.dat`, `SimCity_1..5.dat`,
   `EP1.dat`). Each file builds a `DBPF` and calls `Core.add_dbpf()`.
3. UI updates from the worker thread marshal back via `call_deferred`.
4. On completion, the user picks **Region view** (`Region.tscn`) or the **DAT Explorer**
   (`DATExplorer/DATExplorer.tscn`).

### `Core.gd` — central asset registry

Everything flows through this singleton.
- `subfile_indices`: TGI string -> `SubfileIndex` (built by `add_dbpf`).
- `dbpf_files`, `sub_by_type_and_group`: additional lookup tables.
- Hardcoded TGI dictionaries: `type_dict` / `group_dict` (name -> id) and `class_dict`
  (type name -> parser class, e.g. `FSH -> FSHSubfile`, `PNG -> ImageSubfile`; many are `null`).
- Main API:
  - `Core.subfile(type_id, group_id, instance_id, ParserClass) -> DBPFSubfile`
  - `Core.get_subfile(type_str, group_str, instance_id)` — string-friendly variant.
  - `Core.get_gamedata_path(rel) -> String` — resolves a path under `game_dir`.

### `addons/dbpf/` — DBPF format library (Godot editor plugin)

- `DBPF.gd` parses the container (header, `SubfileIndex` records, `DBDF` compressed-file
  directory).
- `DBPFSubfile.gd` (`class_name DBPFSubfile`) is the base class for parsed subfiles and
  contains a **hand-rolled QFS/RefPack decompressor** in GDScript (`decompress()`,
  performance-sensitive).
- Parser subclasses (all `extends DBPFSubfile`): `ExemplarSubfile` (EQZB property files;
  key descriptions from `exemplar_types.dict`), `FSHSubfile` (textures), `S3DSubfile`
  (3D models), `ATCSubfile`/`AVPSubfile` (2D sprite props — see below), `LTEXTSubfile`
  (UTF-16 strings), `ImageSubfile` (PNG), `RULSubfile` (network rules), `CURSubfile`
  (cursors), `INISubfile`.
- **2D sprite props.** Some props have no S3D model at all: traffic lights, the animated
  balloons, the exploratorium crowd. Their exemplar's `ResourceKeyType0` points at an
  `ATCSubfile` (0x29A5D1EC) — a 48-byte header naming an FSH sprite sheet plus one
  `AVPSubfile` (0x09ADCD75) frame table per zoom 0..4. Each AVP frame names a sheet page,
  a pixel rectangle and an anchor pixel. `City.gd`'s "2D (sprite) props" section turns a
  frame into a camera-facing billboard quad (`_place_sprite`, `_resolve_sprite`).
- City-save subfile parsers (occupants placed in a city): `BuildingSubfile` (0xA9BD882D),
  `PropSubfile` (0x2977AA47) and `FloraSubfile` (0xA9C05C85) share one record family
  (Exemplar TGI marker + LE float bbox/position + orientation); `LotBaseTextureSubfile`
  (0xC97F987C) gives per-tile lot ground-texture FSH families (resolve at group
  0x0986135E, instance = family + zoom 0..4); `LotSubfile` (0xC9BD5D4A) is data-only
  (tile rect, zoning, wealth — SC4 denormalizes lot visuals into the other subfiles).
  All are rendered/loaded from `City.gd` (`load_buildings/load_props/load_flora/`
  `load_lot_textures/load_lots`).
- `GZWin*.gd` (`GZWin`, `GZWinBtn`, `GZWinText`, `GZWinBMP`, `GZWinFlatRect`, `GZWinGen`) —
  Godot `Control` wrappers for SC4's UI primitives.
- **To add a new SC4 file format:** create a new `extends DBPFSubfile` class in `addons/dbpf/`
  and register it in `Core.type_dict` / `Core.class_dict`.

### Subsystems

- **Region view** (`Region.gd`, `Region.tscn`): scans `Regions/<NAME>/` for `.sc4` city saves,
  reads `config.bmp` (via static `FileAccess.open`) for grid layout, and instantiates a
  `RegionCityView` (`RegionUI/RegionCityView.tscn`) per city from the `SC4ReadRegionalCity`
  subfile (location/size/population). Cities are placed on a `TileMapLayer` `BaseGrid`
  (`RegionGrid.gd`). `SC4UISubfile.gd` parses SC4's XML-like `.UI` layout DSL into a `Control`
  tree; `Region.gd`'s `custom_ui_classes` maps SC4 UI element hex IDs -> scripts in `RegionUI/`
  (one per widget).
- **City view** (`CityView/CityScene/City.gd`, `City.tscn`): builds a 3D terrain `ArrayMesh`
  from the `cSTETerrain__SaveAltitudes` heightmap (or a `FastNoiseLite` fallback), textures
  from FSH via `Texture2DArray` + a terrain shader (`CityView/Meshes/Terrain.gd`), a water
  plane (`CityView/Meshes/WaterPlane.gd`), and an S3D model demo. `CityView/ClassDefinitions/`
  holds the (future) transit network graph model (`NetGraphNode`, `NetGraphEdge`, etc.).
- **DAT Explorer** (`DATExplorer/`): a `Tree` browser over loaded DBPF archives with TGI
  filters and subfile previews. Dev tool.

### Threading

Single loader `Thread` in `BootScreen` plus `call_deferred` marshaling. **No `Mutex`,
`Semaphore`, or `WorkerThreadPool` anywhere** — keep it that way unless genuinely necessary.

### Conventions

**Indentation is 4 SPACES everywhere.** Keep the Godot editor's
`text_editor/behavior/indent/type` set to **spaces** (size 4).

## Notes

The save-file format work done here was moved out to the docs site
(`Open-Source-Modding/open-source-modding.github.io`):
- [SimCity 4 savegame format analysis](https://github.com/Open-Source-Modding/open-source-modding.github.io/blob/main/docs/simcity/sc4-savegame-format-analysis.md)
- [SimCity 4 known TGI ids](https://github.com/Open-Source-Modding/open-source-modding.github.io/blob/main/docs/simcity/sc4-known-tgi-ids.md)
