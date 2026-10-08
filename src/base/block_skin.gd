extends RefCounted
# How a block looks: the "connected" skin. The cells of one piece join into one shape with no line
# inside it. Where the piece ends there is a light bevel along its top and left, a deeper one along
# its bottom and right, and a fine dark line against whatever is next to it. Drawn with shapes, not
# an image, so it is sharp at any size. tools/block_styles.py draws the same thing for its previews.

const BEVEL = 0.09  # parts of a cell
const LINE = 0.025


# joins: the sides that join another cell of the same piece (Tile.UP | Tile.DOWN | ...)
static func draw(canvas: CanvasItem, rect: Rect2, color: Color, joins: int, alpha: float = 1.0) -> void:
	var p = rect.position
	var s = rect.size
	# One flat colour for the body: a shade inside each cell would show a seam wherever two cells
	# of the same piece meet. The bevels along the piece's outer edges give it its depth.
	canvas.draw_rect(rect, Color(color, alpha))

	var b = max(1.0, s.x * BEVEL)
	var l = max(1.0, s.x * LINE)
	var up = (joins & Tile.UP) == 0
	var down = (joins & Tile.DOWN) == 0
	var left = (joins & Tile.LEFT) == 0
	var right = (joins & Tile.RIGHT) == 0
	# The bevel first, then the outline over it
	if up:
		canvas.draw_rect(Rect2(p.x, p.y, s.x, b), tint(color.lightened(0.45), 170, alpha))
	if left:
		canvas.draw_rect(Rect2(p.x, p.y, b, s.y), tint(color.lightened(0.3), 110, alpha))
	if down:
		canvas.draw_rect(Rect2(p.x, p.y + s.y - b, s.x, b), tint(color.darkened(0.3), 170, alpha))
	if right:
		canvas.draw_rect(Rect2(p.x + s.x - b, p.y, b, s.y), tint(color.darkened(0.3), 120, alpha))
	var line = tint(color.darkened(0.65), 230, alpha)
	if up:
		canvas.draw_rect(Rect2(p.x, p.y, s.x, l), line)
	if left:
		canvas.draw_rect(Rect2(p.x, p.y, l, s.y), line)
	if down:
		canvas.draw_rect(Rect2(p.x, p.y + s.y - l, s.x, l), line)
	if right:
		canvas.draw_rect(Rect2(p.x + s.x - l, p.y, l, s.y), line)


# The ghost: a flat, faint white, so a piece's ghost reads as one shape
static func draw_ghost(canvas: CanvasItem, rect: Rect2) -> void:
	canvas.draw_rect(rect, Color(1, 1, 1, 0.2))


static func tint(c: Color, alpha_255: int, alpha: float) -> Color:
	return Color(c, alpha_255 / 255.0 * alpha)


# Joins of the cell at (row, col) in a piece's tile grid (Piece.tiles), for the hold and the queue
static func joins_in(tiles: Array, row: int, col: int) -> int:
	var joins = 0
	if row > 0 and tiles[row - 1][col].type != Tile.TileType.EMPTY:
		joins |= Tile.UP
	if row < tiles.size() - 1 and tiles[row + 1][col].type != Tile.TileType.EMPTY:
		joins |= Tile.DOWN
	if col > 0 and tiles[row][col - 1].type != Tile.TileType.EMPTY:
		joins |= Tile.LEFT
	if col < tiles[row].size() - 1 and tiles[row][col + 1].type != Tile.TileType.EMPTY:
		joins |= Tile.RIGHT
	return joins
