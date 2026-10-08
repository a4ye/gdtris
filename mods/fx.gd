extends Node2D
# Visual effects for GDTris: board motion, clear effects, spin callouts and post processing.
# This node is a child of the MainGame node (graphics.gd), so everything it draws moves with
# the board. It only reads the game state; it never changes the game.
#
# Presets:
#   "curated": row flash (and lightning for a big spike), particles, shockwave, chromatic
#              aberration, spin/quad callouts with B2B and the damage number,
#              hard drop trails, bloom, spin sparks and flash, lock sparkles, glass board panel,
#              lens grade (vignette, grain, colour), perfect clear sweep and title
#   "all":     curated + camera punch, attack orbs and a SENT counter, outlined ghost,
#              blurred background, slow camera drift, denser particles
# The clear shockwave (a TETR.IO-style ripple packet) scales with the attack (lines sent, TETR.IO
# rules) of the current burst: every clear adds its attack, and the burst lasts while each clear
# comes within SPIKE_WINDOW (1 s) of the last one, whatever is placed in between. Below WAVE_MIN
# (10) there is no ripple; from there
#   WAVE_PEAK * lerp(WAVE_FLOOR, 1, ((burst - WAVE_MIN) / (WAVE_TOP - WAVE_MIN)) ^ rate)
# screen heights, a quarter of full strength at 10 and all of it at WAVE_TOP (100). That is then
# multiplied by this clear's own attack / WAVE_UNIT (6), so a clear that sends 6 lines ripples at
# 1x and one that sends nothing does not ripple at all. Add "@<rate>" to the preset to set the
# rate, e.g. "curated@1.5"; the default is 1.0 (linear). Rate 0 gives full strength from 10 on.
# A comma separated list of names works as a preset too. "motion" (board springs on inputs),
# "shake" (screen shake on clears) and "ca_pulse" (aberration spikes on clears) are in "game" only:
# they answer the hands rather than the camera, which is too bouncy to film but is the point when
# somebody is playing.
#
#   "game": everything that answers an input or a clear. This is the preset for the real game.
#           Left out of it on purpose: "camera", a slow zoom and tilt that never stops. It reads
#           well in a video and badly under a player, who is lining pieces up against the walls.

const PRESETS = {
	"curated": ["flash", "particles", "wave", "ca", "callouts", "trail", "bloom",
		"spinflash", "sparkles", "panel", "lens", "perfect"],
	"all": ["flash", "particles", "wave", "ca", "callouts", "trail", "bloom",
		"spinflash", "sparkles", "panel", "lens", "perfect",
		"punch", "attack", "ghost", "bgblur", "camera", "dense"],
	"game": ["flash", "particles", "wave", "ca", "callouts", "trail", "bloom",
		"spinflash", "sparkles", "panel", "lens", "perfect",
		"punch", "attack", "ghost", "bgblur", "dense",
		"motion", "shake", "ca_pulse"],
}

const T_COLOR = Color(0.86, 0.36, 1.0)
const QUAD_COLOR = Color(0.3, 0.95, 1.0)
const B2B_COLOR = Color(1.0, 0.8, 0.32)
const DANGER_COLOR = Color(1.0, 0.18, 0.22)

var g  # the MainGame node
var on := {}
var grid_alpha := 0.1

# Board motion: damped springs kicked by inputs, plus trauma based shake for clears
var spring_pos := Vector2.ZERO
var spring_vel := Vector2.ZERO
var spring_ang := 0.0
var spring_ang_vel := 0.0
var trauma := 0.0
var punch := 0.0
var clock := 0.0

var flashes := []
var particles := []
var sparkles := []
var trails := []
var locks := []
var spin_sparks := []  # off a piece that a rotation spins in
var spin_glow := {}  # the flash on that piece, and the ring in its shape
const SPIN_RING_LIFE := 0.35
var orbs := []
var callout := []
var callout_age := 99.0
# Versus: the opponent's (the bot's) effects on its own board (opponent_clear)
var opp_origin := Vector2.ZERO  # its grid_start
var opp_callout := []
var opp_callout_age := 99.0
var opp_b2b := -1
var opp_spike := 0
var opp_spike_time := -99.0
var b2b := -1
# Danger (the game's danger check), eased: 0 safe, about 0.45 near the top, 1 when the next
# placement would kill. It drives the red border, the red light on the board and the screen edges.
var danger_level := 0.0
var danger_phase := 0.0
# TETR.IO's damage number: the attack sent, adding up while the number is still on screen. It
# stays DAMAGE_HOLD after it last grew, then fades over DAMAGE_FADE.
var damage := 0
var damage_time := -99.0
var damage_pop := 0.0
const DAMAGE_HOLD := 1.0
const DAMAGE_FADE := 0.35
# With the game's thunder (MainGame.THUNDER_STEPS): as the damage number passes 10, 18 and 26 lines
# the screen flickers like lightning, 0.12 s after the clear, with the thunder's crack
const LIGHTNING_STEPS := [10, 18, 26]
var lightning_age := 99.0
var lightning_strength := 0.0
var spike := 0  # attack sent in the current burst of clears
var spike_time := -99.0  # clock at the burst's last clear
const SPIKE_WINDOW := 1.0  # seconds a burst waits for its next clear
var last_time := 0.0  # the game clock as of the last frame, to see a restart
var sent := 0
var sent_pop := 0.0

var post: ShaderMaterial
var waves := []
var ca := 0.0
var ca_center := Vector2(0.5, 0.5)

# Falling piece as of the last check, to tell rotations, moves and gravity apart
var snap_piece = null
var snap_coords := []
var snap_rot := 0
var last_rot := false

var add_layer: Node2D
var text_layer: Node2D
var wave_rate := 1.0
const WAVE_PEAK := 0.0184  # amplitude at WAVE_TOP for a 1x clear, in screen heights
const WAVE_MIN := 10.0  # burst attack that starts the ripple
const WAVE_FLOOR := 0.25  # strength at WAVE_MIN, as a part of WAVE_PEAK
const WAVE_TOP := 100.0  # burst attack that reaches full strength
const WAVE_UNIT := 6.0  # attack of one clear that ripples at 1x

# Perfect clear: a front of light runs out from the clear over the empty board, lighting each cell
# in the piece colours and lifting motes of light; the board's border flares; then PERFECT (one
# letter per piece colour, like the logo) and CLEAR drop in over the middle of the board.
const PC_LIFE := 2.2
const PC_STEP := 0.03  # seconds the light front takes per cell
const PC_HUES := [Tile.TileType.Z_PIECE, Tile.TileType.L_PIECE, Tile.TileType.O_PIECE,
	Tile.TileType.S_PIECE, Tile.TileType.I_PIECE, Tile.TileType.J_PIECE, Tile.TileType.T_PIECE]
var pc_age := 99.0
var pc_origin := Vector2.ZERO  # in cells
var motes := []


