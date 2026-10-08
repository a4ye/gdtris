class_name Game

var soft_dropping: bool = false

enum MoveDirections {
	LEFT,
	RIGHT,
	DOWN
}

# The List of the coordinates for the non-empty squares of the current piece
# (0, 0) is the top left of the board
# (9, 23) is the bottom right of the board
var current_piece_coordinates: Array[Vector2]

var piece_queue: Array[Piece]

var current_piece: Piece

# The top left corner of the bounding box for the current piece
var current_piece_top_left_corner: Vector2

var ghost_coordinates: Array[Vector2]
var hold_piece: Piece = null
var already_held: bool = false

# Stores the highest row that contains a piece, 0 is the highest row (for performance)
var highest_piece_row: int

var bag_1: Array[Piece.Pieces]
var bag_2: Array[Piece.Pieces]

var number_of_lines_cleared: int = 0
var pieces_placed: int = 0
var total_attack: int = 0  # lines of attack made this game (TETR.IO's APM counts these)

# How often a piece falls in milliseconds
var gravity_fall_delay: int = 1000

# Pieces locks after 0.5s on the ground
var drop_lock_time_begin = -1
const DROP_LOCK_DELAY = 500

var game_started: bool = false
var game_ended: bool = false

# Lock resets, as in TETR.IO: each move or rotation resets the lock delay and uses one reset. They
# refill only when the piece falls lower than it has been. With all 15 used, the piece locks as
# soon as it is on the ground (MainGame._process).
const LOCK_RESETS = 15
var drop_lock_reset_count: int = 0
# The lowest row the piece's top left corner has reached
var lowest_row: int = 0

# Number of lines cleared in a row
var combo: int = 0

# Back-to-back: quads and spin clears in a row, with no other clear between. -1 is none, 0 the
# first, 1 is "B2B x1" (as TETR.IO counts)
var b2b: int = -1

# Attack (lines sent), with TETR.IO's season 1 rules (TETRA LEAGUE before 2024): see tetrio_attack()
enum Spin { NONE, MINI, FULL }
const ATTACK = {
	Spin.NONE: [0, 0, 1, 2, 4],
	Spin.MINI: [0, 0, 1, 2, 10],
	Spin.FULL: [0, 2, 4, 6, 10],
}
const ALL_CLEAR_ATTACK = 10

# The spin the last rotation made. A move or a fall cancels it: a spin needs the last thing the
# piece did to be a rotation.
var last_spin: int = Spin.NONE

# Set at a top out (top_out), when the game restarts; MainGame plays the sound and clears it
var topped_out: bool = false

# If player is still alive
var alive = true

# Survival mode (enable_survival): an opponent sends garbage, which the player blocks or tanks
const Garbage = preload("res://src/base/garbage.gd")
const Survival = preload("res://src/base/survival.gd")
var garbage = null  # the incoming queue
var attacker = null
# The game clock at the last top out, before it went back to 0
var last_run_time: float = 0.0
# False in versus: a top out ends the round and leaves the board as it was (the match restarts
# both games); otherwise the game restarts at once
var auto_restart: bool = true

var board: Array[Array]

func restart():
	# Initialize the board and other variables
	# Game is 10 x 24
	for i in range(10):
		for j in range(24):
			board[i][j].state = Tile.State.EMPTY
			board[i][j].type = Tile.TileType.EMPTY
			board[i][j].connections = 0

	piece_queue.clear()
	current_piece_coordinates.clear()
	ghost_coordinates.clear()
	highest_piece_row = 24

	# Initialize the bags
	bag_1.clear()
	bag_2.clear()

	# Add a pieces to bag 1 and shuffle
	var random_values: Array[int] = []
	for i in range(0, 7):
		random_values.push_back(i)
	random_values.shuffle()

	for value in random_values:
		bag_1.push_back(Piece.Pieces.values()[value])

	random_values.clear()
	# Add a pieces to bag 2 and shuffle
	for i in range(0, 7):
		random_values.push_back(i)
	random_values.shuffle()

	for value in random_values:
		bag_2.push_back(Piece.Pieces.values()[value])

	# Fill the queue with 5 pieces
	for i in range(5):
		piece_queue.push_back(get_piece_from_bag())

	hold_piece = null
	already_held = false
	number_of_lines_cleared = 0
	gravity_fall_delay = 1000
	drop_lock_time_begin = -1
	game_ended = false
	drop_lock_reset_count = 0
	combo = 0
	b2b = -1
	alive = true
	pieces_placed = 0
	total_attack = 0
	MainGame.last_gravity_time = -1
	if garbage != null:
		garbage.clear()
	if attacker != null:
		attacker.reset()

	spawn_new_piece_from_bag()
	game_started = true

