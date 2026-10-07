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

# Back-to-back: quads and T-spin clears in a row, with no other clear between. -1 is none, 0 the
# first, 1 is "B2B x1" (as TETR.IO counts)
var b2b: int = -1

# A T-spin needs the last thing the piece did to be a rotation; a move or a fall cancels it
var last_move_rotation: bool = false

# Set when the stack reaches the spawn and the game restarts; MainGame plays the sound and clears it
var topped_out: bool = false

# If player is still alive
var alive = true

var board: Array[Array]

func restart():
	# Initialize the board and other variables
	# Game is 10 x 24
	for i in range(10):
		for j in range(24):
			board[i][j].state = Tile.State.EMPTY
			board[i][j].type = Tile.TileType.EMPTY

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
	MainGame.last_gravity_time = -1

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
	last_move_rotation = false

	# Check if player is dead
	for i in range(0, current_piece.tiles[0].size()):
		for j in range(0, current_piece.tiles.size()):
			if current_piece.tiles[j][i].state != Tile.State.EMPTY:
				if board[i + 3][j + 1].state != Tile.State.EMPTY:
					restart()
					MainGame.time_elapsed = 0
					topped_out = true
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

	# Checked before the piece becomes part of the stack (its own cells are never the corners)
	var tspin = last_move_rotation and is_t_spin_position()
	var combo_before = combo

	for point in current_piece_coordinates:
		board[point.x][point.y].state = Tile.State.PLACED
		highest_piece_row = min(highest_piece_row, point.y)

	# Try clearing lines
	var rows: Array[int] = clear_lines()

	if rows.size() > 0:
		combo += 1
	else:
		combo = 0

	var b2b_broken = false
	if rows.size() > 0:
		if tspin or rows.size() == 4:
			b2b += 1
		else:
			b2b_broken = b2b >= 1
			b2b = -1
	# Read before the spawn below, which restarts the game on a top out
	var b2b_now = b2b

	# Move the rows down
	number_of_lines_cleared += rows.size()
	
	var max_value = -1
	if (!rows.is_empty()):
		for row in rows:
			max_value = max(max_value, row)

	if max_value != -1:
		move_rows_down(max_value, highest_piece_row, rows)

	var player_alive = spawn_new_piece_from_bag()

	var is_perfect_clear = true
	for i in range(10):
		for j in range(highest_piece_row, 24):
			if board[i][j].state == Tile.State.PLACED:
				is_perfect_clear = false
				break

	if !player_alive:
		is_perfect_clear = false

	return {
		"lines_cleared": rows,
		"is_perfect_clear": is_perfect_clear,
		"tspin": tspin and rows.size() > 0,
		"b2b": b2b_now,
		"b2b_broken": b2b_broken,
		"combo_broken": rows.is_empty() and combo_before >= 2,
		"topped_out": !player_alive
	}

# Three of the four corners around a T's centre are filled (or are the walls or the floor)
func is_t_spin_position() -> bool:
	if current_piece.piece_type != Piece.Pieces.T_PIECE:
		return false
	var centre = current_piece_top_left_corner + Vector2(1, 1)
	var corners = 0
	for d in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var p = centre + d
		if p.x < 0 or p.x >= 10 or p.y >= 24 or (p.y >= 0 and board[p.x][p.y].state == Tile.State.PLACED):
			corners += 1
	return corners >= 3

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
				board[j][i].state = Tile.State.EMPTY
				board[j][i].type = Tile.TileType.EMPTY

	highest_piece_row += number_times_to_move_down

func hard_drop():
	# Falling any distance means the last thing the piece did was not a rotation
	if ghost_coordinates != current_piece_coordinates:
		last_move_rotation = false

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
	last_move_rotation = false

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

	last_move_rotation = true
	use_lock_reset()
	return true