func setup(main, preset: String):
	g = main
	if "@" in preset:
		wave_rate = float(preset.get_slice("@", 1))
		preset = preset.get_slice("@", 0)
	for name in PRESETS[preset] if PRESETS.has(preset) else preset.split(","):
		on[name.strip_edges()] = true
	if on.has("panel"):
		grid_alpha = 0.055

	add_layer = Node2D.new()
	var add_material = CanvasItemMaterial.new()
	add_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	add_layer.material = add_material
	add_layer.draw.connect(_draw_add)
	add_child(add_layer)
	text_layer = Node2D.new()
	text_layer.draw.connect(_draw_text)
	add_child(text_layer)
	# Above everything else in the scene, the bot's board in versus too (it is drawn after the game)
	add_layer.z_index = 10
	text_layer.z_index = 10

	# Replaces the game's chromatic aberration pass (that node is hidden in game.tscn)
	post = ShaderMaterial.new()
	post.shader = load("res://mods/post_fx.gdshader")
	var post_rect = g.get_parent().get_node("CanvasLayer/ColorRect")
	post_rect.material = post
	post_rect.visible = true
	if on.has("bgblur"):
		var blur = ShaderMaterial.new()
		blur.shader = load("res://mods/bg_blur.gdshader")
		g.get_parent().get_node("CanvasLayer2/TextureRect").material = blur
	_snapshot()


func _unit() -> float:
	return g.tile_size / 40.0


func _snapshot():
	snap_piece = g.game.current_piece
	snap_coords = g.game.current_piece_coordinates.duplicate()
	snap_rot = g.game.current_piece.rotation


func _nudge(now: Array):
	if not on.has("motion") or now.is_empty() or snap_coords.is_empty():
		return
	var dx = now[0].x - snap_coords[0].x
	var dy = now[0].y - snap_coords[0].y
	var u = _unit()
	if dx != 0:
		spring_vel.x += sign(dx) * (75.0 + 7.0 * min(abs(dx), 8.0)) * u
	if dy > 0:
		spring_vel.y += (55.0 + 4.0 * dy) * u


# Called after every key press the game handles (taps, rotations, soft drop, hold)
func after_input(keycode):
	if keycode == GameConfig.get_setting("controls", "hard_drop"):
		return
	if g.game.current_piece != snap_piece:
		# Hold swapped the piece
		last_rot = false
		if on.has("motion"):
			spring_vel.y -= 70.0 * _unit()
		_snapshot()
		return
	var now = g.game.current_piece_coordinates.duplicate()
	if g.game.current_piece.rotation != snap_rot:
		last_rot = true
		var dir := 1.0
		if keycode == GameConfig.get_setting("controls", "rotate_ccw"):
			dir = -1.0
		elif keycode == GameConfig.get_setting("controls", "rotate_180"):
			dir = 1.5 if randf() < 0.5 else -1.5
		if on.has("motion"):
			spring_ang_vel += 0.24 * dir
		if on.has("spinflash"):
			var spin = _rotation_spin()
			if spin != 0:
				_spin_burst(sign(dir), spin == 1)
	elif now != snap_coords:
		last_rot = false
		_nudge(now)
	_snapshot()


func before_hard_drop() -> Dictionary:
	var game = g.game
	var piece = game.current_piece
	var cells = game.current_piece_coordinates.duplicate()
	var landing = game.ghost_coordinates.duplicate()
	var types := []
	for x in range(10):
		var column := []
		for y in range(24):
			var tile = game.board[x][y]
			column.append(tile.type if tile.state == Tile.State.PLACED else Tile.TileType.EMPTY)
		types.append(column)
	var drop := 0
	if not cells.is_empty() and not landing.is_empty():
		drop = int(landing[0].y - cells[0].y)
	# 3-corner rule, and the last successful movement must be a rotation
	var tspin := false
	if piece.piece_type == Piece.Pieces.T_PIECE and last_rot and drop == 0:
		tspin = _t_corners() >= 3
	return {
		"color": MainGame.COLORS[piece.tile_type], "cells": cells, "landing": landing,
		"types": types, "drop": drop, "tspin": tspin,
	}


# Filled corners around the falling T's centre (walls and floor count)
func _t_corners() -> int:
	var game = g.game
	var centre = game.current_piece_top_left_corner + Vector2(1, 1)
	var corners := 0
	for d in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var p = centre + d
		if p.x < 0 or p.x >= 10 or p.y >= 24 or (p.y >= 0 and game.board[p.x][p.y].state == Tile.State.PLACED):
			corners += 1
	return corners


# The spin the last rotation made (0 none, 1 mini, 2 full): the game's own call (TETR.IO rules)
# when it makes one; an older game does not, and then a T in 3 filled corners counts
func _rotation_spin() -> int:
	var spin = g.game.get("last_spin")
	if spin != null:
		return spin
	return 2 if g.game.current_piece.piece_type == Piece.Pieces.T_PIECE and _t_corners() >= 3 else 0


# As in TETR.IO, a rotation that makes a spin lights up the piece before it locks: sparks burst off
# it and swirl the way it turned (dir 1 clockwise, -1 the other way), stars twinkle on and around
# it, it flashes, and a ring in its shape runs out from it. A mini gets fewer sparks and stars.
func _spin_burst(dir: float, mini: bool):
	var cells = g.game.current_piece_coordinates
	if cells.is_empty():
		return
	var ts = g.tile_size
	var gs = g.grid_start
	var u = _unit()
	var centre := Vector2.ZERO
	for p in cells:
		centre += p
	centre = gs + (centre / cells.size() + Vector2(0.5, 0.5)) * ts
	var piece = g.game.current_piece
	var color = T_COLOR if piece.piece_type == Piece.Pieces.T_PIECE else MainGame.COLORS[piece.tile_type]
	for i in range(20 if mini else 44):
		var pos = gs + (cells[randi() % cells.size()] + Vector2(randf(), randf())) * ts
		var out = (pos - centre).normalized() if pos.distance_to(centre) > 1.0 else Vector2.RIGHT.rotated(randf() * TAU)
		# Screen y points down, so turning a vector by +90 degrees turns it clockwise. A lift toward
		# the top: a spun piece is in a slot, with the stack around it and open board above it.
		var heading = (out + out.rotated(PI / 2 * dir) * 0.8 + Vector2(0, -0.5)).normalized()
		spin_sparks.append({
			"pos": pos, "vel": heading * randf_range(320.0, 760.0) * u * (0.7 if mini else 1.0),
			"age": 0.0, "life": randf_range(0.35, 0.6), "size": randf_range(0.1, 0.2) * ts,
			"color": color.lerp(Color(1, 1, 1), randf_range(0.05, 0.5)),
		})
	# The stars: drawn with the lock sparkles, and some start a little late, so they keep coming
	for i in range(8 if mini else 16):
		sparkles.append({
			"pos": gs + (cells[randi() % cells.size()] + Vector2(randf_range(-0.25, 1.25), randf_range(-0.25, 1.25))) * ts,
			"vel": Vector2(randf_range(-40.0, 40.0), randf_range(-70.0, -10.0)) * u,
			"age": -randf_range(0.0, 0.18), "life": randf_range(0.45, 0.75), "size": randf_range(0.28, 0.5) * ts,
			"phase": randf() * TAU, "spin": randf_range(-3.0, 3.0),
			"color": color.lerp(Color(1, 1, 1), randf_range(0.2, 0.6)),
		})
	spin_glow = {"piece": piece, "cells": cells.duplicate(), "age": 0.0, "color": color}


