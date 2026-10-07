extends Control
# "GDTRIS" built from the game's blocks, one piece colour a letter. The blocks drop into place
# when the screen opens, letter after letter, bottom row first.

const TILES = preload("res://assets/tiles.png")
const WORD = ["G", "D", "T", "R", "I", "S"]
# Tile kinds (Tile.TileType order): I cyan, L orange, T purple, Z red, O yellow, S green
const KINDS = [0, 2, 5, 6, 3, 4]
const LETTERS = {
	"G": [".###.", "#....", "#.###", "#...#", ".###."],
	"D": ["####.", "#...#", "#...#", "#...#", "####."],
	"T": ["#####", "..#..", "..#..", "..#..", "..#.."],
	"R": ["####.", "#...#", "####.", "#..#.", "#...#"],
	"I": ["###", ".#.", ".#.", ".#.", "###"],
	"S": [".####", "#....", ".###.", "....#", "####."],
}
const DROP_TIME = 0.42

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


func _draw():
	var cell = size.y / 5.0
	var x = (size.x - word_width() * cell) / 2.0
	for i in len(WORD):
		var rows = LETTERS[WORD[i]]
		var source = Rect2(16 * KINDS[i], 0, 16, 16)
		for row in 5:
			for col in len(rows[row]):
				if rows[row][col] != "#":
					continue
				var delay = 0.08 * i + 0.03 * (4 - row)
				var t = clamp((age - delay) / DROP_TIME, 0.0, 1.0)
				var eased = 1.0 - pow(1.0 - t, 3.0)
				var fall = (1.0 - eased) * (size.y + 3 * cell)
				var rect = Rect2(x + col * cell, row * cell - fall, cell, cell)
				var alpha = clamp(t * 4.0, 0.0, 1.0)
				draw_rect(Rect2(rect.position + Vector2(cell, cell) * 0.14, rect.size), Color(0, 0, 0, 0.4 * alpha))
				draw_texture_rect_region(TILES, rect, source, Color(1, 1, 1, alpha))
		x += (len(rows[0]) + 1) * cell