func get_piece_from_bag():
	var piece = Piece.new(bag_1.pop_front())
	bag_1.push_back(bag_2.pop_front())

	if bag_2.is_empty():
		# Add pieces to bag 2 and shuffle
		var random_values: Array[int] = []
		for i in range(0, 7):
			random_values.push_back(i)
		random_values.shuffle()

		for value in random_values:
			bag_2.push_back(Piece.Pieces.values()[value])

	return piece

func hold() -> bool:
	if already_held:
		return false

	# Clear the current piece
	for point in current_piece_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	# Clear the ghost
	for point in ghost_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	# Hold the piece
	if hold_piece == null:
		hold_piece = Piece.new(current_piece.piece_type)
		already_held = true
		spawn_new_piece_from_bag()
	else:
		already_held = true
		var temp = Piece.new(current_piece.piece_type)
		current_piece = Piece.new(hold_piece.piece_type)
		hold_piece = Piece.new(temp.piece_type)
		spawn_new_piece(current_piece)
	return true

func spawn_new_piece_from_bag():
	piece_queue.push_back(get_piece_from_bag())
	return spawn_new_piece(piece_queue.pop_front())

func spawn_new_piece(piece: Piece) -> bool:
	current_piece = piece

	current_piece_coordinates.clear()
	current_piece_top_left_corner = Vector2(3, 1)

	# A new piece gets its own lock delay and resets, not what is left of the last piece's
	drop_lock_time_begin = -1
	drop_lock_reset_count = 0
	lowest_row = int(current_piece_top_left_corner.y)
	last_spin = Spin.NONE

	# Check if player is dead
	for i in range(0, current_piece.tiles[0].size()):
		for j in range(0, current_piece.tiles.size()):
			if current_piece.tiles[j][i].state != Tile.State.EMPTY:
				if board[i + 3][j + 1].state != Tile.State.EMPTY:
					top_out()
					return false

	# Merge the piece into the array
	for i in range(current_piece.tiles[0].size()):
		for j in range(current_piece.tiles.size()):
			if current_piece.tiles[j][i].state != Tile.State.EMPTY:
				board[i + 3][j + 1].state = current_piece.tiles[j][i].state
				board[i + 3][j + 1].type = current_piece.tiles[j][i].type
				current_piece_coordinates.push_back(Vector2(i + 3, j + 1))

	ghost_coordinates = calculate_drop_position()
	show_ghost(ghost_coordinates)
	return true

func calculate_drop_position():
	# Only include the lowest (highest) Y coordinate of each column
	var filtered_coordinates: Array[Vector2] = []
	var new_coordinates: Array[Vector2] = []

	for point in current_piece_coordinates:
		var add = true
		for index in range(filtered_coordinates.size()):
			if point.x == filtered_coordinates[index].x:
				add = false
				if point.y > filtered_coordinates[index].y:
					filtered_coordinates[index].y = point.y
		if add:
			filtered_coordinates.push_back(Vector2(point.x, point.y))


	var amount_to_fall = 24
	for point in filtered_coordinates:
		# Check how far the piece can fall
		for i in range(point.y, 24):
			if board[point.x][i].state == Tile.State.PLACED:
				amount_to_fall = min(amount_to_fall, i - point.y - 1)
				break
			elif i == 23:
				amount_to_fall = min(amount_to_fall, i - point.y)

	for point in current_piece_coordinates:
		if point.y + (0 if amount_to_fall == 24 else amount_to_fall) > 23:
			return current_piece_coordinates
		new_coordinates.push_back(Vector2(point.x, point.y + (0 if amount_to_fall == 24 else amount_to_fall)))

	return new_coordinates