func after_hard_drop(pre: Dictionary, info: Dictionary):
	var u = _unit()
	var ts = g.tile_size
	var gs = g.grid_start
	var rows = info["lines_cleared"]
	var lines = rows.size()
	var color: Color = pre["color"]

	# Survival: garbage rose under the piece as it locked. The rows flash red, and the piece's own
	# effects follow it up.
	# (On a top out the game has usually started again, and then there is nothing to flash; in
	# versus the last board stays, with the garbage that topped the player out)
	var tanked: int = info.get("tanked", 0)
	if tanked > 0 and (not info.get("topped_out", false) or g.game.game_ended):
		var risen = []
		for p in pre["landing"]:
			risen.append(p - Vector2(0, tanked))
		pre["landing"] = risen
		if on.has("flash"):
			for r in range(24 - tanked, 24):
				flashes.append({"y": r, "age": 0.0, "color": DANGER_COLOR})
		if on.has("shake"):
			trauma = min(1.0, trauma + 0.06 * tanked)

	if on.has("trail") and pre["drop"] > 0:
		var columns := {}
		for p in pre["cells"]:
			columns[int(p.x)] = min(columns.get(int(p.x), 99), p.y)
		var bottoms := {}
		for p in pre["landing"]:
			bottoms[int(p.x)] = max(bottoms.get(int(p.x), -1), p.y)
		for x in columns:
			trails.append({"x": x, "top": columns[x], "bottom": bottoms[x] + 1, "age": 0.0, "color": color})
	if on.has("sparkles"):
		_lock_sparkles(pre["landing"])
	if on.has("motion"):
		spring_vel.y += (115.0 + 9.0 * pre["drop"]) * u
	last_rot = false
	_snapshot()

	# The game reports the spin (TETR.IO's rules: minis, and spins of any piece) and its attack and
	# back-to-back; an older game does not, and then this works them out itself, T-spins only
	var spin: int = info.get("spin", 2 if pre["tspin"] else 0)  # 0 none, 1 mini, 2 full
	var piece: int = info.get("piece", Piece.Pieces.T_PIECE)
	var spun = spin != 0

	if lines == 0:
		if spun and on.has("callouts"):
			_set_callout(_spin_callout(spin, piece))
		return

	var difficult: bool = spun or lines == 4
	b2b = info.get("b2b", b2b + 1 if difficult else -1)

	var cx := 0.0
	for p in pre["landing"]:
		cx += p.x
	cx /= max(1, pre["landing"].size())
	var cy := 0.0
	for r in rows:
		cy += r
	cy /= lines
	var centre = gs + Vector2((cx + 0.5) * ts, (cy + 0.5) * ts)
	var big = 1.0 + (0.35 if lines == 4 else 0.0) + (0.15 if spun else 0.0) + 0.04 * min(max(b2b, 0), 10)
	var attack: int = info.get("attack", _attack(pre["tspin"], lines))
	if on.has("callouts") and attack > 0:
		if clock - damage_time > DAMAGE_HOLD + DAMAGE_FADE:
			damage = 0
		var before = damage
		damage += attack
		damage_time = clock
		damage_pop = 1.0
		if on.has("flash"):
			for k in range(LIGHTNING_STEPS.size()):
				if before < LIGHTNING_STEPS[k] and damage >= LIGHTNING_STEPS[k]:
					lightning_age = -0.12
					lightning_strength = 0.6 + 0.2 * k
	# A burst goes on while each clear comes within SPIKE_WINDOW of the last one; pieces placed in
	# between with no clear do not end it
	if clock - spike_time > SPIKE_WINDOW:
		spike = 0
	spike += attack
	spike_time = clock
	# Ripple amplitude in screen heights, and the packet width, from the burst's attack, scaled by
	# this clear's own attack. Nothing below WAVE_MIN; WAVE_PEAK is reached at WAVE_TOP.
	var ramp = clamp((float(spike) - WAVE_MIN) / (WAVE_TOP - WAVE_MIN), 0.0, 1.0)
	var wave_scale = 0.0
	if spike >= WAVE_MIN:
		wave_scale = WAVE_PEAK * lerp(WAVE_FLOOR, 1.0, pow(ramp, wave_rate)) * attack / WAVE_UNIT
	var wave_size = 0.85 + 0.3 * ramp

	if on.has("flash"):
		for r in rows:
			flashes.append({"y": r, "age": 0.0})
	if on.has("particles"):
		var per_cell = 3 if on.has("dense") else 2
		for r in rows:
			for x in range(10):
				var t = pre["types"][x][r]
				var c: Color = MainGame.COLORS[t] if t != Tile.TileType.EMPTY and MainGame.COLORS.has(t) else color
				for i in range(per_cell):
					particles.append({
						"pos": gs + Vector2((x + 0.5 + randf_range(-0.35, 0.35)) * ts, (r + 0.5 + randf_range(-0.3, 0.3)) * ts),
						"vel": Vector2((x - cx) * 34.0 + randf_range(-170.0, 170.0), randf_range(-520.0, -140.0)) * u,
						"age": 0.0, "life": randf_range(0.45, 0.95), "size": randf_range(0.11, 0.24) * ts,
						"color": c.lerp(Color(1, 1, 1), 0.3),
					})
	if on.has("shake"):
		trauma = min(1.0, trauma + 0.3 * big)
	if on.has("motion"):
		spring_vel.y += 150.0 * u * big
	if on.has("punch"):
		punch += 0.011 * big
	var uv = _screen_uv(centre)
	# A silent wave would still take one of the shader's four slots from a live one
	if on.has("wave") and wave_scale > 0.0:
		waves.append({"c": uv, "age": 0.0, "s": wave_scale, "z": wave_size})
	if on.has("ca_pulse"):
		ca += 0.006 * big
		ca_center = uv
	var spin_color = T_COLOR if piece == Piece.Pieces.T_PIECE else color
	if on.has("callouts"):
		_callout_for(spin, piece, lines)
	if on.has("spinflash") and spun:
		locks.append({"cells": pre["landing"], "age": 0.0, "life": 0.32, "color": spin_color, "grow": 0.35})
	# The attack flies to the SENT counter or, in versus, to the bot's garbage meter, and then it is
	# only what the attack did not cancel
	var target = g.get("attack_target")
	var outgoing = attack if target == null else attack - info.get("blocked", 0)
	if (on.has("attack") or target != null) and outgoing > 0:
		orbs.append({
			"from": centre, "age": 0.0, "life": 0.46 if target == null else 0.33, "attack": outgoing,
			"color": spin_color if spun else QUAD_COLOR, "trail": [],
		})
	if on.has("perfect") and info.get("is_perfect_clear", false):
		_perfect_clear(Vector2(cx + 0.5, cy + 0.5))


