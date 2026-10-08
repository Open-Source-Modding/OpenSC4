extends DBPFSubfile

# Parses SC4's power-line subfiles from a city save. Power lines are stored as
# TWO cross-referencing subfiles, and this parser reads both:
#
#   0xC9C05C5D  cSC4PowerLineOccupant  -- one 85-byte record per wire span,
#                                         holding its tile and the memory
#                                         addresses of the two pylons it runs
#                                         between.
#   0x09C05C6A  cSC4PowerPoleOccupant  -- one variable-length record per pylon,
#                                         holding its Exemplar TGI (hence its
#                                         S3D model) and world position.
#
# Neither type is listed in sc4-savegame-format-analysis.md 4.4; both are absent
# from Big City Tutorial but present in six of the other shipped saves.
#
# The two are joined by memory address: a span names its two poles, and a pole
# names the spans hanging off it. Verified across five saves -- every pole
# reference in every span resolves to a pole record, and every span carries
# exactly two.
#
# PARTIAL BY DESIGN: a pole record's head (through position) is decoded and
# validated; its tail -- typically another 1.4 KB of per-span wire data -- is
# not, and no community parser decodes it either. We stop after the head and
# skip to the next record using the record's own size prefix, which is safe.
# The pylon models therefore place correctly; the wires are drawn as straight
# spans between pole positions rather than as SC4's exact sagging geometry.
class_name PowerLineSubfile

const LINE_MARKER : int = 0x0990b2ea
const POLE_MARKER : int = 0x2890d4de
const POLE_TYPE : int = 0x09c05c6a
const APPEARANCE_PRESENT : int = 0x01

# Fixed record offsets, verified across every save that has power lines.
const LINE_OFF_POSITION : int = 0x30
const LINE_OFF_TILE : int = 0x3c
const LINE_OFF_REFS : int = 0x45
const POLE_OFF_TGI : int = 0x24
const POLE_OFF_POSITION : int = 0x31   # odd-aligned, hence the explicit offset

class PowerLine:
    var appearance : int
    var position : Vector3        # metres, span midpoint
    var tile_x : int
    var tile_z : int
    var flag : int                # 0 or 1; meaning not established
    var pole_mems : Array         # always two; keys into PowerLineSubfile.poles

    func is_present() -> bool:
        return (appearance & APPEARANCE_PRESENT) != 0

# Field names follow the building/prop/flora occupant records so a pole drops
# straight into City._place_occupants().
class PowerPole:
    var appearance : int
    var exemplar_tgi : Array      # [type, group, instance] -- resolves to an S3D
    var position : Vector3        # metres; Y is up
    var pos_x : float             # metres
    var pos_z : float
    var altitude : float
    var orientation : int = 0     # not decoded; pylons are symmetric enough
    var mem : int                 # the key spans reference it by

    func is_present() -> bool:
        return (appearance & APPEARANCE_PRESENT) != 0

var lines : Array = []
var poles : Dictionary = {}       # mem -> PowerPole
var layout_failures : int = 0

func _init(index):
    super._init(index)

# Reads whichever of the two subfiles this instance was opened on; call
# load_poles() afterwards with the pole subfile's own DBPF index to fill in the
# other half.
func load(file, dbdf=null):
    super.load(file, dbdf)
    if index.type_id == POLE_TYPE:
        _parse_poles()
    else:
        _parse_lines()
    if layout_failures > 0:
        Log.warn("PowerLineSubfile: %d records failed a layout check" % layout_failures)
    return OK

func _parse_lines():
    var n = raw_data.size()
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        if _u32(pos + 0x14) != LINE_MARKER:
            Log.warn("PowerLineSubfile: span at %d failed the marker layout check" % pos)
            layout_failures += 1
            pos += size
            continue
        var line = PowerLine.new()
        line.appearance = raw_data[pos + 0x13]
        buf.seek(pos + LINE_OFF_POSITION)
        line.position = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
        line.tile_x = buf.get_u32()
        line.tile_z = buf.get_u32()
        line.flag = buf.get_u8()
        # Trailing (memory address, type id) pairs, one per pole. Always two.
        var at = pos + LINE_OFF_REFS
        while at + 8 <= pos + size:
            if _u32(at + 4) == POLE_TYPE:
                line.pole_mems.append(_u32(at))
            at += 8
        if line.pole_mems.size() != 2:
            Log.warn("PowerLineSubfile: span at %d references %d poles, expected 2"
                % [pos, line.pole_mems.size()])
            layout_failures += 1
        lines.append(line)
        pos += size

func _parse_poles():
    var n = raw_data.size()
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        if _u32(pos + 0x14) != POLE_MARKER:
            Log.warn("PowerLineSubfile: pole at %d failed the marker layout check" % pos)
            layout_failures += 1
            pos += size
            continue
        var pole = PowerPole.new()
        pole.mem = _u32(pos + 8)
        pole.appearance = raw_data[pos + 0x13]
        # Stored group, type, instance -- reordered to the [type, group,
        # instance] the rest of the engine passes around.
        var gid = _u32(pos + POLE_OFF_TGI)
        var tid = _u32(pos + POLE_OFF_TGI + 4)
        var iid = _u32(pos + POLE_OFF_TGI + 8)
        pole.exemplar_tgi = [tid, gid, iid]
        buf.seek(pos + POLE_OFF_POSITION)
        pole.position = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
        pole.pos_x = pole.position.x
        pole.altitude = pole.position.y
        pole.pos_z = pole.position.z
        poles[pole.mem] = pole
        pos += size

# Merges a separately-parsed pole subfile into this one.
func adopt_poles(other : PowerLineSubfile):
    for mem in other.poles.keys():
        poles[mem] = other.poles[mem]
    layout_failures += other.layout_failures
