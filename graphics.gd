extends Node2D

class_name MainGame

var game: Game
var fx = null
# "play", "survival" (garbage comes in) or "versus" (against the bot); the home screen sets it
static var mode = "play"
const Garbage = preload("res://src/base/garbage.gd")
# Danger (Game.danger): the cells marked with X's, where the next piece would not fit, and whether
# the stack is near the top (the effects turn the border red)
var danger: Array[Vector2] = []
var danger_high = false
# The survival result shown over the new game after a top out: {"time", "best", "new_best", "age"}
var result = {}
# Versus: the bot (BotPlayer) and its board (BotView) on the right, played in rounds: a countdown,
# play until one side tops out, the result, then the next round
const BotPlayer = preload("res://src/versus/bot_player.gd")
const BotView = preload("res://src/versus/bot_view.gd")
enum Round { COUNTDOWN, PLAYING, OVER }
const COUNTDOWN_TIME = 1.5  # 3, 2, 1: half a second each
const OVER_TIME = 3.0
var bot_player = null
var bot_view = null
var bot_grid_start := Vector2.ZERO
var attack_target = null  # where the effects send the player's attack: the bot's garbage meter
var round_state = Round.PLAYING
var round_timer := 0.0
var round_winner := ""  # "you" or "bot"
var score = [0, 0]  # rounds won: you, the bot
# Unlimited lives (VS BOT setup): a top out starts the player's board again and the round goes on,
# until the bot tops out
var unlimited_lives := false
var top_outs := 0  # this round
var respawn_age := 99.0  # since the last of them, for the "TOP OUT" over the board
# "@0.5": the shockwave grows with the burst's attack along a square root, so it gets strong soon
# after 10 lines (half strength at 20) and still reaches full strength at 100
const FX_PRESET = "flash,particles,wave,ca,callouts,trail,bloom,spinflash,sparkles,panel,lens,perfect@0.5"

# Called when the node enters the scene tree for the first time.
func _ready():
	get_tree().get_root().size_changed.connect(on_window_resize)
	GameConfig.create()
	layout()

	# These are static, so they outlive the scene: coming back from settings would otherwise carry
	# on the old clock, and gravity, which speeds up with it
	time_elapsed = 0
	last_gravity_time = -1

	var atlas = tile_map.tile_set.get_source(0) as TileSetAtlasSource
	var atlas_image = atlas.texture.get_image()
	for i in range(0, 10):
		var tile_image = atlas_image.get_region(atlas.get_tile_texture_region(Vector2i(int(i), 0)))
		var tile_texture = ImageTexture.create_from_image(tile_image)
		tile_texture.set_size_override(Vector2i(tile_size, tile_size))
		tile_textures.append(tile_texture)

	var color_ramp_gradient = Gradient.new()
	color_ramp_gradient.set_color(0, Color(1, 1, 1, 0.3))
	color_ramp_gradient.set_color(1, Color(1, 1, 1, 0))
	color_ramp_gradient_texture = GradientTexture1D.new()
	color_ramp_gradient_texture.set_gradient(color_ramp_gradient)

	var size_curve = Curve.new()
	size_curve.add_point(Vector2(0, 0))
	size_curve.add_point(Vector2(1, 1))
	size_curve_texture = CurveTexture.new()
	size_curve_texture.set_curve(size_curve)

	var names = SFX_NAMES.duplicate()
	for i in range(1, COMBO_SOUNDS + 1):
		names.append("combo_%d" % i)
	for sound in names:
		var path = "res://assets/sfx/%s.ogg" % sound
		if not ResourceLoader.exists(path):
			path = "res://assets/sfx/%s.wav" % sound
		sfx[sound] = load(path)

	game = Game.new()
	if mode == "survival":
		game.enable_survival(Game.Survival.saved_options())
	elif mode == "versus":
		game.enable_garbage()
		game.auto_restart = false
		bot_player = BotPlayer.new(GameConfig.get_setting("bot", "level"), GameConfig.get_setting("bot", "pps") / 10.0)
		unlimited_lives = GameConfig.get_setting("bot", "unlimited")
		bot_view = BotView.new()
		bot_view.main = self
		bot_view.player = bot_player
		add_sibling.call_deferred(bot_view)
	# Deferred: the scene is still being built here, and a sound added now would not play
	if bot_player != null:
		start_round.call_deferred()
	else:
		play_sound.call_deferred("start")
	if FX_PRESET != "":
		fx = load("res://mods/fx.gd").new()
		add_child(fx)
		fx.setup(self, FX_PRESET)

var color_ramp_gradient_texture: GradientTexture1D
var size_curve_texture: CurveTexture

static var time_elapsed = 0
# Auto shift: the direction pressed last (-1 left, 1 right, 0 none) and the game time of its next
# shift. The first shift comes DAS after the press, then one every ARR.
var shift_direction = 0
var next_shift_time = -1.0
var last_sdf_time = -1
static var last_gravity_time = -1

# Sound effects, made by tools/make_sfx.py. Their levels are set in the files, so all play at 0 dB.
# The short input sounds are WAV (no decode delay), the rest Ogg Vorbis.
const SFX_NAMES = ["move", "rotate", "spin", "softdrop", "hold", "harddrop", "lock", "clear_1", "clear_2",
	"clear_3", "clear_quad", "clear_spin", "btb", "btb_break", "combo_break", "allclear", "topout", "start",
	"garbage_rise", "block", "warning", "alert", "garbage_in_small", "garbage_in_medium", "garbage_in_large",
	"garbage_out_small", "garbage_out_medium", "garbage_out_large", "garbage_alarm",
	"thunder_1", "thunder_2", "thunder_3"]