# Versus: the bot placed a piece on its board at origin (cells: where it went, board indices
# y * 10 + x). It gets what the player's clears get, on its own board: the callout with its
# back-to-back, row flashes and particles, and a shockwave from its own spike (by the same rule as
# the player's). Its damage number and attack orbs are drawn by the bot's view.
func opponent_clear(origin: Vector2, info: Dictionary, cells: PackedInt32Array):
	opp_origin = origin
	var ts = g.tile_size
	var u = _unit()
	var rows = info["lines_cleared"]
	var lines = rows.size()
	var spin: int = info.get("spin", 0)
	var piece: int = info.get("piece", Piece.Pieces.T_PIECE)
	if lines == 0:
		if spin != 0 and on.has("callouts"):
			opp_callout = _spin_callout(spin, piece)
			opp_callout_age = 0.0
		return
	opp_b2b = info["b2b"]
	var cx := 4.5
	if not cells.is_empty():
		cx = 0.0
		for idx in cells:
			cx += idx % 10
		cx /= cells.size()
	var cy := 0.0
	for r in rows:
		cy += r
	cy /= lines
	var centre = origin + Vector2((cx + 0.5) * ts, (cy + 0.5) * ts)
	var attack: int = info["attack"]
	if clock - opp_spike_time > SPIKE_WINDOW:
		opp_spike = 0
	opp_spike += attack
	opp_spike_time = clock
	var ramp = clamp((float(opp_spike) - WAVE_MIN) / (WAVE_TOP - WAVE_MIN), 0.0, 1.0)
	if on.has("wave") and opp_spike >= WAVE_MIN and attack > 0:
		var scale = WAVE_PEAK * lerp(WAVE_FLOOR, 1.0, pow(ramp, wave_rate)) * attack / WAVE_UNIT
		waves.append({"c": _screen_uv(centre), "age": 0.0, "s": scale, "z": 0.85 + 0.3 * ramp})
	var color: Color = MainGame.COLORS[Piece.new(piece).tile_type]
	if on.has("flash"):
		for r in rows:
			flashes.append({"y": r, "age": 0.0, "origin": origin})
	if on.has("particles"):
		for r in rows:
			for x in range(10):
				for i in range(2):
					particles.append({
						"pos": origin + Vector2((x + 0.5 + randf_range(-0.35, 0.35)) * ts, (r + 0.5 + randf_range(-0.3, 0.3)) * ts),
						"vel": Vector2((x - cx) * 34.0 + randf_range(-170.0, 170.0), randf_range(-520.0, -140.0)) * u,
						"age": 0.0, "life": randf_range(0.45, 0.95), "size": randf_range(0.11, 0.24) * ts,
						"color": color.lerp(Color(1, 1, 1), 0.3),
					})
	if on.has("callouts"):
		opp_callout = _callout_items(spin, piece, lines, opp_b2b)
		if info.get("is_perfect_clear", false):
			opp_callout.append({"text": "PERFECT CLEAR", "size": 0.8, "color": B2B_COLOR})
		opp_callout_age = 0.0


func _perfect_clear(origin: Vector2):
	pc_age = 0.0
	pc_origin = origin
	var ts = g.tile_size
	var u = _unit()
	# The motes wait (negative age) until the light front reaches their cell
	for x in range(10):
		for y in range(4, 24):
			if randf() > 0.3:
				continue
			var cell = Vector2(x + 0.5, y + 0.5)
			var d = cell.distance_to(origin)
			motes.append({
				"pos": g.grid_start + (cell + Vector2(randf_range(-0.4, 0.4), randf_range(-0.4, 0.4))) * ts,
				"vel": Vector2(randf_range(-25.0, 25.0), -randf_range(50.0, 150.0)) * u,
				"age": -d * PC_STEP, "life": randf_range(0.7, 1.3), "size": randf_range(0.05, 0.1) * ts,
				"color": _pc_color(d).lerp(Color(1, 1, 1), 0.35), "phase": randf() * TAU,
			})


# The piece colours in rainbow order, blended, by distance (in cells) from the clear
func _pc_color(d: float) -> Color:
	var p = fposmod(d * 0.3, PC_HUES.size())
	var i = int(p)
	return MainGame.COLORS[PC_HUES[i]].lerp(MainGame.COLORS[PC_HUES[(i + 1) % PC_HUES.size()]], p - i)


# 1 at the perfect clear, fading over about a second
func _pc_flare() -> float:
	return exp(-pc_age * 2.5) if pc_age < PC_LIFE else 0.0


# Lines sent for a clear, TETR.IO rules (no combo): base by clear type plus the B2B bonus,
# which steps up at B2B x1, x3, x8, x24, x67, ...
func _attack(tspin: bool, lines: int) -> int:
	var base = [0, 2, 4, 6, 6][lines] if tspin else [0, 0, 1, 2, 4][lines]
	if b2b >= 1 and (tspin or lines == 4):
		for level in [1, 3, 8, 24, 67, 185, 504, 1370]:
			if b2b >= level:
				base += 1
	return base


# White twinkling stars off the edges of a piece as it locks
func _lock_sparkles(cells: Array):
	if cells.is_empty():
		return
	var ts = g.tile_size
	var gs = g.grid_start
	var u = _unit()
	var centre := Vector2.ZERO
	for p in cells:
		centre += p
	centre = gs + (centre / cells.size() + Vector2(0.5, 0.5)) * ts
	for p in cells:
		for i in range(3):
			# A random point on the cell border
			var side = randi() % 4
			var t = randf()
			var local = [Vector2(t, 0), Vector2(1, t), Vector2(t, 1), Vector2(0, t)][side]
			var pos = gs + (p + local) * ts
			var out = (pos - centre).normalized() if pos != centre else Vector2.UP
			sparkles.append({
				"pos": pos, "vel": out * randf_range(25.0, 85.0) * u + Vector2(0, -randf_range(10.0, 45.0)) * u,
				"age": 0.0, "life": randf_range(0.3, 0.6), "size": randf_range(0.17, 0.32) * ts,
				"phase": randf() * TAU, "spin": randf_range(-3.0, 3.0),
			})


func _screen_uv(p: Vector2) -> Vector2:
	var screen = g.get_global_transform_with_canvas() * p
	return screen / get_viewport_rect().size


func _new_run():
	b2b = -1
	spike = 0
	spike_time = -99.0
	sent = 0
	sent_pop = 0.0
	orbs.clear()
	callout = []
	pc_age = 99.0
	motes.clear()
	damage = 0
	damage_time = -99.0
	lightning_age = 99.0
	opp_callout = []
	opp_b2b = -1
	opp_spike = 0
	opp_spike_time = -99.0
	spin_sparks.clear()
	spin_glow = {}


func _set_callout(items: Array):
	callout = items
	callout_age = 0.0


# "T-SPIN", "T-SPIN MINI", "S-SPIN MINI" ...: the piece's letter, in its colour (T in the T colour)
func _spin_callout(spin: int, piece: int) -> Array:
	var letter = "IJLOSTZ"[piece]
	var color = T_COLOR if piece == Piece.Pieces.T_PIECE else MainGame.COLORS.get(piece, T_COLOR)
	var text = "%s-SPIN%s" % [letter, " MINI" if spin == 1 else ""]
	return [{"text": text, "size": 0.72, "color": color}]


func _callout_for(spin: int, piece: int, lines: int):
	_set_callout(_callout_items(spin, piece, lines, b2b))


# The callout for a clear: the spin, the kind of clear, and the back-to-back count
func _callout_items(spin: int, piece: int, lines: int, b2b_count: int) -> Array:
	var names = ["", "SINGLE", "DOUBLE", "TRIPLE", "QUAD"]
	var items := []
	if spin != 0:
		items.append_array(_spin_callout(spin, piece))
		items.append({"text": names[min(lines, 4)], "size": 1.45, "color": Color(1, 1, 1)})
	elif lines == 4:
		items.append({"text": "QUAD", "size": 1.75, "color": QUAD_COLOR})
	else:
		items.append({"text": names[lines], "size": 1.2, "color": Color(1, 1, 1)})
	if b2b_count >= 1:
		items.append({"text": "B2B ×%d" % b2b_count, "size": 0.62, "color": B2B_COLOR})
	return items


func _sent_target() -> Vector2:
	var target = g.get("attack_target")
	if target != null:
		return target
	return g.grid_start + Vector2(11.7 * g.tile_size, 22.65 * g.tile_size)


func _noise(t: float, phase: float) -> float:
	return sin(t + phase) * 0.55 + sin(t * 1.73 + phase * 2.1) * 0.3 + sin(t * 2.91 + phase * 0.7) * 0.15


