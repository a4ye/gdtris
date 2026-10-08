extends Node2D
# The bot's board in versus, to the right of the player's: its glass panel, stack and falling piece
# (no ghost, as TETR.IO shows an opponent), hold and queue, incoming garbage, name and speed, the
# round's countdown and result over it, and its attacks flying across to the player's garbage meter.
# MainGame (main) owns the match; this only draws.

const BlockSkin = preload("res://src/base/block_skin.gd")
const ACCENT = Color(0.62, 0.9, 0.78)
const RED = Color(1.0, 0.22, 0.26)
const GOLD = Color(1.0, 0.8, 0.32)
const ORB_LIFE = 0.33  # lands as the garbage becomes ready (Garbage.GARBAGE_DELAY)

var main  # MainGame
var player  # BotPlayer
var orbs = []  # the bot's attacks on their way: {"from", "lines", "age", "trail"}
# The bot's damage number, as the player's (mods/fx.gd): its attack, adding up while still shown
var clock := 0.0
var damage := 0
var damage_time := -99.0
var damage_pop := 0.0
const DAMAGE_HOLD = 1.0
const DAMAGE_FADE = 0.35


func _process(delta):
	clock += delta
	damage_pop *= exp(-9.0 * delta)
	for o in orbs:
		o["age"] += delta
		o["trail"].push_front(_orb_pos(o))
		if o["trail"].size() > 10:
			o["trail"].pop_back()
	orbs = orbs.filter(func(o): return o["age"] < ORB_LIFE)
	queue_redraw()


# The bot made an attack (before cancelling): its damage number grows
func on_attack(lines: int):
	if clock - damage_time > DAMAGE_HOLD + DAMAGE_FADE:
		damage = 0
	damage += lines
	damage_time = clock
	damage_pop = 1.0


# A new round: no number left over from the last one
func clear():
	damage = 0
	damage_time = -99.0
	orbs.clear()


# An attack leaves the bot's board for the player's meter
func launch(lines: int):
	var ts = main.tile_size
	var from = main.bot_grid_start + Vector2(5 * ts, 14 * ts)
	if not player.last_cells.is_empty():
		var sum = Vector2.ZERO
		for idx in player.last_cells:
			sum += Vector2(idx % 10 + 0.5, idx / 10 + 0.5)
		from = main.bot_grid_start + sum / player.last_cells.size() * ts
	orbs.append({"from": from, "lines": lines, "age": 0.0, "trail": []})