# Lines waiting in the garbage queue that set off the alarm
const BIG_INCOMING = 10
# Thunder for a big spike, as TETR.IO plays it. The attack sent while the damage number is still on
# screen adds up (mods/fx.gd: 1 s after it last grew, and its fade); as the total passes each step
# the thunder for that step plays, the bigger the louder.
const THUNDER_STEPS = [10, 18, 26]
const SPIKE_HOLD = 1.35
var spikes = {"you": [0, -99.0], "bot": [0, -99.0]}  # each side's spike: [lines, game clock of the last]
const COMBO_SOUNDS = 16
var sfx = {}
var last_played = {}
var sound_rng = RandomNumberGenerator.new()

# TODO: Implement input remapping
func _input(event):
	# If space is pressed, hard drop the piece
	if event is InputEventKey:
		var just_pressed = event.is_pressed() and not event.is_echo()

		if event.is_action_pressed("settings"):
			get_tree().change_scene_to_file("res://home.tscn")

		# Versus: restart starts the round again (the score stays); between rounds the keys do nothing
		if bot_player != null:
			if event.keycode == GameConfig.get_setting("controls", "restart") and just_pressed:
				start_round()
				return
			if round_state != Round.PLAYING or game.game_ended:
				return

		if event.keycode == GameConfig.get_setting("controls", "hard_drop")&&just_pressed:
			lock_piece(true)

		elif event.keycode == GameConfig.get_setting("controls", "left")&&just_pressed:
			if game.move_piece(Game.MoveDirections.LEFT):
				play_sound("move", 0.04, 0.02)
			start_shift(-1)

		elif event.keycode == GameConfig.get_setting("controls", "right")&&just_pressed:
			if game.move_piece(Game.MoveDirections.RIGHT):
				play_sound("move", 0.04, 0.02)
			start_shift(1)

		elif event.keycode == GameConfig.get_setting("controls", "soft_drop")&&just_pressed:
			var moved = false
			if (GameConfig.get_setting("handling", "sdf") == 0):
				for i in range(0, 20):
					moved = game.move_piece(Game.MoveDirections.DOWN) or moved
			moved = game.move_piece(Game.MoveDirections.DOWN) or moved
			if moved:
				play_sound("softdrop", 0.03, 0.04)

		elif event.keycode == GameConfig.get_setting("controls", "rotate_cw")&&just_pressed:
			play_rotate_sound(game.rotate_piece(Piece.RotationAmount.NINETY_DEGREES))

		elif event.keycode == GameConfig.get_setting("controls", "rotate_ccw")&&just_pressed:
			play_rotate_sound(game.rotate_piece(Piece.RotationAmount.TWO_HUNDRED_SEVENTY_DEGREES))

		elif event.keycode == GameConfig.get_setting("controls", "rotate_180")&&just_pressed:
			play_rotate_sound(game.rotate_piece(Piece.RotationAmount.ONE_HUNDRED_EIGHTY_DEGREES))

		elif event.keycode == GameConfig.get_setting("controls", "hold")&&just_pressed:
			if game.hold():
				play_sound("hold")
		elif event.keycode == GameConfig.get_setting("controls", "restart")&&just_pressed:
			game.restart()
			time_elapsed = 0
			last_gravity_time = -1
			play_sound("start")

	if fx and event is InputEventKey and event.is_pressed() and not event.is_echo():
		fx.after_input(event.keycode)

# jitter varies the pitch a little, so a sound heard many times in a row does not sound mechanical.
# min_gap (seconds) keeps a sound that can fire every frame, like moves and soft drop, from piling up.
# bus: "Master", or opponent_bus() for the bot's sounds.
func play_sound(sound: String, jitter: float = 0.0, min_gap: float = 0.0, bus: String = "Master"):
	var now = Time.get_ticks_msec() / 1000.0
	if min_gap > 0 and now - last_played.get(sound, -1.0) < min_gap:
		return
	last_played[sound] = now
	var player = AudioStreamPlayer.new()
	player.stream = sfx[sound]
	player.bus = bus
	if jitter > 0:
		player.pitch_scale = 1.0 + sound_rng.randf_range(-jitter, jitter)
	add_sibling(player)
	player.play()
	player.finished.connect(player.queue_free)

func play_sound_later(delay: float, sound: String, bus: String = "Master"):
	get_tree().create_timer(delay).timeout.connect(play_sound.bind(sound, 0.0, 0.0, bus))

# The bot's sounds go through this bus: 7 dB quieter and a little to the right, where its board is,
# as TETR.IO plays the other player's sounds. Made the first time it is needed.
static func opponent_bus() -> String:
	if AudioServer.get_bus_index("Opponent") == -1:
		AudioServer.add_bus()
		var i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, "Opponent")
		AudioServer.set_bus_send(i, "Master")
		AudioServer.set_bus_volume_db(i, -7.0)
		var panner = AudioEffectPanner.new()
		panner.pan = 0.35
		AudioServer.add_bus_effect(i, panner)
	return "Opponent"

