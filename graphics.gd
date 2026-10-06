extends Node2D

class_name MainGame

var game: Game
var fx = null
const FX_PRESET = "flash,particles,wave,ca,callouts,trail,bloom,spinflash,sparkles,panel,lens"

# Called when the node enters the scene tree for the first time.
func _ready():
	get_tree().get_root().size_changed.connect(on_window_resize)
	window_size = get_viewport_rect().size
	window_center = window_size / 2
	tile_size = window_size.y / 30
	grid_start = Vector2(window_center.x - 5 * tile_size - tile_size / 2, window_center.y - 12 * tile_size - tile_size / 2)
	GameConfig.create()

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

	game = Game.new()
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

var hard_drop_sound = load("res://assets/hard_drop.wav")
var perfect_clear_sound = load("res://assets/perfect_clear.wav")
var line_clear_sound = load("res://assets/line_clear.wav")
var combo_max_sound = load("res://assets/combo_max.wav")
var combo_sounds = [
	load("res://assets/combo_1.wav"),
	load("res://assets/combo_2.wav"),
	load("res://assets/combo_3.wav"),
	load("res://assets/combo_4.wav"),
	load("res://assets/combo_5.wav"),
	load("res://assets/combo_6.wav"),
	load("res://assets/combo_7.wav"),
	load("res://assets/combo_8.wav"),
	load("res://assets/combo_9.wav"),
	load("res://assets/combo_10.wav"),
	load("res://assets/combo_11.wav"),
	load("res://assets/combo_12.wav"),
	load("res://assets/combo_13.wav"),
	# There is no combo_14.wav: combo_15.wav is the next note of the scale after combo_13
	load("res://assets/combo_15.wav"),
]

# TODO: Implement input remapping
func _input(event):
	# If space is pressed, hard drop the piece
	if event is InputEventKey:
		var just_pressed = event.is_pressed() and not event.is_echo()

		if event.is_action_pressed("settings"):
			get_tree().change_scene_to_file("res://settings.tscn")

		if event.keycode == GameConfig.get_setting("controls", "hard_drop")&&just_pressed:
			play_sound(hard_drop_sound, 0)
			lock_piece()

		elif event.keycode == GameConfig.get_setting("controls", "left")&&just_pressed:
			game.move_piece(Game.MoveDirections.LEFT)
			start_shift(-1)

		elif event.keycode == GameConfig.get_setting("controls", "right")&&just_pressed:
			game.move_piece(Game.MoveDirections.RIGHT)
			start_shift(1)

		elif event.keycode == GameConfig.get_setting("controls", "soft_drop")&&just_pressed:
			if (GameConfig.get_setting("handling", "sdf") == 0):
				for i in range(0, 20):
					game.move_piece(Game.MoveDirections.DOWN)
			game.move_piece(Game.MoveDirections.DOWN)
			
		elif event.keycode == GameConfig.get_setting("controls", "rotate_cw")&&just_pressed:
			game.rotate_piece(Piece.RotationAmount.NINETY_DEGREES)
			
		elif event.keycode == GameConfig.get_setting("controls", "rotate_ccw")&&just_pressed:
			game.rotate_piece(Piece.RotationAmount.TWO_HUNDRED_SEVENTY_DEGREES)
			
		elif event.keycode == GameConfig.get_setting("controls", "rotate_180")&&just_pressed:
			game.rotate_piece(Piece.RotationAmount.ONE_HUNDRED_EIGHTY_DEGREES)
			
		elif event.keycode == GameConfig.get_setting("controls", "hold")&&just_pressed:
			game.hold()
		elif event.keycode == GameConfig.get_setting("controls", "restart")&&just_pressed:
			game.restart()
			time_elapsed = 0
			last_gravity_time = -1

	if fx and event is InputEventKey and event.is_pressed() and not event.is_echo():
		fx.after_input(event.keycode)

func play_sound(stream: AudioStream, volume_db: float = 5):
	var player = AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	add_sibling(player)
	player.play()
	player.finished.connect(player.queue_free)