func show_ghost(ghost_coords: Array[Vector2]):
	if ghost_coords == null:
		return
	
	for point in ghost_coords:
		if point.y < 4 || board[point.x][point.y].state != Tile.State.EMPTY:
			continue
		if board[point.x][point.y].state != Tile.State.EMPTY:
			continue
		board[point.x][point.y].type = Tile.TileType.GHOST

func _init():
	# Initialize the board and other variables
	# Game is 10 x 24
	for i in range(10):
		board.append([])
		for j in range(24):
			board[i].push_back(Tile.new(Tile.TileType.EMPTY, Tile.State.EMPTY))

	piece_queue = []
	current_piece_coordinates = []
	ghost_coordinates = []
	highest_piece_row = 24

	# Initialize the bags
	bag_1 = []
	bag_2 = []

	# Add a pieces to bag 1 and shuffle
	var random_values: Array[int] = []
	for i in range(0, 7):
		random_values.push_back(i)
	random_values.shuffle()

	for value in random_values:
		bag_1.push_back(Piece.Pieces.values()[value])

	random_values.clear()
	# Add a pieces to bag 2 and shuffle
	for i in range(0, 7):
		random_values.push_back(i)
	random_values.shuffle()

	for value in random_values:
		bag_2.push_back(Piece.Pieces.values()[value])


	# Fill the queue with 5 pieces
	for i in range(5):
		piece_queue.push_back(get_piece_from_bag())

	spawn_new_piece_from_bag()
	game_started = true

func place_piece() -> Dictionary:
	already_held = false
	pieces_placed += 1

	var spin = last_spin
	var piece_type = current_piece.piece_type
	var combo_before = combo

	for point in current_piece_coordinates:
		board[point.x][point.y].state = Tile.State.PLACED
		board[point.x][point.y].connections = joins_within(point, current_piece_coordinates)
		highest_piece_row = min(highest_piece_row, point.y)

	# Try clearing lines
	var rows: Array[int] = clear_lines()

	if rows.size() > 0:
		combo += 1
	else:
		combo = 0

	# Move the rows down
	number_of_lines_cleared += rows.size()
	
	# A piece cut by a cleared row stays cut: its parts above and below must not join again when
	# the rows move down
	for row in rows:
		for x in range(10):
			if row > 0:
				board[x][row - 1].connections &= ~Tile.DOWN
			if row < 23:
				board[x][row + 1].connections &= ~Tile.UP

	var max_value = -1
	if (!rows.is_empty()):
		for row in rows:
			max_value = max(max_value, row)

	if max_value != -1:
		move_rows_down(max_value, highest_piece_row, rows)

	var is_perfect_clear = rows.size() > 0
	for i in range(10):
		for j in range(highest_piece_row, 24):
			if board[i][j].state == Tile.State.PLACED:
				is_perfect_clear = false
				break

	# Back-to-back, as in TETR.IO season 1: a T-spin (mini or full) or a quad keeps it going, any
	# other clear breaks it, and a placement with no clear leaves it alone. An all clear does not
	# change it.
	var b2b_broken = false
	if rows.size() > 0:
		if spin != Spin.NONE or rows.size() >= 4:
			b2b += 1
		else:
			b2b_broken = b2b >= 1
			b2b = -1

	var attack = 0
	if rows.size() > 0:
		# TETR.IO counts the combo from 0 at the first clear of a run; this game counts from 1
		attack = tetrio_attack(rows.size(), spin, max(b2b, 0), combo - 1)
		if is_perfect_clear:
			attack += ALL_CLEAR_ATTACK
	total_attack += attack
	# Read before the spawn below, which restarts the game on a top out
	var b2b_now = b2b

	# Survival: a clear's attack blocks incoming garbage (what is left over goes nowhere); a
	# placement with no clear tanks the ready garbage, which rises into the board
	var blocked = 0
	var tanked = 0
	var player_alive = true
	if garbage != null:
		if rows.size() > 0:
			blocked = garbage.cancel(attack)
		else:
			for part in garbage.take(MainGame.time_elapsed):
				tanked += part[0]
				if not raise_garbage(part[0], part[1]):
					player_alive = false
					break

	if player_alive:
		player_alive = spawn_new_piece_from_bag()
	else:
		top_out()
	if !player_alive:
		is_perfect_clear = false

	return {
		"lines_cleared": rows,
		"is_perfect_clear": is_perfect_clear,
		"spin": spin,
		"piece": piece_type,
		"tspin": spin != Spin.NONE and piece_type == Piece.Pieces.T_PIECE and rows.size() > 0,
		"attack": attack,
		"b2b": b2b_now,
		"b2b_broken": b2b_broken,
		"combo_broken": rows.is_empty() and combo_before >= 2,
		"topped_out": !player_alive,
		"blocked": blocked,
		"tanked": tanked,
	}