# A rotation that makes a T-spin (game.detect_spin) gets the spin sound, as in TETR.IO
func play_rotate_sound(rotated: bool):
	if rotated:
		play_sound("spin" if game.last_spin != Game.Spin.NONE else "rotate", 0.03)

# Locks the piece where its ghost is. A hard drop, the lock delay running out and the lock forced
# after too many lock resets all come through here, so all three get the same sounds and effects.
func lock_piece(hard: bool = false):
	var fx_pre = fx.before_hard_drop() if fx else {}
	var clear_info = game.hard_drop()
	if fx:
		fx.after_hard_drop(fx_pre, clear_info)
	play_placement_sounds(game, clear_info, hard, "you")
	var lines = clear_info["lines_cleared"].size()
	# Versus: what the attack did not cancel goes to the bot
	if bot_player != null:
		var sent = clear_info["attack"] - clear_info["blocked"]
		if sent > 0:
			bot_player.game.garbage.receive(sent, time_elapsed)

	if lines > 0:
		for i in range(0, clear_info["lines_cleared"].size() if fx == null else 0):
			var particle = GPUParticles2D.new()
			var process_material = ParticleProcessMaterial.new()

			process_material.particle_flag_disable_z = true
			process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
			process_material.emission_box_extents = Vector3(6 * tile_size, 1, 1)
			process_material.angle_max = 360
			process_material.gravity.y = 200
			process_material.scale_min = 0.3
			process_material.scale_max = 0.8
			process_material.scale_over_velocity_curve = size_curve_texture
			process_material.color_ramp = color_ramp_gradient_texture

			add_child(particle)
			particle.process_material = process_material
			particle.texture = tile_textures[7]
			particle.position = Vector2(grid_start.x + tile_size * 5, grid_start.y + clear_info["lines_cleared"][i] * tile_size + tile_size)
			particle.amount = 12
			particle.lifetime = 0.5
			particle.one_shot = true
			particle.explosiveness = 0.75
			# Not the finished signal: the compatibility renderer does not emit it in 4.2
			get_tree().create_timer(particle.lifetime + 0.5).timeout.connect(particle.queue_free)
			particle.emitting = true

	# The plain label; the effects draw their own perfect clear
	if clear_info["is_perfect_clear"] and not (fx and fx.on.has("perfect")):
		var perfect_clear_label = Label.new()
		perfect_clear_label.text = "PERFECT CLEAR"
		perfect_clear_label.horizontal_alignment = HorizontalAlignment.HORIZONTAL_ALIGNMENT_CENTER

		var mat = ShaderMaterial.new()
		mat.shader = load("res://rainbow.gdshader")
		mat.set_shader_parameter("size", Vector2(tile_size * 40, 1))

		perfect_clear_label.material = mat
		perfect_clear_label.add_theme_font_size_override("font_size", tile_size * 1.2)

		perfect_clear_label.position = Vector2(grid_start.x, grid_start.y + 12 * tile_size)
		perfect_clear_label.pivot_offset = Vector2(tile_size * 5, tile_size)
		perfect_clear_label.size = Vector2(tile_size * 10, tile_size * 2)
		perfect_clear_label.scale = Vector2(0, 0)

		var on_resize = func():
			mat.set_shader_parameter("size", Vector2(tile_size * 40, 1))
			perfect_clear_label.material = mat
			perfect_clear_label.add_theme_font_size_override("font_size", tile_size * 1.2)
			perfect_clear_label.position = Vector2(grid_start.x, grid_start.y + 12 * tile_size)
			perfect_clear_label.pivot_offset = perfect_clear_label.size / 2
			perfect_clear_label.size = Vector2(tile_size * 10, tile_size * 2)
		get_viewport().get_window().size_changed.connect(on_resize)

		var tween = create_tween()
		tween.tween_property(perfect_clear_label, "scale", Vector2(1, 1), 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(perfect_clear_label, "scale", Vector2(0, 0), 1).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_IN)

		add_sibling(perfect_clear_label)
		get_tree().create_timer(2).timeout.connect(func():
			get_viewport().get_window().size_changed.disconnect(on_resize)
			perfect_clear_label.queue_free()
		)

# The sounds of a placement by who ("you", or "bot" in versus: on the opponent bus): the drop, the
# clear, back-to-back, combo (from the second clear in a row, as in TETR.IO), the attack, the
# thunder of a big spike, garbage blocked or risen, and a perfect clear. The bot's attack is heard
# as it arrives (play_incoming), not as it leaves.
func play_placement_sounds(g: Game, info: Dictionary, hard: bool, who: String):
	var bus = "Master" if who == "you" else opponent_bus()
	play_sound("harddrop" if hard else "lock", 0.04, 0.0, bus)
	var lines = info["lines_cleared"].size()
	if lines > 0:
		if lines == 4:
			play_sound("clear_quad", 0.0, 0.0, bus)
		elif info["spin"] != Game.Spin.NONE:
			play_sound("clear_spin", 0.0, 0.0, bus)
		else:
			play_sound("clear_%d" % lines, 0.0, 0.0, bus)
		if info["b2b"] >= 1:
			play_sound("btb", 0.0, 0.0, bus)
		elif info["b2b_broken"]:
			play_sound("btb_break", 0.0, 0.0, bus)
		if g.combo >= 2:
			play_sound("combo_%d" % min(g.combo - 1, COMBO_SOUNDS), 0.0, 0.0, bus)
	elif info["combo_broken"]:
		play_sound("combo_break", 0.0, 0.0, bus)
	if info["attack"] > 0:
		# A shot, 60 ms after the clear sound so the two are heard apart
		if who == "you":
			play_sound_later(0.06, "garbage_out_" + size_name(info["attack"]))
		var step = thunder_step(who, info["attack"])
		if step >= 0:
			play_sound_later(0.12, "thunder_%d" % (step + 1), bus)
	if g.garbage != null:
		if info["blocked"] > 0:
			play_sound("block", 0.0, 0.0, bus)
		if info["tanked"] > 0:
			play_sound("garbage_rise", 0.0, 0.0, bus)
	if info["is_perfect_clear"]:
		play_sound("allclear", 0.0, 0.0, bus)