# Locks the piece where its ghost is. A hard drop, the lock delay running out and the lock forced
# after too many lock resets all come through here, so all three get the same sounds and effects.
func lock_piece():
	var fx_pre = fx.before_hard_drop() if fx else {}
	var clear_info = game.hard_drop()
	if fx:
		fx.after_hard_drop(fx_pre, clear_info)
	if (!clear_info["lines_cleared"].is_empty()):
		play_sound(line_clear_sound)
		if game.combo > 14:
			play_sound(combo_max_sound)
		else:
			play_sound(combo_sounds[game.combo - 1])

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

	if clear_info["is_perfect_clear"]:
		play_sound(perfect_clear_sound)

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

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	time_elapsed += delta
	game.gravity_fall_delay = 1000 / (0.05 * game.number_of_lines_cleared + 1 + time_elapsed / 60)

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
			while time_elapsed - last_sdf_time > interval and steps < 24:
				game.move_piece(Game.MoveDirections.DOWN)
				last_sdf_time += interval
				steps += 1
	else:
		last_sdf_time = -1

	if (last_gravity_time != - 1 and time_elapsed - last_gravity_time > game.gravity_fall_delay / 1000.0):
		game.move_piece(Game.MoveDirections.DOWN)
		last_gravity_time = time_elapsed
		
	elif last_gravity_time == - 1:
		last_gravity_time = time_elapsed

	queue_redraw()

const COLORS = {
	Tile.TileType.I_PIECE: Color(0, 1, 1, 1),
	Tile.TileType.J_PIECE: Color(0, 0, 1, 1),
	Tile.TileType.L_PIECE: Color(1, 0.5, 0, 1),
	Tile.TileType.O_PIECE: Color(1, 1, 0, 1),
	Tile.TileType.S_PIECE: Color(0, 1, 0, 1),
	Tile.TileType.T_PIECE: Color(1, 0, 1, 1),
	Tile.TileType.Z_PIECE: Color(1, 0, 0, 1),
	Tile.TileType.GHOST: Color(1, 1, 1, 0.2),
	Tile.TileType.EMPTY: Color(0, 0, 0, 0),
	Tile.TileType.DISABLED: Color(0.5, 0.5, 0.5, 1)
}

var tile_textures: Array[Texture] = []

var window_size
var window_center
var tile_size
var grid_start

func on_window_resize():
	window_size = get_viewport_rect().size
	window_center = window_size / 2
	tile_size = window_size.y / 30
	grid_start = Vector2(window_center.x - 5 * tile_size - tile_size / 2, window_center.y - 12 * tile_size - tile_size / 2)

@onready var tile_map: TileMap = $"../TileMap"
@onready var tile_map_texture: Texture2D = tile_map.tile_set.get_source(0).texture