func _process(delta):
	clock += delta
	var u = _unit()

	# R and a top out restart the game in place and set its clock back to 0. This node stays, so
	# the run's own state (B2B and the panel glow that follows it, combo, SENT) has to go back too.
	if MainGame.time_elapsed < last_time:
		_new_run()
	last_time = MainGame.time_elapsed

	# DAS slides and gravity happen in the game's own _process, which runs before this one
	var piece = g.game.current_piece
	if piece == snap_piece and piece.rotation == snap_rot:
		var now = g.game.current_piece_coordinates.duplicate()
		if now != snap_coords and not now.is_empty() and not snap_coords.is_empty():
			if now[0].y == snap_coords[0].y:
				_nudge(now)
			last_rot = false
	_snapshot()

	# Springs, shake and decays
	var k := 420.0
	var c := 17.0
	spring_vel += (-k * spring_pos - c * spring_vel) * delta
	spring_pos += spring_vel * delta
	spring_ang_vel += (-k * spring_ang - c * spring_ang_vel) * delta
	spring_ang += spring_ang_vel * delta
	trauma = max(0.0, trauma - 1.5 * delta)
	punch *= exp(-7.0 * delta)
	ca *= exp(-5.0 * delta)
	sent_pop *= exp(-9.0 * delta)
	damage_pop *= exp(-9.0 * delta)
	opp_callout_age += delta
	lightning_age += delta
	callout_age += delta
	var danger_cells = g.get("danger")
	var danger_target = 0.0
	if danger_cells != null and not danger_cells.is_empty():
		danger_target = 1.0
	elif g.get("danger_high"):
		danger_target = 0.45
	danger_level = lerp(danger_level, danger_target, 1.0 - exp(-8.0 * delta))
	danger_phase += delta * (8.0 if danger_target == 1.0 else 3.5)
	pc_age += delta

	var offset = spring_pos
	var angle = spring_ang
	if on.has("shake") and trauma > 0.0:
		var t2 = trauma * trauma
		offset += Vector2(_noise(clock * 31.0, 0.0), _noise(clock * 29.0, 7.3)) * 13.0 * u * t2
		angle += _noise(clock * 23.0, 3.1) * 0.01 * t2
	if on.has("motion") or on.has("shake"):
		var pivot = g.grid_start + Vector2(5.0 * g.tile_size, 14.0 * g.tile_size)
		g.rotation = angle
		g.position = pivot + offset - pivot.rotated(angle)

	for p in particles:
		var v: Vector2 = p["vel"]
		v.y += 1150.0 * u * delta
		v *= exp(-1.4 * delta)
		p["vel"] = v
		p["pos"] = p["pos"] + v * delta
		p["age"] += delta
	particles = particles.filter(func(p): return p["age"] < p["life"])
	for sp in sparkles:
		sp["age"] += delta
		if sp["age"] < 0.0:  # not started yet
			continue
		var v: Vector2 = sp["vel"]
		v *= exp(-3.0 * delta)
		sp["vel"] = v
		sp["pos"] = sp["pos"] + v * delta
	sparkles = sparkles.filter(func(sp): return sp["age"] < sp["life"])
	for sk in spin_sparks:
		var v: Vector2 = sk["vel"]
		v *= exp(-4.5 * delta)
		sk["vel"] = v
		sk["pos"] = sk["pos"] + v * delta
		sk["age"] += delta
	spin_sparks = spin_sparks.filter(func(sk): return sk["age"] < sk["life"])
	if not spin_glow.is_empty():
		spin_glow["age"] += delta
	for m in motes:
		m["age"] += delta
		if m["age"] > 0.0:
			var v: Vector2 = m["vel"]
			v *= exp(-1.2 * delta)
			m["vel"] = v
			m["pos"] = m["pos"] + v * delta
	motes = motes.filter(func(m): return m["age"] < m["life"])
	for f in flashes:
		f["age"] += delta
	flashes = flashes.filter(func(f): return f["age"] < 0.24)
	for t in trails:
		t["age"] += delta
	trails = trails.filter(func(t): return t["age"] < 0.16)
	for l in locks:
		l["age"] += delta
	locks = locks.filter(func(l): return l["age"] < l["life"])
	for w in waves:
		w["age"] += delta
	waves = waves.filter(func(w): return w["age"] < 1.0)
	for o in orbs:
		o["age"] += delta
		o["trail"].push_front(_orb_pos(o))
		if o["trail"].size() > 12:
			o["trail"].pop_back()
		if o["age"] >= o["life"] and not o.has("done"):
			o["done"] = true
			sent += o["attack"]
			sent_pop = 1.0
			if on.has("wave"):
				waves.append({"c": _screen_uv(_sent_target()), "age": 0.0, "s": 0.004, "z": 0.5})
			if on.has("ca_pulse"):
				ca += 0.0025
	orbs = orbs.filter(func(o): return o["age"] < o["life"] + 0.2)

	_update_post()
	add_layer.queue_redraw()
	text_layer.queue_redraw()


func _orb_pos(o: Dictionary) -> Vector2:
	var t = clamp(o["age"] / o["life"], 0.0, 1.0)
	t = t * t * (3.0 - 2.0 * t)
	var a: Vector2 = o["from"]
	var b = _sent_target()
	var control = (a + b) * 0.5 + Vector2(0, -4.0 * g.tile_size)
	return a.lerp(control, t).lerp(control.lerp(b, t), t)


func _update_post():
	post.set_shader_parameter("ca_base", 0.0055 if on.has("ca") else 0.0)
	post.set_shader_parameter("ca_amount", ca)
	post.set_shader_parameter("ca_center", ca_center)
	var sizes = [1.0, 1.0, 1.0, 1.0]
	for i in range(4):
		var v = Vector4(0, 0, 0, 0)
		if i < waves.size():
			var w = waves[waves.size() - 1 - i]
			v = Vector4(w["c"].x, w["c"].y, w["age"], w["s"])
			sizes[i] = w.get("z", 1.0)
		post.set_shader_parameter("wave%d" % i, v)
	post.set_shader_parameter("wave_size", Vector4(sizes[0], sizes[1], sizes[2], sizes[3]))
	post.set_shader_parameter("bloom", ((0.55 if on.has("lens") else 0.42) + 0.35 * _pc_flare()) if on.has("bloom") else 0.0)
	post.set_shader_parameter("lens", 1.0 if on.has("lens") else 0.0)
	post.set_shader_parameter("danger", danger_level * (0.6 + 0.4 * _danger_pulse()))
	post.set_shader_parameter("flash", _lightning())
	post.set_shader_parameter("time", clock)
	var zoom = 1.0 + punch
	var tilt = Vector2.ZERO
	if on.has("camera"):
		zoom += 0.018 + 0.0025 * min(max(b2b, 0), 8)
		tilt = Vector2(sin(clock * 0.23) * 0.02, sin(clock * 0.17 + 1.2) * 0.014)
	post.set_shader_parameter("zoom", zoom)
	post.set_shader_parameter("tilt", tilt)


# Lightning: a bright stroke, then a second weaker one 90 ms later
func _lightning() -> float:
	var a = lightning_age
	if a < 0.0 or a > 0.5:
		return 0.0
	var f = exp(-a / 0.035)
	if a > 0.09:
		f += 0.7 * exp(-(a - 0.09) / 0.05)
	return lightning_strength * min(f, 1.0)


func _danger_pulse() -> float:
	return 0.5 + 0.5 * sin(danger_phase)