# Adds an attack to who's spike; returns the thunder step it passed (0-2), or -1
func thunder_step(who: String, attack: int) -> int:
	var spike = spikes[who]
	# The clock goes back to 0 on a restart: a new spike then too
	if time_elapsed - spike[1] > SPIKE_HOLD or time_elapsed < spike[1]:
		spike[0] = 0
	var before = spike[0]
	spike[0] += attack
	spike[1] = time_elapsed
	var step = -1
	for k in range(THUNDER_STEPS.size()):
		if before < THUNDER_STEPS[k] and spike[0] >= THUNDER_STEPS[k]:
			step = k
	return step

# Attack sizes, for the garbage sounds
func size_name(lines: int) -> String:
	if lines >= 8:
		return "large"
	return "medium" if lines >= 4 else "small"

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	if bot_player != null:
		if round_state != Round.PLAYING:
			update_round(delta)
			queue_redraw()
			return
		round_timer += delta
		respawn_age += delta
	time_elapsed += delta
	game.gravity_fall_delay = 1000 / (0.05 * game.number_of_lines_cleared + 1 + time_elapsed / 60)
	# Attacks arriving in the garbage queue. The one that brings it to BIG_INCOMING lines or more sets
	# off the alarm instead of the usual hit.
	var waiting_before = game.garbage.total() if game.garbage != null else 0
	play_incoming(game.update_garbage(time_elapsed), waiting_before)

	if game.topped_out:
		game.topped_out = false
		play_sound("topout")
		if mode == "survival":
			show_result(game.last_run_time)
		elif bot_player != null:
			if unlimited_lives:
				respawn()
			else:
				end_round("bot")
				queue_redraw()
				return

	if not result.is_empty():
		result["age"] += delta

	var was_blocked = not danger.is_empty()
	var was_high = danger_high
	var now_danger = game.danger()
	danger = now_danger["cells"]
	danger_high = now_danger["high"]
	# Like TETR.IO's damage alert: an alarm when the next placement would kill (the X's), and a
	# softer warning when the stack first gets near the top
	if not danger.is_empty() and not was_blocked:
		play_sound("alert", 0.0, 0.4)
	elif danger_high and not was_high:
		play_sound("warning", 0.0, 3.0)

	# If piece can't moving down start lock timer
	if (game.try_to_move_piece(Game.MoveDirections.DOWN).is_empty()):
		if game.drop_lock_reset_count >= Game.LOCK_RESETS:
			# Out of lock resets: lock as soon as it is on the ground, as TETR.IO does
			lock_piece()
		elif (game.drop_lock_time_begin == - 1):
			game.drop_lock_time_begin = time_elapsed
		elif (time_elapsed - game.drop_lock_time_begin > game.DROP_LOCK_DELAY / 1000.0):
			lock_piece()
	else:
		game.drop_lock_time_begin = -1

	handle_shift()

	if Input.is_key_pressed(GameConfig.get_setting("controls", "soft_drop")):
		if GameConfig.get_setting("handling", "sdf") == 0:
			for i in range(0, 20):
				game.move_piece(Game.MoveDirections.DOWN)
		elif last_sdf_time == - 1:
			last_sdf_time = time_elapsed
		else:
			# TETR.IO: SDF times gravity, but never slower than SDF x 3 rows a second (0.05 a frame).
			# Several steps in one frame when the interval is shorter than a frame.
			var rows_per_second = GameConfig.get_setting("handling", "sdf") * max(1000.0 / game.gravity_fall_delay, 3.0)
			var interval = 1.0 / rows_per_second
			var steps = 0
			var moved = false
			while time_elapsed - last_sdf_time > interval and steps < 24:
				moved = game.move_piece(Game.MoveDirections.DOWN) or moved
				last_sdf_time += interval
				steps += 1
			if moved:
				play_sound("softdrop", 0.03, 0.04)
	else:
		last_sdf_time = -1

	if (last_gravity_time != - 1 and time_elapsed - last_gravity_time > game.gravity_fall_delay / 1000.0):
		game.move_piece(Game.MoveDirections.DOWN)
		last_gravity_time = time_elapsed
		
	elif last_gravity_time == - 1:
		last_gravity_time = time_elapsed

	if bot_player != null:
		update_bot()

	queue_redraw()

