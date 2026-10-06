extends Node2D
# Visual effects for GDTris: board motion, clear effects, spin callouts and post processing.
# This node is a child of the MainGame node (graphics.gd), so everything it draws moves with
# the board. It only reads the game state; it never changes the game.
#
# Presets:
#   "curated": row flash, particles, shockwave, chromatic aberration, spin/quad callouts with B2B,
#              hard drop trails, bloom, spin flash, lock sparkles, glass board panel,
#              lens grade (vignette, grain, colour)
#   "all":     curated + camera punch, attack orbs and a SENT counter, outlined ghost,
#              blurred background, slow camera drift, denser particles
# The clear shockwave (a TETR.IO-style ripple packet) scales with the attack (lines sent, TETR.IO
# rules) of the combo so far: every clear in a run of pieces that each clear a line adds to it, and
# a piece that clears nothing starts it again. Below WAVE_MIN (10) there is no ripple; from there
#   WAVE_PEAK * lerp(WAVE_FLOOR, 1, ((combo - WAVE_MIN) / (WAVE_TOP - WAVE_MIN)) ^ rate)
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
		"spinflash", "sparkles", "panel", "lens"],
	"all": ["flash", "particles", "wave", "ca", "callouts", "trail", "bloom",
		"spinflash", "sparkles", "panel", "lens",
		"punch", "attack", "ghost", "bgblur", "camera", "dense"],
	"game": ["flash", "particles", "wave", "ca", "callouts", "trail", "bloom",
		"spinflash", "sparkles", "panel", "lens",
		"punch", "attack", "ghost", "bgblur", "dense",
		"motion", "shake", "ca_pulse"],
}

const T_COLOR = Color(0.86, 0.36, 1.0)
const QUAD_COLOR = Color(0.3, 0.95, 1.0)
const B2B_COLOR = Color(1.0, 0.8, 0.32)

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
var orbs := []
var callout := []
var callout_age := 99.0
var b2b := -1
var combo_sent := 0  # attack sent by the current combo
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
const WAVE_MIN := 10.0  # combo attack that starts the ripple
const WAVE_FLOOR := 0.25  # strength at WAVE_MIN, as a part of WAVE_PEAK
const WAVE_TOP := 100.0  # combo attack that reaches full strength
const WAVE_UNIT := 6.0  # attack of one clear that ripples at 1x


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
		if on.has("motion"):
			var dir := 1.0
			if keycode == GameConfig.get_setting("controls", "rotate_ccw"):
				dir = -1.0
			elif keycode == GameConfig.get_setting("controls", "rotate_180"):
				dir = 1.5 if randf() < 0.5 else -1.5
			spring_ang_vel += 0.24 * dir
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
		var centre = game.current_piece_top_left_corner + Vector2(1, 1)
		var corners := 0
		for d in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var p = centre + d
			if p.x < 0 or p.x >= 10 or p.y >= 24 or (p.y >= 0 and game.board[p.x][p.y].state == Tile.State.PLACED):
				corners += 1
		tspin = corners >= 3
	return {
		"color": MainGame.COLORS[piece.tile_type], "cells": cells, "landing": landing,
		"types": types, "drop": drop, "tspin": tspin,
	}


func after_hard_drop(pre: Dictionary, info: Dictionary):
	var u = _unit()
	var ts = g.tile_size
	var gs = g.grid_start
	var rows = info["lines_cleared"]
	var lines = rows.size()
	var color: Color = pre["color"]

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

	if lines == 0:
		if pre["tspin"] and on.has("callouts"):
			_set_callout([{"text": "T-SPIN", "size": 0.75, "color": T_COLOR}])
		return

	var difficult: bool = pre["tspin"] or lines == 4
	b2b = b2b + 1 if difficult else -1

	var cx := 0.0
	for p in pre["landing"]:
		cx += p.x
	cx /= max(1, pre["landing"].size())
	var cy := 0.0
	for r in rows:
		cy += r
	cy /= lines
	var centre = gs + Vector2((cx + 0.5) * ts, (cy + 0.5) * ts)
	var big = 1.0 + (0.35 if lines == 4 else 0.0) + (0.15 if pre["tspin"] else 0.0) + 0.04 * min(max(b2b, 0), 10)
	var attack = _attack(pre["tspin"], lines)
	# The game's own combo count also sees the pieces that lock on the lock delay, which never come
	# through this hook, so a combo it has ended is never carried on here
	if g.game.combo <= 1:
		combo_sent = 0
	combo_sent += attack
	# Ripple amplitude in screen heights, and the packet width, from the combo's attack, scaled by
	# this clear's own attack. Nothing below WAVE_MIN; WAVE_PEAK is reached at WAVE_TOP.
	var ramp = clamp((float(combo_sent) - WAVE_MIN) / (WAVE_TOP - WAVE_MIN), 0.0, 1.0)
	var wave_scale = 0.0
	if combo_sent >= WAVE_MIN:
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
	if on.has("callouts"):
		_callout_for(pre["tspin"], lines)
	if on.has("spinflash") and pre["tspin"]:
		locks.append({"cells": pre["landing"], "age": 0.0, "life": 0.32, "color": T_COLOR, "grow": 0.35})
	if on.has("attack") and difficult:
		orbs.append({
			"from": centre, "age": 0.0, "life": 0.46, "attack": attack,
			"color": T_COLOR if pre["tspin"] else QUAD_COLOR, "trail": [],
		})


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
	combo_sent = 0
	sent = 0
	sent_pop = 0.0
	orbs.clear()
	callout = []


func _set_callout(items: Array):
	callout = items
	callout_age = 0.0