# options: the survival settings (Survival.configure)
func enable_survival(options: Dictionary):
	garbage = Garbage.new()
	attacker = Survival.new()
	attacker.configure(options)

# Versus: a garbage queue with no opponent of its own; the other player's attacks fill it
func enable_garbage():
	garbage = Garbage.new()

# Called every frame with the game clock: the opponent's attacks arrive in the garbage queue.
# Returns the sizes of the attacks that arrived, for the sounds.
func update_garbage(now: float) -> Array:
	if attacker == null:
		return []
	return attacker.update(now, garbage)

# The stack reached the spawn, or garbage pushed it out of the board: start again
func top_out():
	last_run_time = MainGame.time_elapsed
	topped_out = true
	if not auto_restart:
		game_ended = true
		return
	restart()
	MainGame.time_elapsed = 0

# Pushes the stack up by lines and fills the rows under it with garbage, with a hole at column.
# The garbage of one attack is drawn as one slab. False if that pushed blocks out of the top of the
# board: a top out. The garbage rises all the same (the blocks pushed out are lost), so the last
# board shows the garbage that topped the player out, as TETR.IO shows it.
func raise_garbage(lines: int, column: int) -> bool:
	var pushed_out = false
	for y in range(lines):
		for x in range(10):
			if board[x][y].state == Tile.State.PLACED:
				pushed_out = true
	for y in range(24 - lines):
		for x in range(10):
			var below = board[x][y + lines]
			board[x][y].state = below.state
			board[x][y].type = below.type
			board[x][y].connections = below.connections
	for y in range(24 - lines, 24):
		for x in range(10):
			var tile = board[x][y]
			if x == column:
				tile.state = Tile.State.EMPTY
				tile.type = Tile.TileType.EMPTY
				tile.connections = 0
				continue
			tile.state = Tile.State.PLACED
			tile.type = Tile.TileType.GARBAGE
			tile.connections = 0
			if y > 24 - lines:
				tile.connections |= Tile.UP
			if y < 23:
				tile.connections |= Tile.DOWN
			if x > 0 and x - 1 != column:
				tile.connections |= Tile.LEFT
			if x < 9 and x + 1 != column:
				tile.connections |= Tile.RIGHT
	highest_piece_row = max(0, highest_piece_row - lines)
	return not pushed_out