# Attacks that arrived in the player's garbage queue (lines each), with the lines that were waiting
# before. The one that brings it to BIG_INCOMING lines or more sets off the alarm instead of the
# usual hit.
func play_incoming(arrived: Array, waiting_before: int):
	if arrived.is_empty():
		return
	if waiting_before < BIG_INCOMING and game.garbage.total() >= BIG_INCOMING:
		play_sound("garbage_alarm")
	else:
		for lines in arrived:
			play_sound("garbage_in_" + size_name(lines))

# ---- Versus ----------------------------------------------------------------------------------

# The bot thinks and plays; what its attack does not cancel comes to the player
func update_bot():
	var info = bot_player.update(time_elapsed)
	if not info.is_empty():
		play_placement_sounds(bot_player.game, info, true, "bot")
		if fx and fx.has_method("opponent_clear"):
			fx.opponent_clear(bot_grid_start, info, bot_player.last_cells)
		if info["attack"] > 0:
			bot_view.on_attack(info["attack"])
		var sent = info["attack"] - info["blocked"]
		if sent > 0:
			var before = game.garbage.total()
			game.garbage.receive(sent, time_elapsed)
			play_incoming([sent], before)
			bot_view.launch(sent)
	if bot_player.game.topped_out:
		bot_player.game.topped_out = false
		end_round("you")

# The bot thinks on a worker thread: stop it before the scene goes
func _exit_tree():
	if bot_player != null:
		bot_player.halt()

func start_round():
	game.restart()
	game.topped_out = false
	bot_player.reset(0.0)
	if bot_view != null:
		bot_view.clear()
	time_elapsed = 0
	last_gravity_time = -1
	shift_direction = 0
	danger = []
	danger_high = false
	round_state = Round.COUNTDOWN
	round_timer = 0.0
	top_outs = 0
	respawn_age = 99.0
	play_sound("rotate")

# Unlimited lives: the player's board starts again with an empty garbage queue; the round, the
# clock and the bot go on, and so do the player's stats (speed, APM and lines are for the round)
func respawn():
	var kept = [game.pieces_placed, game.total_attack, game.number_of_lines_cleared]
	game.restart()
	game.topped_out = false
	game.pieces_placed = kept[0]
	game.total_attack = kept[1]
	game.number_of_lines_cleared = kept[2]
	top_outs += 1
	respawn_age = 0.0
	shift_direction = 0
	danger = []
	danger_high = false
	if fx and fx.has_method("_new_run"):
		fx._new_run()

func update_round(delta: float):
	var before = round_timer
	round_timer += delta
	if round_state == Round.COUNTDOWN:
		for mark in [0.5, 1.0]:
			if before < mark and round_timer >= mark:
				play_sound("rotate")
		if round_timer >= COUNTDOWN_TIME:
			round_state = Round.PLAYING
			round_timer = 0.0
			play_sound("start")
	elif round_state == Round.OVER and round_timer >= OVER_TIME:
		start_round()

func end_round(winner: String):
	bot_player.halt()
	round_state = Round.OVER
	round_timer = 0.0
	round_winner = winner
	score[0 if winner == "you" else 1] += 1
	if winner == "you":
		play_sound("allclear")

# The text over a board for the round, [text, size in cells, colour], or [] for none. for_player:
# the player's board, else the bot's.
func round_overlay(for_player: bool) -> Array:
	if bot_player == null:
		return []
	match round_state:
		Round.COUNTDOWN:
			return [str(3 - int(round_timer / 0.5)), 3.0, Color(1, 1, 1)]
		Round.PLAYING:
			if round_timer < 0.5:
				return ["GO", 2.6, Color(1.0, 0.8, 0.32, 1.0 - round_timer / 0.5)]
			if for_player and respawn_age < 1.0:
				return ["TOP OUT", 1.6, Color(1.0, 0.22, 0.26, 1.0 - clamp((respawn_age - 0.6) / 0.4, 0.0, 1.0))]
		Round.OVER:
			var won = (round_winner == "you") == for_player
			return ["WIN" if won else "LOSE", 2.2, Color(1.0, 0.8, 0.32) if won else Color(1.0, 0.22, 0.26)]
	return []

# The score between the boards, the player's name under the board, and the round's text over it
func draw_versus():
	var ts = tile_size
	var cx = window_center.x
	var y = grid_start.y + 2.9 * ts
	centred_string("%d – %d" % score, cx, y, int(1.4 * ts), Color(1, 1, 1))
	centred_string("YOU", cx - 3.4 * ts, y - 0.2 * ts, int(0.6 * ts), Color(0.6, 0.67, 0.65))
	centred_string("BOT", cx + 3.4 * ts, y - 0.2 * ts, int(0.6 * ts), Color(0.6, 0.67, 0.65))
	centred_string("YOU · ∞ LIVES" if unlimited_lives else "YOU", grid_start.x + 5 * ts, grid_start.y + 25.2 * ts, int(0.7 * ts), Color(1, 1, 1, 0.9))
	if unlimited_lives:
		centred_string("1 TOP OUT" if top_outs == 1 else "%d TOP OUTS" % top_outs, grid_start.x + 5 * ts, grid_start.y + 26.2 * ts,
			int(0.55 * ts), Color(1.0, 0.45, 0.45) if top_outs > 0 else Color(0.6, 0.67, 0.65))
	# The board flashes red as it starts again
	if respawn_age < 0.5:
		draw_rect(Rect2(grid_start.x, grid_start.y + 4 * ts, 10 * ts, 20 * ts), Color(1.0, 0.22, 0.26, 0.35 * (1.0 - respawn_age / 0.5)))
	var overlay = round_overlay(true)
	if not overlay.is_empty():
		centred_string(overlay[0], grid_start.x + 5 * ts, grid_start.y + 14.5 * ts, int(overlay[1] * ts), overlay[2], true)