# Danger: red light comes down from the top of the board (further, the worse it is), and when the
# next placement would kill, up its sides as well
func _draw_danger_glow():
	var ts = g.tile_size
	var gs = g.grid_start
	var a = danger_level * (0.6 + 0.4 * _danger_pulse())
	var red = Color(DANGER_COLOR, 0.35 * a)
	var clear = Color(DANGER_COLOR, 0.0)
	var top = gs.y + 4 * ts
	var bottom = gs.y + 24 * ts
	var depth = (3.0 + 5.0 * danger_level) * ts
	add_layer.draw_polygon(
		PackedVector2Array([Vector2(gs.x, top), Vector2(gs.x + 10 * ts, top), Vector2(gs.x + 10 * ts, top + depth), Vector2(gs.x, top + depth)]),
		PackedColorArray([red, red, clear, clear]))
	var side = clamp((danger_level - 0.5) * 2.0, 0.0, 1.0) * a
	if side > 0.0:
		var edge = Color(DANGER_COLOR, 0.3 * side)
		for x in [gs.x, gs.x + 10 * ts]:
			var inner = x + (1.2 * ts if x == gs.x else -1.2 * ts)
			add_layer.draw_polygon(
				PackedVector2Array([Vector2(x, top), Vector2(inner, top), Vector2(inner, bottom), Vector2(x, bottom)]),
				PackedColorArray([edge, clear, clear, edge]))


func _b2b_color() -> Color:
	return _b2b_color_for(b2b)


func _b2b_color_for(count: int) -> Color:
	var level = clamp(float(max(count, 0)) / 8.0, 0.0, 1.0)
	return Color(0.62, 0.9, 0.78).lerp(B2B_COLOR, min(1.0, level * 2.0)).lerp(T_COLOR, max(0.0, level * 2.0 - 1.0))


# Board background; replaces the game's flat dark rectangle
func draw_panel(canvas: CanvasItem):
	var ts = g.tile_size
	var gs = g.grid_start
	var rect = Rect2(gs.x, gs.y + 4 * ts, 10 * ts, 20 * ts)
	if not on.has("panel"):
		canvas.draw_rect(rect, Color(0, 0, 0, 0.5))
		return
	var flare = _pc_flare()
	var glow = _b2b_color().lerp(Color(1, 1, 1), 0.75 * flare)
	var strength = 0.55 + 0.45 * clamp(float(max(b2b, 0)) / 6.0, 0.0, 1.0) + 1.2 * flare
	# Danger, as in TETR.IO: the border pulses red while the stack is near the top, and harder when
	# the next placement would kill (the game's X's)
	if danger_level > 0.01:
		var pulse = _danger_pulse()
		glow = glow.lerp(DANGER_COLOR, min(1.0, danger_level * 1.4) * (0.65 + 0.35 * pulse))
		strength = max(strength, danger_level * 1.4 * (1.0 + 0.5 * pulse))
	canvas.draw_rect(rect.grow(0.22 * ts), Color(0, 0, 0, 0.28))
	for i in range(6):
		canvas.draw_rect(rect.grow((i + 1) * 0.07 * ts), Color(glow.r, glow.g, glow.b, 0.045 * (6 - i) / 6.0 * strength), false, 0.07 * ts)
	canvas.draw_rect(rect, Color(0.015, 0.025, 0.02, 0.66))
	canvas.draw_rect(rect, Color(glow.r, glow.g, glow.b, min(1.0, 0.6 * strength)), false, 2.0)


# Versus: the bot's board panel at origin, glowing with its back-to-back as the player's does with
# the player's; red once it has topped out
func draw_opponent_panel(canvas: CanvasItem, origin: Vector2, topped_out: bool):
	var ts = g.tile_size
	var rect = Rect2(origin.x, origin.y + 4 * ts, 10 * ts, 20 * ts)
	var glow = DANGER_COLOR if topped_out else _b2b_color_for(opp_b2b)
	var strength = 1.2 if topped_out else 0.55 + 0.45 * clamp(float(max(opp_b2b, 0)) / 6.0, 0.0, 1.0)
	canvas.draw_rect(rect.grow(0.22 * ts), Color(0, 0, 0, 0.28))
	for i in range(6):
		canvas.draw_rect(rect.grow((i + 1) * 0.07 * ts), Color(glow.r, glow.g, glow.b, 0.045 * (6 - i) / 6.0 * strength), false, 0.07 * ts)
	canvas.draw_rect(rect, Color(0.015, 0.025, 0.02, 0.66))
	canvas.draw_rect(rect, Color(glow.r, glow.g, glow.b, min(1.0, 0.6 * strength)), false, 2.0)


func draw_ghost(canvas: CanvasItem, x: float, y: float):
	var ts = g.tile_size
	var c: Color = MainGame.COLORS[g.game.current_piece.tile_type]
	var r = Rect2(x + 3, y + 3, ts - 6, ts - 6)
	canvas.draw_rect(r, Color(c.r, c.g, c.b, 0.1))
	canvas.draw_rect(r, Color(c.r, c.g, c.b, 0.7), false, 2.0)


