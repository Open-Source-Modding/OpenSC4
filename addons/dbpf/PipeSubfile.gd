extends DBPFSubfile

# Parses SC4's pipe subfile (type 0x49C05B9F, cSC4PipeOccupant) from a city
# save: one record per water-pipe tile.
#
# NOTE ON THE TYPE ID: sc4-savegame-format-analysis.md 4.4 labels 0x49C05B9F the
# "prebuilt network subfile". That is wrong -- 0x49C05B9F is cSC4PipeOccupant,
# and the real prebuilt network is 0x49C1A034 (which appears in none of the
# shipped saves). Confirmed by record shape: 700-byte records whose trailing
# fields are pipe-specific (tile coordinate, four corner heights, side
# textures), all carrying networkType 4 = Pipe.
#
# Pipe records share the network family's head -- version, the 0xC772BF98
# marker, tract, sgprops, exemplar TGI, then position and four quad vertices --
# and then diverge: a 4x4 placement matrix, the tile coordinate, per-corner
# heights and the tunnel side/bottom texture strips that give the pipe its
# excavated trench when the underground view is on.
#
# Layout verified byte-exact (bytes consumed == record size) for all 483 records
# of Big City Tutorial. Matches the Pipe class of the `sc4` savegame library.
class_name PipeSubfile

const FAMILY_MARKER : int = 0xc772bf98
const APPEARANCE_PRESENT : int = 0x01

class PipeTile:
    var network_type : int        # always 4 (Pipe) in practice
    var appearance : int
    var texture_id : int          # network piece id (tile shape), not a ground texture
    var orientation : int
    var position : Vector3        # metres, tile centre
    var vertices : Array          # 4 Vertex, the trench's top face
    var west : int                # connection codes, as in the RUL edge tables
    var north : int
    var east : int
    var south : int
    var bbox : AABB
    var blocks : int
    var side_textures : Array     # 5 arrays of Vertex: west, north, east, south, bottom
    var tile_x : int              # absolute city tile
    var tile_z : int
    var diagonal_flipped : bool
    var corner_heights : Array    # metres: NW, SW, SE, NE
    var model_height : float      # metres
    var exemplar_tgi : Array

    func is_present() -> bool:
        return (appearance & APPEARANCE_PRESENT) != 0

var tiles : Array = []
var layout_failures : int = 0

func _init(index):
    super._init(index)

func load(file, dbdf=null):
    super.load(file, dbdf)
    var n = raw_data.size()
    var buf = StreamPeerBuffer.new()
    buf.data_array = raw_data
    var pos = 0
    while pos + 4 <= n:
        var size = _u32(pos)
        if size < 4 or pos + size > n:
            break
        var tile = _read_tile(buf, pos)
        if tile != null:
            tiles.append(tile)
        pos += size
    if layout_failures > 0:
        Log.warn("PipeSubfile: %d of %d records failed the record-size layout check"
            % [layout_failures, tiles.size() + layout_failures])
    return OK

func _read_tile(buf : StreamPeerBuffer, pos : int):
    buf.seek(pos)
    var header = _read_record_header(buf)
    var tile = PipeTile.new()

    buf.get_u16()                     # zot
    buf.get_u8()                      # unknown
    buf.get_u32()                     # unknown
    tile.appearance = buf.get_u8()
    if buf.get_u32() != FAMILY_MARKER:
        Log.warn("PipeSubfile: record at %d failed the family-marker layout check" % pos)
        layout_failures += 1
        return null
    buf.seek(buf.get_position() + 8)  # tract
    _read_sgprops(buf)
    tile.exemplar_tgi = [buf.get_u32(), buf.get_u32(), buf.get_u32()]
    buf.get_u8()                      # unknown
    buf.seek(buf.get_position() + 36) # 3x3 orientation matrix

    tile.position = Vector3(buf.get_float(), buf.get_float(), buf.get_float())
    tile.vertices = [_read_vertex(buf), _read_vertex(buf), _read_vertex(buf), _read_vertex(buf)]

    tile.texture_id = buf.get_u32()
    buf.seek(buf.get_position() + 5)  # unknown
    tile.orientation = buf.get_u8()
    buf.seek(buf.get_position() + 3)  # unknown
    tile.network_type = buf.get_u8()
    tile.west = buf.get_u8()
    tile.north = buf.get_u8()
    tile.east = buf.get_u8()
    tile.south = buf.get_u8()
    buf.get_u32()                     # unknown

    tile.bbox = _read_bbox(buf, true)
    buf.seek(buf.get_position() + 34) # unknown run, verified constant-width
    tile.blocks = buf.get_u32()
    for _side in range(5):            # west, north, east, south, bottom
        var strip : Array = []
        var count = buf.get_u32()
        for _i in range(count):
            strip.append(_read_vertex(buf))
        tile.side_textures.append(strip)
    buf.get_u32()                     # unknown
    buf.seek(buf.get_position() + 64) # 4x4 placement matrix

    tile.tile_x = buf.get_u32()
    tile.tile_z = buf.get_u32()
    tile.diagonal_flipped = buf.get_u8() != 0
    buf.get_u8()                      # side flag
    buf.get_u8()                      # side flag
    tile.corner_heights = [buf.get_float(), buf.get_float(), buf.get_float(), buf.get_float()]
    tile.model_height = buf.get_float()
    buf.get_u32()                     # the subfile's own type id, echoed
    buf.get_u32()                     # unknown
    buf.get_u32()                     # unknown

    if buf.get_position() - pos != header.size:
        Log.warn("PipeSubfile: record at %d consumed %d bytes, declared %d"
            % [pos, buf.get_position() - pos, header.size])
        layout_failures += 1
        return null
    return tile