# outlined: a dark edge, for text over the blocks of a board
func centred_string(text: String, x: float, y: float, size: int, color: Color, outlined: bool = false):
	var width = hud_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at = Vector2(x - width / 2, y)
	if outlined:
		draw_string_outline(hud_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, int(0.18 * tile_size), Color(0.04, 0.02, 0.03, 0.9 * color.a))
	draw_string(hud_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)

const BlockSkin = preload("res://src/base/block_skin.gd")

# The pieces' colours: the "vivid" palette of tools/block_styles.py, made in OKLCH so that no piece
# looks much brighter than the others. The effects take their colours from here too.
const COLORS = {
	Tile.TileType.I_PIECE: Color(0.0588, 0.8118, 0.8745),   # 0fcfdf
	Tile.TileType.J_PIECE: Color(0.2, 0.4627, 0.9804),      # 3376fa
	Tile.TileType.L_PIECE: Color(0.9529, 0.5098, 0.1098),   # f3821c
	Tile.TileType.O_PIECE: Color(0.9569, 0.8078, 0.1373),   # f4ce23
	Tile.TileType.S_PIECE: Color(0.3333, 0.8157, 0.2039),   # 55d034
	Tile.TileType.T_PIECE: Color(0.7569, 0.3255, 0.8784),   # c153e0
	Tile.TileType.Z_PIECE: Color(0.9608, 0.2353, 0.2549),   # f53c41
	Tile.TileType.GHOST: Color(1, 1, 1, 0.2),
	Tile.TileType.GARBAGE: Color(0.5255, 0.5255, 0.5255),   # 868686
	Tile.TileType.EMPTY: Color(0, 0, 0, 0),
	Tile.TileType.DISABLED: Color(0.5, 0.5, 0.5, 1)
}

var tile_textures: Array[Texture] = []

var window_size
var window_center
var tile_size
var grid_start

func on_window_resize():
	layout()

# The board in the middle; in versus, the player's on the left and the bot's on the right, the
# two boards the same distance either side of the middle of the window (as in TETR.IO), with only
# the player's queue and the bot's hold between them, and the cells small enough for all of it
# (the stats on the left to the bot's queue on the right) to fit across the window
func layout():
	window_size = get_viewport_rect().size
	window_center = window_size / 2
	if mode == "versus":
		tile_size = min(window_size.y / 30, window_size.x / 44)
		grid_start = Vector2(window_center.x - 15.5 * tile_size, window_center.y - 12.5 * tile_size)
		bot_grid_start = Vector2(window_center.x + 5.5 * tile_size, grid_start.y)
		attack_target = bot_grid_start + Vector2(-0.26 * tile_size, 21 * tile_size)
	else:
		tile_size = window_size.y / 30
		grid_start = Vector2(window_center.x - 5 * tile_size - tile_size / 2, window_center.y - 12 * tile_size - tile_size / 2)

@onready var tile_map: TileMap = $"../TileMap"

func draw_tile(tile: Tile.TileType, x: float, y: float, joins: int):
	if (tile == Tile.TileType.EMPTY):
		return
	var rect = Rect2(x, y, tile_size, tile_size)
	if (tile == Tile.TileType.GHOST):
		if fx and fx.on.has("ghost"):
			fx.draw_ghost(self, x, y)
		else:
			BlockSkin.draw_ghost(self, rect)
	else:
		BlockSkin.draw(self, rect, COLORS[tile], joins)

# Which sides of the board cell (i, j) join the same piece. A locked cell remembers it; the falling
# piece and its ghost join whatever of their own kind is next to them (there is only one of each).
func joins_at(i: int, j: int) -> int:
	return joins_in_game(game, i, j)

static func joins_in_game(g: Game, i: int, j: int) -> int:
	var tile = g.board[i][j]
	if tile.state == Tile.State.PLACED:
		return tile.connections
	var joins = 0
	for side in [[0, -1, Tile.UP], [0, 1, Tile.DOWN], [-1, 0, Tile.LEFT], [1, 0, Tile.RIGHT]]:
		var x = i + side[0]
		var y = j + side[1]
		if x < 0 or x >= 10 or y < 0 or y >= 24:
			continue
		var other = g.board[x][y]
		if tile.state == Tile.State.FALLING and other.state == Tile.State.FALLING:
			joins |= side[2]
		elif tile.type == Tile.TileType.GHOST and other.type == Tile.TileType.GHOST and other.state == Tile.State.EMPTY:
			joins |= side[2]
	return joins

var hud_font: Font = load("res://assets/JetBrainsMono-SemiBold.ttf")