func _draw_add():
	var ts = g.tile_size
	var gs = g.grid_start
	for t in trails:
		var a = 1.0 - t["age"] / 0.16
		var x0 = gs.x + t["x"] * ts + 0.22 * ts
		var x1 = x0 + 0.56 * ts
		var y0 = gs.y + max(t["top"], 2) * ts
		var y1 = gs.y + t["bottom"] * ts
		var c: Color = t["color"].lerp(Color(1, 1, 1), 0.45)
		add_layer.draw_polygon(
			PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]),
			PackedColorArray([Color(c.r, c.g, c.b, 0), Color(c.r, c.g, c.b, 0), Color(c.r, c.g, c.b, 0.32 * a), Color(c.r, c.g, c.b, 0.32 * a)]))
	if danger_level > 0.01:
		_draw_danger_glow()
	if pc_age < PC_LIFE:
		_draw_pc_sweep()
	for f in flashes:
		var k = f["age"] / 0.24
		var a = (1.0 - k) * (1.0 - k)
		var fo: Vector2 = f.get("origin", gs)  # the player's board, or the bot's
		var y = fo.y + f["y"] * ts
		var grow = 0.5 * ts * k
		var fc: Color = f.get("color", Color(1, 1, 1))  # white for a clear, red for rising garbage
		add_layer.draw_rect(Rect2(fo.x - 0.1 * ts * k, y - grow * 0.5, 10 * ts + 0.2 * ts * k, ts + grow), Color(fc, 0.55 * a))
		var w = 10 * ts * min(1.0, k * 3.5)
		add_layer.draw_rect(Rect2(fo.x + 5 * ts - w * 0.5, y + 0.42 * ts, w, 0.16 * ts), Color(fc, a))
	for l in locks:
		var k = l["age"] / l["life"]
		var c: Color = l["color"]
		for p in l["cells"]:
			var r = Rect2(gs.x + p.x * ts, gs.y + p.y * ts, ts, ts).grow(l["grow"] * ts * k)
			add_layer.draw_rect(r, Color(c.r, c.g, c.b, 0.7 * (1.0 - k)))
	# The spun piece flashes while it is still the falling piece, and a ring in its shape runs out
	if not spin_glow.is_empty():
		var c: Color = spin_glow["color"].lerp(Color(1, 1, 1), 0.5)
		if spin_glow["age"] < 0.25 and spin_glow["piece"] == g.game.current_piece:
			var k = spin_glow["age"] / 0.25
			for p in g.game.current_piece_coordinates:
				add_layer.draw_rect(Rect2(gs.x + p.x * ts, gs.y + p.y * ts, ts, ts), Color(c, 0.7 * (1.0 - k) * (1.0 - k)))
		if spin_glow["age"] < SPIN_RING_LIFE:
			_draw_spin_ring(spin_glow["cells"], spin_glow["age"] / SPIN_RING_LIFE, c)
	for sk in spin_sparks:
		var a = 1.0 - sk["age"] / sk["life"]
		var c: Color = sk["color"]
		add_layer.draw_line(sk["pos"] - sk["vel"] * 0.05, sk["pos"], Color(c, 0.7 * a), sk["size"])
		add_layer.draw_circle(sk["pos"], sk["size"] * 0.75, Color(c.lerp(Color(1, 1, 1), 0.4), a))
	for p in particles:
		var a = 1.0 - p["age"] / p["life"]
		var s = p["size"] * (0.35 + 0.65 * a)
		var c: Color = p["color"]
		add_layer.draw_line(p["pos"] - p["vel"] * 0.03, p["pos"], Color(c.r, c.g, c.b, 0.45 * a), s * 0.55)
		add_layer.draw_rect(Rect2(p["pos"] - Vector2(s, s) * 0.5, Vector2(s, s)), Color(c.r, c.g, c.b, a))
	for sp in sparkles:
		if sp["age"] < 0.0:
			continue
		var k = sp["age"] / sp["life"]
		var twinkle = 0.65 + 0.35 * sin(sp["phase"] + sp["age"] * 38.0)
		var a = (1.0 - k) * twinkle
		var r = sp["size"] * (1.0 - 0.5 * k)
		var rot = sp["spin"] * sp["age"]
		var arm = Vector2(r, 0).rotated(rot)
		var arm2 = Vector2(0, r).rotated(rot)
		var c: Color = sp.get("color", Color(1, 1, 1))  # lock sparkles are white, spin stars coloured
		add_layer.draw_circle(sp["pos"], r * 0.75, Color(c, 0.12 * a))
		add_layer.draw_line(sp["pos"] - arm, sp["pos"] + arm, Color(c, a), max(1.0, r * 0.22))
		add_layer.draw_line(sp["pos"] - arm2, sp["pos"] + arm2, Color(c, a), max(1.0, r * 0.22))
		add_layer.draw_circle(sp["pos"], r * 0.28, Color(1, 1, 1, min(1.0, a * 1.3)))
	for o in orbs:
		if o["age"] > o["life"]:
			continue
		var c: Color = o["color"]
		var trail: Array = o["trail"]
		for i in range(trail.size()):
			var fade = 1.0 - float(i) / trail.size()
			add_layer.draw_circle(trail[i], 0.22 * ts * fade, Color(c.r, c.g, c.b, 0.25 * fade))
		var p = _orb_pos(o)
		add_layer.draw_circle(p, 0.55 * ts, Color(c.r, c.g, c.b, 0.12))
		add_layer.draw_circle(p, 0.3 * ts, Color(c.r, c.g, c.b, 0.35))
		add_layer.draw_circle(p, 0.14 * ts, Color(1, 1, 1, 0.95))
	for m in motes:
		if m["age"] < 0.0:
			continue
		var k = m["age"] / m["life"]
		var a = min(1.0, m["age"] / 0.08) * (1.0 - k) * (0.7 + 0.3 * sin(m["phase"] + m["age"] * 30.0))
		var c: Color = m["color"]
		add_layer.draw_circle(m["pos"], m["size"] * 2.6, Color(c, 0.16 * a))
		add_layer.draw_circle(m["pos"], m["size"], Color(c.lerp(Color(1, 1, 1), 0.5), a))
	# Soft glow behind the callout text
	if not callout.is_empty() and callout_age < 1.6:
		_draw_callout(add_layer, true)
	if not opp_callout.is_empty() and opp_callout_age < 1.6:
		_draw_callout_at(add_layer, true, opp_callout, opp_callout_age, opp_origin)
	if pc_age < PC_LIFE:
		_draw_pc_title(add_layer, true)
	_draw_damage(add_layer, true)


func _draw_text():
	if not callout.is_empty() and callout_age < 1.6:
		_draw_callout(text_layer, false)
	if not opp_callout.is_empty() and opp_callout_age < 1.6:
		_draw_callout_at(text_layer, false, opp_callout, opp_callout_age, opp_origin)
	if pc_age < PC_LIFE:
		_draw_pc_title(text_layer, false)
	_draw_damage(text_layer, false)
	if on.has("attack"):
		var ts = g.tile_size
		var gs = g.grid_start
		var font = g.hud_font
		text_layer.draw_string(font, Vector2(gs.x + 11 * ts, gs.y + 21 * ts), "SENT", HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts))
		var scale = 1.0 + 0.3 * sent_pop
		var pivot = Vector2(gs.x + 11 * ts, gs.y + 22.6 * ts)
		text_layer.draw_set_transform(pivot, 0.0, Vector2(scale, scale))
		var color = Color(1, 1, 1).lerp(B2B_COLOR, sent_pop)
		text_layer.draw_string(font, Vector2(0, 0.4 * ts), str(sent), HORIZONTAL_ALIGNMENT_LEFT, -1, int(ts), color)
		text_layer.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_callout(canvas: CanvasItem, glow: bool):
	_draw_callout_at(canvas, glow, callout, callout_age, g.grid_start)