# Danger, as TETR.IO warns of it. It looks at the board as it will be after the next placement:
# the falling piece locked where its ghost is, its full rows cleared or, if it clears none, the
# incoming garbage (as much as can rise at one placement) risen under it. Returns
#   "cells": where the next piece will appear, if it would not fit there (the X's), else nothing
#   "high":  the stack reaches the top DANGER_ROWS rows of the board, or the next piece would not fit
const DANGER_ROWS = 4
func danger() -> Dictionary:
	var cells: Array[Vector2] = []
	if piece_queue.is_empty():
		return {"cells": cells, "high": false}
	# Rows from the top, each a list of 10 filled flags
	var rows = []
	for y in range(24):
		var row = []
		for x in range(10):
			row.append(board[x][y].state == Tile.State.PLACED)
		rows.append(row)
	for p in ghost_coordinates:
		rows[int(p.y)][int(p.x)] = true
	rows = rows.filter(func(row): return row.has(false))
	var cleared = 24 - rows.size()
	for i in range(cleared):
		var empty = []
		empty.resize(10)
		empty.fill(false)
		rows.push_front(empty)
	var rise = 0
	if garbage != null and cleared == 0:
		rise = min(garbage.total(), Garbage.GARBAGE_CAP)

	var blocked = false
	for y in range(rise):  # blocks the garbage would push out of the top
		if rows[y].has(true):
			blocked = true
	var next = piece_queue[0]
	for j in range(next.tiles.size()):
		for i in range(next.tiles[j].size()):
			if next.tiles[j][i].state != Tile.State.EMPTY:
				cells.push_back(Vector2(i + 3, j + 1))
	for cell in cells:
		var y = int(cell.y) + rise  # the row that will be pushed up to the cell
		if y > 23 or rows[y][int(cell.x)]:
			blocked = true
	var top = 24 - rise  # the top of the stack after the rise
	for y in range(24):
		if rows[y].has(true):
			top = y - rise
			break
	if not blocked:
		cells.clear()
	return {"cells": cells, "high": blocked or top < 4 + DANGER_ROWS}

# Lines sent by one clear, by TETR.IO's season 1 rules (combo table "multiplier", B2B chaining): the
# clear's base, plus a back-to-back bonus that grows slowly with the chain (1 at x1, 1.65 at x2, 2.41
# at x3, ...), then times 1 + 0.25 per combo step, and from the second step on never less than
# ln(1 + 1.25 x combo). Rounded down at the end. combo counts from 0.
static func tetrio_attack(lines: int, spin: int, back_to_back: int, combo_count: int) -> int:
	var garbage = float(ATTACK[spin][min(lines, 4)])
	if lines > 0 and back_to_back > 0:
		var chain = log(1 + back_to_back * 0.8)
		garbage += floor(1 + chain) + (0.0 if back_to_back == 1 else (1 + fmod(chain, 1.0)) / 3)
	if combo_count > 0:
		garbage *= 1 + 0.25 * combo_count
		if combo_count > 1:
			garbage = max(log(1 + 1.25 * combo_count), garbage)
	return int(floor(garbage))

# Which sides of a cell touch another of the given cells (a piece's own), as Tile.UP | DOWN | ...
static func joins_within(point: Vector2, cells: Array[Vector2]) -> int:
	var joins = 0
	if cells.has(point + Vector2(0, -1)):
		joins |= Tile.UP
	if cells.has(point + Vector2(0, 1)):
		joins |= Tile.DOWN
	if cells.has(point + Vector2(-1, 0)):
		joins |= Tile.LEFT
	if cells.has(point + Vector2(1, 0)):
		joins |= Tile.RIGHT
	return joins

# The spin a rotation made, by TETR.IO's season 1 rules ("T-spins": only the T spins). A T with three
# of the four corners round its centre filled (walls and floor count) is a T-spin: a full one when
# both corners on the side it points to are filled or it got there by the fin/TST kick, a mini
# otherwise.
func detect_spin(from_rotation: int, to_rotation: int, kick: Vector2) -> int:
	var spin = Spin.NONE
	if current_piece.piece_type == Piece.Pieces.T_PIECE:
		var centre = current_piece_top_left_corner + Vector2(1, 1)
		# top left, top right, bottom right, bottom left; corner k faces the rotations k and k + 3
		var corners = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
		var filled = 0
		var front = 0
		for k in 4:
			var p = centre + corners[k]
			if p.x < 0 or p.x >= 10 or p.y >= 24 or (p.y >= 0 and board[p.x][p.y].state == Tile.State.PLACED):
				filled += 1
				if to_rotation == k or to_rotation == (k + 3) % 4:
					front += 1
		if filled >= 3:
			spin = Spin.FULL if front == 2 else Spin.MINI
			# The last kicks of 0 or 2 to the side states: TETR.IO's fin and TST kicks
			var far_kick = (to_rotation == 1 and kick == Vector2(-1, 2)) or (to_rotation == 3 and kick == Vector2(1, 2))
			if far_kick and (from_rotation == 0 or from_rotation == 2):
				spin = Spin.FULL
	return spin

