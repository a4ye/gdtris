class_name Tile

enum TileType {
	I_PIECE,
	J_PIECE,
	L_PIECE,
	O_PIECE,
	S_PIECE,
	T_PIECE,
	Z_PIECE,
	GHOST,
	GARBAGE,
	DISABLED,
	EMPTY,
}

enum State {
	EMPTY,
	PLACED,
	FALLING
}


# Sides that join another cell of the same piece, for the connected look (see block_skin.gd)
const UP = 1
const DOWN = 2
const LEFT = 4
const RIGHT = 8

var type: TileType
var state: State
# Set when the piece locks; a cleared row cuts the joins across it
var connections: int = 0

func _init(tile_type: TileType, tile_state: State):
	type = tile_type
	state = tile_state