func _orb_pos(o: Dictionary) -> Vector2:
	var t = clamp(o["age"] / ORB_LIFE, 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	var a: Vector2 = o["from"]
	var b: Vector2 = main.grid_start + Vector2(-0.26 * main.tile_size, 21 * main.tile_size)
	var control = (a + b) * 0.5 + Vector2(0, -6.0 * main.tile_size)
	return a.lerp(control, t).lerp(control.lerp(b, t), t)


func _draw():
	if main == null or main.tile_size == null:
		return
	var ts: float = main.tile_size
	var gs: Vector2 = main.bot_grid_start
	var g: Game = player.game
	var font: Font = main.hud_font

	# The panel glows with the bot's back-to-back, as the player's does (mods/fx.gd)
	var rect = Rect2(gs.x, gs.y + 4 * ts, 10 * ts, 20 * ts)
	if main.fx != null and main.fx.has_method("draw_opponent_panel"):
		main.fx.draw_opponent_panel(self, gs, g.game_ended)
	else:
		draw_rect(rect.grow(0.22 * ts), Color(0, 0, 0, 0.28))
		draw_rect(rect, Color(0.015, 0.025, 0.02, 0.66))
		draw_rect(rect, Color(RED if g.game_ended else ACCENT, 0.55), false, 2.0)
	for i in range(10):
		for j in range(4, 24):
			draw_rect(Rect2(gs.x + i * ts, gs.y + j * ts, ts, ts), Color(1, 1, 1, 0.055), false, 2.0)

	for i in range(10):
		for j in range(24):
			var tile = g.board[i][j]
			if tile.type == Tile.TileType.EMPTY or tile.type == Tile.TileType.GHOST:
				continue
			BlockSkin.draw(self, Rect2(gs.x + i * ts, gs.y + j * ts, ts, ts), MainGame.COLORS[tile.type], MainGame.joins_in_game(g, i, j))

	# Hold, on the left, and the queue, on the right, as for the player
	var hold_label = font.get_string_size("HOLD", HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts)).x
	draw_string(font, Vector2(gs.x - ts - hold_label, gs.y + 5 * ts), "HOLD", HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts))
	if g.hold_piece != null:
		_draw_piece(g.hold_piece, gs + Vector2(-5 * ts, 6 * ts), ts, g.already_held)
	draw_string(font, Vector2(gs.x + 11 * ts, gs.y + 5 * ts), "QUEUE", HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts))
	for k in range(g.piece_queue.size()):
		_draw_piece(g.piece_queue[k], gs + Vector2(11 * ts, (6 + 3 * k) * ts), ts, false)

	main.draw_garbage_meter_on(self, g.garbage, gs)

	# Name and speed under the board
	var name = "BOT · LEVEL %d" % player.level
	var seconds = max(MainGame.time_elapsed, 0.001)
	var stats = "%.2f PPS · %.1f APM" % [player.pieces_placed / seconds, player.game.total_attack / seconds * 60.0]
	_centred(font, name, gs.x + 5 * ts, gs.y + 25.2 * ts, int(0.7 * ts), Color(1, 1, 1, 0.9))
	_centred(font, stats, gs.x + 5 * ts, gs.y + 26.2 * ts, int(0.55 * ts), Color(0.6, 0.67, 0.65))

	for o in orbs:
		var trail: Array = o["trail"]
		for k in range(trail.size()):
			var fade = 1.0 - float(k) / trail.size()
			draw_circle(trail[k], 0.22 * ts * fade, Color(RED, 0.3 * fade))
		var p = _orb_pos(o)
		draw_circle(p, 0.5 * ts, Color(RED, 0.15))
		draw_circle(p, 0.28 * ts, Color(RED, 0.5))
		draw_circle(p, 0.13 * ts, Color(1, 1, 1, 0.95))

	_draw_damage(font, gs, ts)

	# The round's countdown and result, over this board as over the player's
	var overlay = main.round_overlay(false)
	if not overlay.is_empty():
		var size = int(overlay[1] * ts)
		var w = font.get_string_size(overlay[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var at = Vector2(gs.x + 5 * ts - w / 2, gs.y + 14.5 * ts)
		draw_string_outline(font, at, overlay[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, int(0.18 * ts), Color(0.04, 0.02, 0.03, 0.9 * overlay[2].a))
		draw_string(font, at, overlay[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, overlay[2])


func _draw_damage(font: Font, gs: Vector2, ts: float):
	var age = clock - damage_time
	if damage <= 0 or age > DAMAGE_HOLD + DAMAGE_FADE:
		return
	var alpha = 1.0 - clamp((age - DAMAGE_HOLD) / DAMAGE_FADE, 0.0, 1.0)
	var color = Color(1, 1, 1)
	if damage >= 10:
		color = Color(1.0, 0.32, 0.28)
		alpha *= 0.7 if sin(clock * 30.0) < 0.0 else 1.0
	elif damage >= 4:
		color = GOLD
	var size = int((1.3 + 0.075 * min(damage, 20)) * ts)
	var scale = 1.0 + 0.45 * damage_pop
	var text = str(damage)
	var width = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var pos = Vector2(-width * 0.5, 0.36 * size)
	draw_set_transform(gs + Vector2(5.0 * ts, 18.0 * ts), -0.1, Vector2(scale, scale))
	draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, int(0.16 * ts), Color(0.05, 0.02, 0.03, 0.85 * alpha))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_piece(piece: Piece, at: Vector2, ts: float, greyed: bool):
	for r in range(piece.tiles.size()):
		for c in range(piece.tiles[r].size()):
			if piece.tiles[r][c].type == Tile.TileType.EMPTY:
				continue
			var type = Tile.TileType.GARBAGE if greyed else piece.tiles[r][c].type
			BlockSkin.draw(self, Rect2(at.x + c * ts, at.y + r * ts, ts, ts), MainGame.COLORS[type], BlockSkin.joins_in(piece.tiles, r, c))


func _centred(font: Font, text: String, x: float, y: float, size: int, color: Color):
	var w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(font, Vector2(x - w / 2, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
