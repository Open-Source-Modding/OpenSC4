extends DBPFSubfile

# Parses the two lot-structure subfiles a city save carries alongside its
# networks -- the retaining walls and foundations SC4 builds under a lot when
# the ground beneath it is not flat:
#
#   0x49C05C8F  cSC4FoundationOccupant          82-byte records
#   0x49C05C9F  cSC4LotRetainingWallOccupant   104-byte records
#
# sc4-savegame-format-analysis.md 4.4 lists these as network-family subfiles
# ("unidentified ... subway/underground?" and "pipe subfile"). They are neither:
# they are lot decoration, and the pipes are 0x49C05B9F.
#
# Both share the occupant head -- version 2.4, a family marker, tract, sgprops,
# then the Exemplar TGI with the instance id repeated -- and then carry a
# placement block that no community parser documents. It was decoded here:
#
#   f32 x, f32 y, f32 z, f32 size_x, f32 height, f32 size_z    (all metres)
#
# Evidence: with this reading, 100% of the 1,245 walls and 2,510 foundations in
# Big City Tutorial have their centre on a tile covered by a lot, and the median
# of (y - terrain altitude at that tile) is exactly 0.00 m. Reading the block
# with x and z transposed drops the lot-coverage hit rate to ~55%, and size_x /
# size_z take only tile-multiple values (16, 32, 48, 64 m = 1..4 tiles), so the
# assignment is not ambiguous.
class_name LotStructureSubfile

const FOUNDATION_TYPE : int = 0x49c05c8f
const WALL_TYPE : int = 0x49c05c9f
const FOUNDATION_MARKER : int = 0x68fd0c69
const WALL_MARKER : int = 0x895d1169
const APPEARANCE_PRESENT : int = 0x01

const OFF_TGI : int = 0x24
# The placement block sits after a type-specific run of undecoded fields: a
# single dword for foundations, and (dword, dword, 8 bytes, dword) for walls.
const FOUNDATION_OFF_PLACEMENT : int = 0x38
const WALL_OFF_PLACEMENT : int = 0x48

# Field names match the building/prop/flora occupant records so these drop
# straight into City._place_occupants().
class LotStructure:
    var appearance : int
    var exemplar_tgi : Array      # [type, group, instance]
    var pos_x : float             # metres, centre of the structure
    var pos_z : float
    var altitude : float          # metres, matches the terrain at that point
    var orientation : int = 0     # not present in the record
    var size_x : float            # metres, a multiple of the 16 m tile
    var size_z : float
    var height : float            # metres

    func is_present() -> bool:
        return (appearance & APPEARANCE_PRESENT) != 0

var structures : Array = []
var layout_failures : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    var is_wall = index.type_id == WALL_TYPE
    var marker = WALL_MARKER if is_wall else FOUNDATION_MARKER
    var off_placement = WALL_OFF_PLACEMENT if is_wall else FOUNDATION_OFF_PLACEMENT
    var n = raw_data.size()
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        if pos + off_placement + 24 > pos + size or _u32(pos + 0x14) != marker:
            Log.warn("LotStructureSubfile: record at %d failed the marker layout check" % pos)
            layout_failures += 1
            pos += size
            continue
        var s = LotStructure.new()
        s.appearance = raw_data[pos + 0x13]
        # Stored group, type, instance; reordered to [type, group, instance].
        var gid = _u32(pos + OFF_TGI)
        var tid = _u32(pos + OFF_TGI + 4)
        var iid = _u32(pos + OFF_TGI + 8)
        s.exemplar_tgi = [tid, gid, iid]
        buf.seek(pos + off_placement)
        s.pos_x = buf.get_float()
        s.altitude = buf.get_float()
        s.pos_z = buf.get_float()
        s.size_x = buf.get_float()
        s.height = buf.get_float()
        s.size_z = buf.get_float()
        structures.append(s)
        pos += size
    if layout_failures > 0:
        Log.warn("LotStructureSubfile: %d of %d records failed a layout check"
            % [layout_failures, structures.size() + layout_failures])
    return OK