func draw_tile(tile: Tile.TileType, x: int, y: int):
	if (tile == Tile.TileType.EMPTY):
		return

	var atlas_coord: int = int(tile)

	var src_region = tile_map.tile_set.get_source(0).get_tile_texture_region(Vector2i(0, 0), 0)
	var dest_region = tile_map.tile_set.get_source(0).get_tile_texture_region(Vector2i(atlas_coord, 0), 0)

	src_region.size.x *= float(tile_size / src_region.size.x)
	src_region.size.y *= float(tile_size / src_region.size.y)
	src_region.position.x = x
	src_region.position.y = y

	if (tile == Tile.TileType.GHOST):
		if fx and fx.on.has("ghost"):
			fx.draw_ghost(self, x, y)
		else:
			draw_texture_rect_region(tile_map_texture, src_region, dest_region, Color(1, 1, 1, 0.2))
	else:
		draw_texture_rect_region(tile_map_texture, src_region, dest_region)

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
				draw_tile(game.board[i][j].type, i * tile_size + grid_start.x, j * tile_size + grid_start.y)

		# Draw Hold HUD text
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size("HOLD", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 5 * tile_size), "HOLD", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size)

		if (game.hold_piece != null):
			# Draw hold piece
			for i in range(game.hold_piece.tiles.size()):
				for j in range(game.hold_piece.tiles[i].size()):
					if game.hold_piece.tiles[i][j].type != Tile.TileType.EMPTY:
						if (game.already_held):
							draw_tile(Tile.TileType.GARBAGE, j * tile_size + grid_start.x - 5 * tile_size, i * tile_size + grid_start.y + 6 * tile_size)
						else:
							draw_tile(game.hold_piece.tiles[i][j].type, j * tile_size + grid_start.x - 5 * tile_size, i * tile_size + grid_start.y + 6 * tile_size)
		
		# Draw Queue Text HUD
		draw_string(hud_font, Vector2(grid_start.x + 11 * tile_size, grid_start.y + 5 * tile_size), "QUEUE", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size)

		# Queue
		for i in range(game.piece_queue.size()):
			for j in range(game.piece_queue[i].tiles.size()):
				for k in range(game.piece_queue[i].tiles[j].size()):
					if game.piece_queue[i].tiles[j][k].type != Tile.TileType.EMPTY:
						draw_tile(game.piece_queue[i].tiles[j][k].type, k * tile_size + grid_start.x + 11 * tile_size, j * tile_size + grid_start.y + 6 * tile_size + i * 3 * tile_size)

		# Lines cleared HUD
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size("LINES", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 16 * tile_size), "LINES", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size, Color(1, 1, 1, 1), HORIZONTAL_ALIGNMENT_RIGHT)
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size(str(game.number_of_lines_cleared), HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 18 * tile_size), str(game.number_of_lines_cleared), HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size, Color(1, 1, 1, 1), HORIZONTAL_ALIGNMENT_RIGHT)

		# Time HUD
		# MM:SS.sss if < 1 hour
		# HH:MM:SS.sss if >= 1 hour
		var time_string = ""
		var time_elapsed_seconds = int(time_elapsed)
		var hours = time_elapsed_seconds / 3600
		var minutes = (time_elapsed_seconds % 3600) / 60
		var seconds = time_elapsed_seconds % 60
		var milliseconds = int((time_elapsed - int(time_elapsed)) * 1000)
		if (hours > 0):
			time_string = ("%02d" % hours) + ":" + ("%02d" % minutes) + ":" + ("%02d" % seconds) + "." + ("%03d" % milliseconds)
		else:
			time_string = ("%02d" % minutes) + ":" + ("%02d" % seconds) + "." + ("%03d" % milliseconds)
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size("TIME", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 21 * tile_size), "TIME", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size, Color(1, 1, 1, 1), HORIZONTAL_ALIGNMENT_RIGHT)
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size(time_string, HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 23 * tile_size), time_string, HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size, Color(1, 1, 1, 1), HORIZONTAL_ALIGNMENT_RIGHT)

		# Speed HUD
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size("SPEED", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 10 * tile_size), "SPEED", HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size, Color(1, 1, 1, 1), HORIZONTAL_ALIGNMENT_RIGHT)
		draw_string(hud_font, Vector2(grid_start.x - 1 * tile_size - hud_font.get_string_size("%.2f PPS" % (float(game.pieces_placed) / time_elapsed), HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size).x, grid_start.y + 12 * tile_size), "%.2f PPS" % (float(game.pieces_placed) / time_elapsed), HORIZONTAL_ALIGNMENT_LEFT, -1, tile_size, Color(1, 1, 1, 1), HORIZONTAL_ALIGNMENT_RIGHT)

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
	if arr == 0:
		# ARR 0 goes straight to the wall
		for i in range(0, 10):
			game.move_piece(move)
		return
	# Several shifts in one frame when ARR is shorter than a frame
	var shifts = 0
	while time_elapsed >= next_shift_time and shifts < 10:
		game.move_piece(move)
		next_shift_time += arr
		shifts += 1
	if shifts == 10:
		next_shift_time = time_elapsed + arr