func _draw():
	draw_texture(color_ramp_gradient_texture, Vector2(0, 10))

	if (game.game_started):
		# Draw grid background
		if fx:
			fx.draw_panel(self)
		else:
			draw_rect(Rect2(grid_start.x, grid_start.y + 4 * tile_size, 10 * tile_size, 20 * tile_size), Color(0, 0, 0, 0.5))

		# Draw grid:
		for i in range(0, 10):
			for j in range(4, 24):
				draw_rect(Rect2(i * tile_size + grid_start.x, j * tile_size + grid_start.y, tile_size, tile_size), Color(1, 1, 1, fx.grid_alpha if fx else 0.1), false, 2.0)

		# Draw board
		for i in range(0, 10):
			for j in range(0, 24):
				draw_tile(game.board[i][j].type, i * tile_size + grid_start.x, j * tile_size + grid_start.y, joins_at(i, j))

		# Draw Hold HUD text
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size("HOLD", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 5 * tile_size), "HOLD", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size)

		if (game.hold_piece != null):
			# Draw hold piece
			for i in range(game.hold_piece.tiles.size()):
				for j in range(game.hold_piece.tiles[i].size()):
					if game.hold_piece.tiles[i][j].type != Tile.TileType.EMPTY:
						var joins = BlockSkin.joins_in(game.hold_piece.tiles, i, j)
						if (game.already_held):
							draw_tile(Tile.TileType.GARBAGE, j * tile_size + grid_start.x - 5 * tile_size, i * tile_size + grid_start.y + 6 * tile_size, joins)
						else:
							draw_tile(game.hold_piece.tiles[i][j].type, j * tile_size + grid_start.x - 5 * tile_size, i * tile_size + grid_start.y + 6 * tile_size, joins)
		
		# Draw Queue Text HUD
		draw_string(hud_font, Vector2(grid_start.x + 11 * tile_size, grid_start.y + 5 * tile_size), "QUEUE", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size)

		# Queue
		for i in range(game.piece_queue.size()):
			for j in range(game.piece_queue[i].tiles.size()):
				for k in range(game.piece_queue[i].tiles[j].size()):
					if game.piece_queue[i].tiles[j][k].type != Tile.TileType.EMPTY:
						draw_tile(game.piece_queue[i].tiles[j][k].type, k * tile_size + grid_start.x + 11 * tile_size, j * tile_size + grid_start.y + 6 * tile_size + i * 3 * tile_size, BlockSkin.joins_in(game.piece_queue[i].tiles, j, k))

		# The stats left of the board: speed (pieces a second), attack (TETR.IO's APM: lines of
		# attack a minute), lines cleared and the time
		var minutes = max(time_elapsed, 0.001) / 60.0
		var stats = [
			["SPEED", "%.2f PPS" % (game.pieces_placed / minutes / 60.0)],
			["APM", "%.1f" % (game.total_attack / minutes)],
			["LINES", str(game.number_of_lines_cleared)],
			["TIME", format_time(time_elapsed)],
		]
		for k in range(stats.size()):
			var y = grid_start.y + (10.0 + 3.6 * k) * tile_size
			hud_right(stats[k][0], y)
			hud_right(stats[k][1], y + 1.6 * tile_size)

		if game.garbage != null:
			draw_garbage_meter()
		for cell in danger:
			draw_danger_mark(cell)
		if not danger.is_empty():
			draw_warning_sign()
		draw_result()
		if bot_player != null:
			draw_versus()

# HUD text that ends a cell left of the board
func hud_right(text: String, y: float):
	var width = hud_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x
	draw_string(hud_font, Vector2(grid_start.x - tile_size - width, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size)

# MM:SS.sss, or HH:MM:SS.sss from an hour on
func format_time(t: float) -> String:
	var whole = int(t)
	var hours = whole / 3600
	var minutes = (whole % 3600) / 60
	var seconds = whole % 60
	var milliseconds = int((t - whole) * 1000)
	if hours > 0:
		return "%02d:%02d:%02d.%03d" % [hours, minutes, seconds, milliseconds]
	return "%02d:%02d.%03d" % [minutes, seconds, milliseconds]

# Incoming garbage, as TETR.IO shows it: a bar along the left edge of the board, a cell high for each
# line, the oldest attack at the bottom. Red once it can rise; pale and blinking while it is on its
# way (Garbage.GARBAGE_DELAY). With BIG_INCOMING lines or more waiting, the red flashes.
func draw_garbage_meter():
	draw_garbage_meter_on(self, game.garbage, grid_start)

# The same for any board: the bot's board in versus draws its meter with this too
func draw_garbage_meter_on(canvas: CanvasItem, garbage, origin: Vector2):
	var x = origin.x - 0.4 * tile_size
	var width = 0.28 * tile_size
	var bottom = origin.y + 24 * tile_size
	canvas.draw_rect(Rect2(x, origin.y + 4 * tile_size, width, 20 * tile_size), Color(0, 0, 0, 0.45))
	var used = 0
	var big = garbage.total() >= BIG_INCOMING
	# Past 20 lines the bar runs on above the board, as far as the top of the window
	var room = int((bottom - 0.8 * tile_size) / tile_size)
	for attack in garbage.queue:
		var lines = min(attack["lines"], room - used)
		if lines <= 0:
			break
		var color = Color(1.0, 0.2, 0.24)
		if big:
			color = color.lerp(Color(1.0, 0.9, 0.9), 0.3 + 0.3 * sin(time_elapsed * 18.0))
		if not garbage.is_ready(attack, time_elapsed):
			color = Color(1.0, 0.72, 0.6, 0.55 + 0.35 * sin(time_elapsed * 40.0))
		canvas.draw_rect(Rect2(x, bottom - (used + lines) * tile_size + 1, width, lines * tile_size - 2), color)
		used += lines
	# and its top carries the number of lines waiting
	var total = garbage.total()
	if total > 20:
		var size = int(0.6 * tile_size)
		var label = str(total)
		var w = hud_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var at = Vector2(x + width / 2 - w / 2, bottom - used * tile_size - 0.2 * tile_size)
		canvas.draw_string_outline(hud_font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, int(0.14 * tile_size), Color(0.05, 0.02, 0.03, 0.9))
		canvas.draw_string(hud_font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(1.0, 0.3, 0.32))

# TETR.IO's warning: an X on each cell where the next piece would appear, when it would not fit
func draw_danger_mark(cell: Vector2):
	var pulse = 0.8 + 0.2 * sin(time_elapsed * 12.0)
	var whole = Rect2(grid_start + cell * tile_size, Vector2(tile_size, tile_size))
	draw_rect(whole.grow(-1), Color(1.0, 0.22, 0.26, 0.2 * pulse))
	draw_rect(whole.grow(-1), Color(1.0, 0.22, 0.26, 0.55 * pulse), false, 2.0)
	var r = whole.grow(-0.14 * tile_size)
	var c = Color(1.0, 0.22, 0.26, pulse)
	var w = max(2.0, 0.14 * tile_size)
	# A dark edge under the red, so the X shows on any piece colour
	for pass_color in [Color(0, 0, 0, 0.7), c]:
		var width = w * (1.8 if pass_color != c else 1.0)
		draw_line(r.position, r.end, pass_color, width)
		draw_line(Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), pass_color, width)