func _callout_for(tspin: bool, lines: int):
	var names = ["", "SINGLE", "DOUBLE", "TRIPLE", "QUAD"]
	var items := []
	if tspin:
		items.append({"text": "T-SPIN", "size": 0.72, "color": T_COLOR})
		items.append({"text": names[lines], "size": 1.45, "color": Color(1, 1, 1)})
	elif lines == 4:
		items.append({"text": "QUAD", "size": 1.75, "color": QUAD_COLOR})
	else:
		items.append({"text": names[lines], "size": 1.2, "color": Color(1, 1, 1)})
	if b2b >= 1:
		items.append({"text": "B2B ×%d" % b2b, "size": 0.62, "color": B2B_COLOR})
	_set_callout(items)


func _sent_target() -> Vector2:
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
	callout_age += delta

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
		var v: Vector2 = sp["vel"]
		v *= exp(-3.0 * delta)
		sp["vel"] = v
		sp["pos"] = sp["pos"] + v * delta
		sp["age"] += delta
	sparkles = sparkles.filter(func(sp): return sp["age"] < sp["life"])
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
	post.set_shader_parameter("bloom", (0.55 if on.has("lens") else 0.42) if on.has("bloom") else 0.0)
	post.set_shader_parameter("lens", 1.0 if on.has("lens") else 0.0)
	post.set_shader_parameter("time", clock)
	var zoom = 1.0 + punch
	var tilt = Vector2.ZERO
	if on.has("camera"):
		zoom += 0.018 + 0.0025 * min(max(b2b, 0), 8)
		tilt = Vector2(sin(clock * 0.23) * 0.02, sin(clock * 0.17 + 1.2) * 0.014)
	post.set_shader_parameter("zoom", zoom)
	post.set_shader_parameter("tilt", tilt)


func _b2b_color() -> Color:
	var level = clamp(float(max(b2b, 0)) / 8.0, 0.0, 1.0)
	return Color(0.62, 0.9, 0.78).lerp(B2B_COLOR, min(1.0, level * 2.0)).lerp(T_COLOR, max(0.0, level * 2.0 - 1.0))


# Board background; replaces the game's flat dark rectangle
func draw_panel(canvas: CanvasItem):
	var ts = g.tile_size
	var gs = g.grid_start
	var rect = Rect2(gs.x, gs.y + 4 * ts, 10 * ts, 20 * ts)
	if not on.has("panel"):
		canvas.draw_rect(rect, Color(0, 0, 0, 0.5))
		return
	var glow = _b2b_color()
	var strength = 0.55 + 0.45 * clamp(float(max(b2b, 0)) / 6.0, 0.0, 1.0)
	canvas.draw_rect(rect.grow(0.22 * ts), Color(0, 0, 0, 0.28))
	for i in range(6):
		canvas.draw_rect(rect.grow((i + 1) * 0.07 * ts), Color(glow.r, glow.g, glow.b, 0.045 * (6 - i) / 6.0 * strength), false, 0.07 * ts)
	canvas.draw_rect(rect, Color(0.015, 0.025, 0.02, 0.66))
	canvas.draw_rect(rect, Color(glow.r, glow.g, glow.b, 0.6 * strength), false, 2.0)


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
	for f in flashes:
		var k = f["age"] / 0.24
		var a = (1.0 - k) * (1.0 - k)
		var y = gs.y + f["y"] * ts
		var grow = 0.5 * ts * k
		add_layer.draw_rect(Rect2(gs.x - 0.1 * ts * k, y - grow * 0.5, 10 * ts + 0.2 * ts * k, ts + grow), Color(1, 1, 1, 0.55 * a))
		var w = 10 * ts * min(1.0, k * 3.5)
		add_layer.draw_rect(Rect2(gs.x + 5 * ts - w * 0.5, y + 0.42 * ts, w, 0.16 * ts), Color(1, 1, 1, a))
	for l in locks:
		var k = l["age"] / l["life"]
		var c: Color = l["color"]
		for p in l["cells"]:
			var r = Rect2(gs.x + p.x * ts, gs.y + p.y * ts, ts, ts).grow(l["grow"] * ts * k)
			add_layer.draw_rect(r, Color(c.r, c.g, c.b, 0.7 * (1.0 - k)))
	for p in particles:
		var a = 1.0 - p["age"] / p["life"]
		var s = p["size"] * (0.35 + 0.65 * a)
		var c: Color = p["color"]
		add_layer.draw_line(p["pos"] - p["vel"] * 0.03, p["pos"], Color(c.r, c.g, c.b, 0.45 * a), s * 0.55)
		add_layer.draw_rect(Rect2(p["pos"] - Vector2(s, s) * 0.5, Vector2(s, s)), Color(c.r, c.g, c.b, a))
	for sp in sparkles:
		var k = sp["age"] / sp["life"]
		var twinkle = 0.65 + 0.35 * sin(sp["phase"] + sp["age"] * 38.0)
		var a = (1.0 - k) * twinkle
		var r = sp["size"] * (1.0 - 0.5 * k)
		var rot = sp["spin"] * sp["age"]
		var arm = Vector2(r, 0).rotated(rot)
		var arm2 = Vector2(0, r).rotated(rot)
		add_layer.draw_circle(sp["pos"], r * 0.75, Color(1, 1, 1, 0.12 * a))
		add_layer.draw_line(sp["pos"] - arm, sp["pos"] + arm, Color(1, 1, 1, a), max(1.0, r * 0.22))
		add_layer.draw_line(sp["pos"] - arm2, sp["pos"] + arm2, Color(1, 1, 1, a), max(1.0, r * 0.22))
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
	# Soft glow behind the callout text
	if not callout.is_empty() and callout_age < 1.6:
		_draw_callout(add_layer, true)


func _draw_text():
	if not callout.is_empty() and callout_age < 1.6:
		_draw_callout(text_layer, false)
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
	var ts = g.tile_size
	var gs = g.grid_start
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