func clear_lines():
	# Store all rows that might be full
	var rows_to_check: Array[int] = []
	for point in current_piece_coordinates:
		if !rows_to_check.has(int(point.y)):
			rows_to_check.push_back(int(point.y))

	var removed_rows: Array[int] = []

	# Check if the rows are full
	for row in rows_to_check:
		var full = true
		for i in range(10):
			if board[i][row].state != Tile.State.PLACED:
				full = false
				break

		if full:
			removed_rows.push_back(row)
			for i in range(10):
				board[i][row].state = Tile.State.EMPTY
				board[i][row].type = Tile.TileType.EMPTY
				board[i][row].connections = 0

	return removed_rows

func move_rows_down(bottom: int, top: int, removed_rows: Array[int]):
	var number_times_to_move_down = 0
	for i in range(bottom, top - 1, -1):
		if removed_rows.has(i):
			number_times_to_move_down += 1
			continue
		else:
			for j in range(10):
				board[j][i + number_times_to_move_down].state = board[j][i].state
				board[j][i + number_times_to_move_down].type = board[j][i].type
				board[j][i + number_times_to_move_down].connections = board[j][i].connections
				board[j][i].state = Tile.State.EMPTY
				board[j][i].type = Tile.TileType.EMPTY
				board[j][i].connections = 0

	highest_piece_row += number_times_to_move_down

func hard_drop():
	# Falling any distance means the last thing the piece did was not a rotation
	if ghost_coordinates != current_piece_coordinates:
		last_spin = Spin.NONE

	for point in current_piece_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	current_piece_coordinates = ghost_coordinates
	for point in current_piece_coordinates:
		board[point.x][point.y].type = current_piece.tile_type
		board[point.x][point.y].state = Tile.State.FALLING

	return place_piece()

func try_to_move_piece(direction: MoveDirections):
	# X+ is right, Y+ is down
	var translation: Vector2

	var new_coordinates: Array[Vector2] = []
	if (direction == MoveDirections.LEFT):
		translation = Vector2(-1, 0)
	elif (direction == MoveDirections.RIGHT):
		translation = Vector2(1, 0)
	elif (direction == MoveDirections.DOWN):
		translation = Vector2(0, 1)

	# Check if the new position of each point is inside the board or if it is obstructed
	for point in current_piece_coordinates:
		if point.y + translation.y >= 24 or point.y + translation.y < 0 or point.x + translation.x >= 10 or point.x + translation.x < 0:
			new_coordinates.clear()
			return new_coordinates
		if (board[point.x + translation.x][point.y + translation.y].state == Tile.State.PLACED):
			new_coordinates.clear()
			return new_coordinates
		new_coordinates.push_back(Vector2(point.x + translation.x, point.y + translation.y))

	return new_coordinates

func move_piece(move_direction: MoveDirections) -> bool:
	var new_coordinates: Array[Vector2] = try_to_move_piece(move_direction)
	if new_coordinates.is_empty():
		return false
	last_spin = Spin.NONE

	for point in current_piece_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	current_piece_coordinates = new_coordinates
	if move_direction == MoveDirections.DOWN:
		current_piece_top_left_corner.y += 1
	elif move_direction == MoveDirections.LEFT:
		current_piece_top_left_corner.x -= 1
	elif move_direction == MoveDirections.RIGHT:
		current_piece_top_left_corner.x += 1

	# Remove the ghost
	for point in ghost_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	# Update the ghost
	ghost_coordinates = calculate_drop_position()
	show_ghost(ghost_coordinates)

	for point in current_piece_coordinates:
		board[point.x][point.y].type = current_piece.tile_type
		board[point.x][point.y].state = Tile.State.FALLING

	if move_direction == MoveDirections.DOWN:
		if current_piece_top_left_corner.y > lowest_row:
			lowest_row = int(current_piece_top_left_corner.y)
			drop_lock_reset_count = 0
	else:
		use_lock_reset()
	return true