# TETR.IO's ⚠: a red warning sign above the board, beside the X's, while the next placement would kill
func draw_warning_sign():
	var pulse = 0.8 + 0.2 * sin(time_elapsed * 12.0)
	var centre = grid_start + Vector2(8.5, 2.0) * tile_size
	var r = 0.9 * tile_size
	draw_colored_polygon(PackedVector2Array([centre + Vector2(0, -r), centre + Vector2(r * 1.1, r * 0.8), centre + Vector2(-r * 1.1, r * 0.8)]),
		Color(1.0, 0.22, 0.26, pulse))
	var size = int(1.1 * tile_size)
	var width = hud_font.get_string_size("!", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(hud_font, Vector2(centre.x - width / 2, centre.y + 0.62 * tile_size), "!", HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0.08, 0.02, 0.03))

# A survival run ended: keep its time, and the best one, on screen over the new game for a while
func show_result(t: float):
	var best = GameConfig.config.get_value("records", "survival", 0.0)
	result = {"time": t, "best": max(best, t), "new_best": t > best, "age": 0.0}
	if t > best:
		GameConfig.change_setting("records", "survival", t)

func draw_result():
	if result.is_empty():
		return
	var age = result["age"]
	if age > 4.0:
		result = {}
		return
	var alpha = clamp(age / 0.15, 0.0, 1.0) * clamp((4.0 - age) / 0.6, 0.0, 1.0)
	var centre = grid_start.x + 5 * tile_size
	var lines = [
		["SURVIVED", 0.7, Color(0.6, 0.67, 0.65)],
		[format_time(result["time"]), 1.5, Color(1, 1, 1)],
		["NEW BEST" if result["new_best"] else "BEST " + format_time(result["best"]), 0.6,
			Color(1.0, 0.8, 0.32) if result["new_best"] else Color(0.6, 0.67, 0.65)],
	]
	var y = grid_start.y + 11 * tile_size
	for line in lines:
		var size = int(line[1] * tile_size)
		y += line[1] * tile_size * 1.25
		var width = hud_font.get_string_size(line[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		draw_string(hud_font, Vector2(centre - width / 2, y), line[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(line[2], alpha))

# A tap moves the piece once (in _input) and starts the auto shift for that direction. While both
# directions are held the one pressed last wins; let go of it and the other one charges DAS again.
func start_shift(direction: int):
	shift_direction = direction
	next_shift_time = time_elapsed + GameConfig.get_setting("handling", "das") / 1000.0

func handle_shift():
	var left_held = Input.is_key_pressed(GameConfig.get_setting("controls", "left"))
	var right_held = Input.is_key_pressed(GameConfig.get_setting("controls", "right"))
	if (shift_direction == -1 and not left_held) or (shift_direction == 1 and not right_held):
		shift_direction = 0
	if shift_direction == 0:
		if left_held:
			start_shift(-1)
		elif right_held:
			start_shift(1)
		return
	if time_elapsed < next_shift_time:
		return

	var move = Game.MoveDirections.LEFT if shift_direction == -1 else Game.MoveDirections.RIGHT
	var arr = GameConfig.get_setting("handling", "arr") / 1000.0
	var moved = false
	if arr == 0:
		# ARR 0 goes straight to the wall
		for i in range(0, 10):
			moved = game.move_piece(move) or moved
	else:
		# Several shifts in one frame when ARR is shorter than a frame
		var shifts = 0
		while time_elapsed >= next_shift_time and shifts < 10:
			moved = game.move_piece(move) or moved
			next_shift_time += arr
			shifts += 1
		if shifts == 10:
			next_shift_time = time_elapsed + arr
	if moved:
		play_sound("move", 0.04, 0.02)
