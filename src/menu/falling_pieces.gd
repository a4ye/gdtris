extends Node2D
# Faint pieces drifting down behind the menus, drawn with the game's own blocks

const COUNT = 18
const TILES = preload("res://assets/tiles.png")

var pieces = []
var rng = RandomNumberGenerator.new()


func _ready():
	rng.randomize()
	for i in COUNT:
		pieces.append(new_piece(true))


func new_piece(anywhere: bool) -> Dictionary:
	var size = get_viewport_rect().size
	var cell = size.y / 30.0 * rng.randf_range(0.8, 1.8)
	var kind = rng.randi_range(0, 6)
	return {
		"kind": kind,
		"rotation": 0 if kind == Piece.Pieces.O_PIECE else rng.randi_range(0, 3),
		"cell": cell,
		"x": rng.randf_range(-0.05, 0.95) * size.x,
		"y": rng.randf_range(-0.1, 1.0) * size.y if anywhere else -cell * 4.0 - rng.randf() * size.y * 0.4,
		"speed": cell * rng.randf_range(0.5, 1.3),
		# bigger pieces are nearer: a little brighter
		"alpha": rng.randf_range(0.045, 0.08) * cell / (size.y / 30.0),
	}


func _process(delta):
	var height = get_viewport_rect().size.y
	for i in pieces.size():
		pieces[i]["y"] += pieces[i]["speed"] * delta
		if pieces[i]["y"] > height + pieces[i]["cell"]:
			pieces[i] = new_piece(false)
	queue_redraw()


func _draw():
	for p in pieces:
		var shape = Piece.PIECE_ARRAYS[p["kind"]][p["rotation"]]
		var source = Rect2(16 * p["kind"], 0, 16, 16)
		for row in shape.size():
			for col in shape[row].size():
				if shape[row][col] == 1:
					var at = Vector2(p["x"] + col * p["cell"], p["y"] + row * p["cell"])
					draw_texture_rect_region(TILES, Rect2(at, Vector2(p["cell"], p["cell"])), source, Color(1, 1, 1, p["alpha"]))