func _draw_callout_at(canvas: CanvasItem, glow: bool, callout: Array, callout_age: float, gs: Vector2):
	var ts = g.tile_size
	var font = g.hud_font
	var a = callout_age
	var alpha = clamp(a / 0.05, 0.0, 1.0) * (1.0 - clamp((a - 1.15) / 0.4, 0.0, 1.0))
	var scale = 1.0 + 0.32 * exp(-a * 16.0)
	var centre_x = gs.x + 5.0 * ts
	var y = gs.y + 6.2 * ts
	var total := 0.0
	for item in callout:
		total += item["size"] * ts * 1.08
	var pivot = Vector2(centre_x, y + total * 0.5)
	canvas.draw_set_transform(pivot + Vector2(0.0, -0.3 * ts * clamp(a - 1.15, 0.0, 1.0)), 0.0, Vector2(scale, scale))
	for item in callout:
		var size = int(item["size"] * ts)
		y += item["size"] * ts * 1.08
		var width = font.get_string_size(item["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var pos = Vector2(centre_x - width * 0.5, y) - pivot
		var c: Color = item["color"]
		if glow:
			for d in [Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4), Vector2(3, 3), Vector2(-3, -3)]:
				canvas.draw_string(font, pos + d, item["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(c.r, c.g, c.b, 0.09 * alpha))
		else:
			canvas.draw_string(font, pos, item["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(c.r, c.g, c.b, alpha))
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


# The perfect clear's light front: each empty cell lights up as the front passes it, in the colour
# for its distance from the clear, and fades behind it
func _draw_pc_sweep():
	var ts = g.tile_size
	var gs = g.grid_start
	var edge = max(1.0, 0.05 * ts)
	for x in range(10):
		for y in range(4, 24):
			if g.game.board[x][y].state != Tile.State.EMPTY:
				continue
			var d = Vector2(x + 0.5, y + 0.5).distance_to(pc_origin)
			var t = pc_age - d * PC_STEP
			if t < 0.0 or t > 0.35:
				continue
			# A short, bright pulse, so the front reads as a clean band and not a haze behind it
			var i = min(1.0, t / 0.03) * exp(-t * 13.0)
			var c = _pc_color(d).lerp(Color(1, 1, 1), 0.3 * i)
			var r = Rect2(gs.x + x * ts, gs.y + y * ts, ts, ts).grow(-0.07 * ts)
			add_layer.draw_rect(r, Color(c, 0.3 * i))
			add_layer.draw_rect(r, Color(c, i), false, edge)


# PERFECT drops in a letter at a time, each in its piece colour; CLEAR lands under it, and a streak
# of light runs out from under it. Both rise and fade at the end. glow: the soft halo, drawn on the add layer.
func _draw_pc_title(canvas: CanvasItem, glow: bool):
	var ts = g.tile_size
	var gs = g.grid_start
	var font = g.hud_font
	var a = pc_age - 0.06  # after the row flash
	if a < 0.0:
		return
	var out = clamp((a - 1.55) / 0.45, 0.0, 1.0)
	var lift = -0.4 * ts * out
	var cx = gs.x + 5.0 * ts

	var size1 = int(0.9 * ts)
	var gap = 0.3 * ts
	var slot = font.get_string_size("M", HORIZONTAL_ALIGNMENT_LEFT, -1, size1).x + gap
	var x0 = cx - (slot * 7 - gap) * 0.5
	for i in range(7):
		var t = clamp((a - 0.04 * i) / 0.3, 0.0, 1.0)
		if t <= 0.0:
			break
		var s = t - 1.0
		var land = 1.0 + 2.70158 * s * s * s + 1.70158 * s * s  # ease out with a small overshoot
		var c: Color = MainGame.COLORS[PC_HUES[i]].lerp(Color(1, 1, 1), 0.15)
		var pos = Vector2(x0 + slot * i, gs.y + 13.2 * ts + lift - (1.0 - land) * 0.9 * ts)
		_glow_string(canvas, glow, pos, "PERFECT"[i], size1, c, min(1.0, t * 4.0) * (1.0 - out))

	var b = a - 0.3
	if b < 0.0:
		return
	var size2 = int(1.8 * ts)
	var centre = Vector2(cx, gs.y + 14.5 * ts + lift)
	if glow:
		var k = clamp(b / 0.4, 0.0, 1.0)
		var reach = 9.0 * ts * (1.0 - pow(1.0 - k, 4.0))
		var fade = (1.0 - k) * (1.0 - k)
		# Under the word: through it, it would read as a strikethrough
		var under = centre + Vector2(0, 0.36 * size2 + 0.32 * ts)
		_streak(canvas, under, reach, 0.07 * ts, Color(1, 1, 1, fade))
		_streak(canvas, under, reach * 0.8, 0.45 * ts, Color(0.85, 0.9, 1.0, 0.16 * fade))
	var scale = 1.0 + 0.35 * exp(-b * 14.0)
	var width = font.get_string_size("CLEAR", HORIZONTAL_ALIGNMENT_LEFT, -1, size2).x
	canvas.draw_set_transform(centre, 0.0, Vector2(scale, scale))
	_glow_string(canvas, glow, Vector2(-width * 0.5, 0.36 * size2), "CLEAR", size2, Color(1, 1, 1),
		min(1.0, b / 0.06) * (1.0 - out))
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _glow_string(canvas: CanvasItem, glow: bool, pos: Vector2, text: String, size: int, c: Color, alpha: float):
	var font = g.hud_font
	if glow:
		var u = _unit()
		for d in [Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4), Vector2(3, 3), Vector2(-3, -3)]:
			canvas.draw_string(font, pos + d * u, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(c, 0.1 * alpha))
	else:
		canvas.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(c, alpha))


# A horizontal bar of light, brightest in the middle and fading out to both ends
func _streak(canvas: CanvasItem, centre: Vector2, reach: float, height: float, c: Color):
	var clear = Color(c, 0.0)
	for side in [-1.0, 1.0]:
		var tip = centre.x + side * reach
		canvas.draw_polygon(
			PackedVector2Array([Vector2(centre.x, centre.y - height * 0.5), Vector2(tip, centre.y - height * 0.5),
				Vector2(tip, centre.y + height * 0.5), Vector2(centre.x, centre.y + height * 0.5)]),
			PackedColorArray([c, clear, clear, c]))


# The outline of a piece pushed out from it by a growing distance: each open side of each cell is
# moved out, lengthened at an outer corner and shortened at an inner one, so the sides meet
func _draw_spin_ring(cells: Array, k: float, c: Color):
	var ts = g.tile_size
	var gs = g.grid_start
	var grow = (0.08 + 0.6 * (1.0 - (1.0 - k) * (1.0 - k))) * ts
	var a = pow(1.0 - k, 1.5)
	var width = max(1.5, 0.09 * ts * (1.0 - 0.5 * k))
	var inside := {}
	for p in cells:
		inside[p] = true
	# Outward side, then the side's ends (from the cell's top left) and the way along it, clockwise
	var sides = [
		[Vector2(0, -1), Vector2(0, 0), Vector2(1, 0), Vector2(1, 0)],
		[Vector2(1, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)],
		[Vector2(0, 1), Vector2(1, 1), Vector2(0, 1), Vector2(-1, 0)],
		[Vector2(-1, 0), Vector2(0, 1), Vector2(0, 0), Vector2(0, -1)],
	]
	for p in cells:
		for side in sides:
			var n: Vector2 = side[0]
			if inside.has(p + n):
				continue
			var along: Vector2 = side[3]
			var ends = []
			for e in [[side[1], -along], [side[2], along]]:
				var q = p + e[1]
				var shift = 1.0  # outer corner: lengthen
				if inside.has(q):
					shift = -1.0 if inside.has(q + n) else 0.0  # inner corner: shorten; straight on: neither
				ends.append(gs + (p + e[0]) * ts + (n + e[1] * shift) * grow)
			add_layer.draw_line(ends[0], ends[1], Color(c, 0.25 * a), width * 3.0)
			add_layer.draw_line(ends[0], ends[1], Color(c, 0.9 * a), width)


# The damage number, in the lower middle of the board: bold and tilted, with a dark outline. It pops
# each time it grows and gets bigger with the total; white, gold from 4 lines, and from 10 (a spike)
# red and blinking. glow: the halo, drawn on the add layer.
func _draw_damage(canvas: CanvasItem, glow: bool):
	var age = clock - damage_time
	if damage <= 0 or age > DAMAGE_HOLD + DAMAGE_FADE:
		return
	var ts = g.tile_size
	var alpha = 1.0 - clamp((age - DAMAGE_HOLD) / DAMAGE_FADE, 0.0, 1.0)
	var color = Color(1, 1, 1)
	if damage >= 10:
		color = Color(1.0, 0.32, 0.28)
		alpha *= 0.7 if sin(clock * 30.0) < 0.0 else 1.0
	elif damage >= 4:
		color = B2B_COLOR
	var size = int((1.3 + 0.075 * min(damage, 20)) * ts)
	var scale = 1.0 + 0.45 * damage_pop
	var text = str(damage)
	var font = g.hud_font
	var width = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var pos = Vector2(-width * 0.5, 0.36 * size)
	canvas.draw_set_transform(g.grid_start + Vector2(5.0 * ts, 18.0 * ts), -0.1, Vector2(scale, scale))
	if glow:
		var u = _unit()
		for d in [Vector2(5, 0), Vector2(-5, 0), Vector2(0, 5), Vector2(0, -5), Vector2(4, 4), Vector2(-4, -4)]:
			canvas.draw_string(font, pos + d * u, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color, 0.12 * alpha))
	else:
		canvas.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, int(0.16 * ts), Color(0.05, 0.02, 0.03, 0.85 * alpha))
		canvas.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(color, alpha))
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
