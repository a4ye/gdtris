extends Control
# "GDTRIS" built from the game's blocks: each letter is one connected piece, in one piece colour.
# The letters drop into place one after another when the screen opens.

const BlockSkin = preload("res://src/base/block_skin.gd")
const WORD = ["G", "D", "T", "R", "I", "S"]
const KINDS = [Tile.TileType.I_PIECE, Tile.TileType.L_PIECE, Tile.TileType.T_PIECE,
	Tile.TileType.Z_PIECE, Tile.TileType.O_PIECE, Tile.TileType.S_PIECE]
# Every block touches the next one on a side, so each letter is drawn as one connected piece
# (a block that only touches at a corner would look like a separate piece)
const LETTERS = {
	"G": ["#####", "#....", "#.###", "#...#", "#####"],
	"D": ["####.", "#..##", "#...#", "#..##", "####."],
	"T": ["#####", "..#..", "..#..", "..#..", "..#.."],
	"R": ["#####", "#...#", "#####", "#..#.", "#..##"],
	"I": ["###", ".#.", ".#.", ".#.", "###"],
	"S": ["#####", "#....", "#####", "....#", "#####"],
}
const DROP_TIME = 0.45

var age = 0.0


func _process(delta):
	age += delta
	if age < 3.0:
		queue_redraw()


func word_width() -> int:
	var cells = len(WORD) - 1
	for letter in WORD:
		cells += len(LETTERS[letter][0])
	return cells


static func filled(rows: Array, row: int, col: int) -> bool:
	return row >= 0 and row < rows.size() and col >= 0 and col < len(rows[row]) and rows[row][col] == "#"


func _draw():
	var cell = size.y / 5.0
	var x = (size.x - word_width() * cell) / 2.0
	for i in len(WORD):
		var rows = LETTERS[WORD[i]]
		var t = clamp((age - 0.09 * i) / DROP_TIME, 0.0, 1.0)
		var fall = pow(1.0 - t, 3.0) * (size.y + 3 * cell)
		var alpha = clamp(t * 4.0, 0.0, 1.0)
		var color = MainGame.COLORS[KINDS[i]]
		for row in 5:
			for col in len(rows[row]):
				if not filled(rows, row, col):
					continue
				var joins = 0
				if filled(rows, row - 1, col):
					joins |= Tile.UP
				if filled(rows, row + 1, col):
					joins |= Tile.DOWN
				if filled(rows, row, col - 1):
					joins |= Tile.LEFT
				if filled(rows, row, col + 1):
					joins |= Tile.RIGHT
				var rect = Rect2(x + col * cell, row * cell - fall, cell, cell)
				draw_rect(Rect2(rect.position + Vector2(cell, cell) * 0.14, rect.size), Color(0, 0, 0, 0.35 * alpha))
				BlockSkin.draw(self, rect, color, joins, alpha)
		x += (len(rows[0]) + 1) * cell