# A move or rotation resets the lock delay while resets are left
func use_lock_reset():
	drop_lock_reset_count = min(drop_lock_reset_count + 1, 31)
	if drop_lock_reset_count < LOCK_RESETS:
		drop_lock_time_begin = -1

# 1 for clockwise, 2 for 180, 3 for counterclockwise
func calculate_rotation(rotations: Piece.RotationAmount):
	if rotations == 0 or current_piece.piece_type == Piece.Pieces.O_PIECE:
		return null
	
	var rotated_piece = Piece.new(current_piece.piece_type)
	rotated_piece.rotation = current_piece.rotation
	rotated_piece.rotate(rotations)

	# Calculate the rotation
	# (current rotation, rotated rotation)
	var rotation = Vector2(current_piece.rotation, rotated_piece.rotation)
	var kicks: Array

	if current_piece.piece_type == Piece.Pieces.I_PIECE:
		if not KickTables.IWallKickData.has(rotation):
			return null
		kicks = KickTables.IWallKickData[Vector2(int(rotation.x), int(rotation.y))]
	else:
		if not KickTables.NonIWallKickData.has(rotation):
			return null
		kicks = KickTables.NonIWallKickData[Vector2(int(rotation.x), int(rotation.y))]

	# Try each kick
	for kick in kicks:
		var can_rotate = true
		for i in range(rotated_piece.tiles.size()):
			for j in range(rotated_piece.tiles[i].size()):
				if rotated_piece.tiles[i][j].state == Tile.State.FALLING:
					var break_outer = false
					
					# If out of bounds
					if (j + current_piece_top_left_corner.x + kick.x < 0 or j + current_piece_top_left_corner.x + kick.x >= 10 or i + current_piece_top_left_corner.y + kick.y < 0 or i + current_piece_top_left_corner.y + kick.y >= 24):
						can_rotate = false
						break_outer = true
						break

					if break_outer:
						break

					# If obstructed
					if board[j + current_piece_top_left_corner.x + kick.x][i + current_piece_top_left_corner.y + kick.y].state == Tile.State.PLACED:
						can_rotate = false
						break_outer = true
						break

					if break_outer:
						break

		if can_rotate:
			return kick
	
	return null

func rotate_piece(rotations: Piece.RotationAmount) -> bool:
	if rotations == 0 || current_piece.piece_type == Piece.Pieces.O_PIECE:
		return false

	var kick = calculate_rotation(rotations)
	
	# Null means no valid rotation
	if kick == null:
		return false

	var from_rotation = current_piece.rotation
	current_piece.rotate(rotations)

	# Remove the current piece from the boast
	for point in current_piece_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	current_piece_coordinates.clear()
	# Add the rotated piece to the board
	for i in range(current_piece.tiles.size()):
		for j in range(current_piece.tiles[i].size()):
			if current_piece.tiles[i][j].state == Tile.State.FALLING:
				current_piece_coordinates.push_back(Vector2(j + current_piece_top_left_corner.x + kick.x, i + current_piece_top_left_corner.y + kick.y))
				board[j + current_piece_top_left_corner.x + kick.x][i + current_piece_top_left_corner.y + kick.y].state = Tile.State.FALLING
				board[j + current_piece_top_left_corner.x + kick.x][i + current_piece_top_left_corner.y + kick.y].type = current_piece.piece_type

	# Update the top left corner
	current_piece_top_left_corner.x += kick.x
	current_piece_top_left_corner.y += kick.y

	# Remove the ghost
	for point in ghost_coordinates:
		board[point.x][point.y].state = Tile.State.EMPTY
		board[point.x][point.y].type = Tile.TileType.EMPTY

	# Update the ghost
	ghost_coordinates = calculate_drop_position()
	show_ghost(ghost_coordinates)

	for point in current_piece_coordinates:
		board[point.x][point.y].type = current_piece.tile_type
		board[point.x][point.y].state = Tile.State.FALLING

	last_spin = detect_spin(from_rotation, current_piece.rotation, kick)
	use_lock_reset()
	return true
