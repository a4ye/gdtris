extends RefCounted
# The versus bot. It plays by GDTris's own rules: the piece shapes and SRS+ kicks (180s too) of
# Piece and KickTables, the T-spin rules of Game.detect_spin and TETR.IO's season 1 attack of
# Game.tetrio_attack. It does not run the game to think; it works on a copy of the board as bit
# rows, which is many times faster in GDScript.
#
# How it chooses a placement:
# - Move generation: every place the piece can reach from the spawn with left, right, the three
#   rotations and "drop to the floor", so tucks and spins under overhangs are found too. Each
#   place keeps the moves that reach it; the game replays them, so the game's own rules decide
#   the result.
# - Evaluation: the board terms and the weights of Cold Clear's default evaluator (MinusKelvin's
#   bot for guideline rules, the usual reference for these heuristics): height, bumpiness, holes
#   (cavities and overhangs, and the cells over them), row transitions, the well, T-spin slots,
#   back-to-back, and rewards for each kind of clear. Added for versus: incoming garbage counts as
#   height, and a placement that would top out is ruled out.
# - Search: a beam search down the next pieces it can see, with hold. It thinks a little each
#   frame (step), and its best answer so far is always ready, so a fast bot still moves on time.
#
# Strength levels (1-10) set how far it looks, how many lines of play it keeps, and how much
# random error it makes.

const Garbage = preload("res://src/base/garbage.gd")
const FULL = 1023
enum Action { LEFT, RIGHT, CW, CCW, FLIP, DROP }
const T = Piece.Pieces.T_PIECE
const O = Piece.Pieces.O_PIECE

# Cold Clear's default weights (cold-clear, evaluation/standard.rs)
const W = {
	"back_to_back": 52, "bumpiness": -24, "bumpiness_sq": -7, "row_transitions": -5, "height": -39,
	"top_half": -150, "top_quarter": -511, "cavity_cells": -173, "cavity_cells_sq": -3,
	"overhang_cells": -34, "overhang_cells_sq": -1, "covered_cells": -17, "covered_cells_sq": -1,
	"well_depth": 57, "max_well_depth": 17, "wasted_t": -152, "b2b_clear": 104,
	"perfect_clear": 999, "combo_garbage": 150,
}
const TSLOT = [8, 148, 192, 407]
# A T-spin the next T could really make on the board (found with the T's own move generation, so
# any slot shape counts: doubles, triples, slots under a roof), by lines cleared. Larger than
# Cold Clear's slot weights, as this search is far shallower than Cold Clear's and needs the
# stronger pull to build the slots.
var slot_weights = [0, 150, 380, 560]

# How it likes to attack (style). With Cold Clear's own weights ("cold clear") about half of what
# it sends are attacks of 1 or 2 lines (doubles, triples, the end of a combo), each with its own
# hole: messy "cheese" for the opponent. "clean", the default, costs 300 for each attack that, after
# cancelling, sends only 1 or 2 lines; attacks that only cancel cost nothing, so it still digs and
# defends. Measured at level 10 against steady garbage, 4 runs of 3 minutes each: attacks of 1-2
# lines fell from 53 % to 29 %, the mean attack grew from 2.8 to 3.65 lines, and the lines sent a
# minute went up (60 to 67).
const STYLES = {
	"cold clear": {"clear": [0, -143, -100, -58, 390], "combo": 150, "b2b": 52, "b2b_clear": 104, "small_send": 0},
	"clean": {"clear": [0, -143, -100, -58, 300], "combo": 150, "b2b": 120, "b2b_clear": 180, "small_send": -300},
}
var clear_weights = CLEAR
var combo_weight = 150
# T-spins over quads: T-spin rewards up, the quad's and a wasted T's down, back-to-back worth more.
# Measured at level 9, 3 runs of 400 pieces: attack a piece 0.70 -> 0.76, T-spins as often, no more
# holes. (Cold Clear's own: back-to-back 52, its clear 104, a wasted T -152.)
var b2b_weight = 120
var b2b_clear_weight = 180
var small_send_weight = -300
var tspin_weights = TSPIN
var attack_weight = 0.0
var cavity_weight = -173.0  # each cavity cell (Cold Clear's weight)
var overhang_weight = -34.0
var covered_weight = -17.0  # for each line of attack, on top of the rewards by kind of clear
var wasted_t_weight = -250
const WELL_COLUMN = [20, 23, 20, 50, 59, 21, 59, 10, -10, 24]
const CLEAR = [0, -143, -100, -58, 300]  # Cold Clear's quad: 390
const TSPIN = [0, 200, 650, 900]  # Cold Clear: 121, 410, 602
const MINI = [0, -158, -93]
const GARBAGE_LINE = -40  # each line of garbage it lets rise (versus)
const DEAD = -1000000.0

# level: [lookahead in placements, beam width, random error, sees T-spin slots]
const LEVELS = {
	1: [1, 1, 140.0, false], 2: [1, 1, 100.0, false], 3: [1, 1, 70.0, true], 4: [1, 1, 40.0, true],
	5: [2, 3, 20.0, true], 6: [2, 6, 8.0, true], 7: [3, 6, 0.0, true], 8: [3, 10, 0.0, true],
	9: [4, 10, 0.0, true], 10: [4, 16, 0.0, true],
}

# shapes[type][rotation] = [dys, masks, min_x, max_x, cells]: the piece's rows (offset from the top
# of its box, and the cells in that row as bits from the box's left), the leftmost and rightmost
# cell column in the box, and its cells as Vector2i
var shapes = []
var kicks = []  # kicks[type][from][to] = Array of Vector2i, or [] when there is no such turn
var popcount = PackedByteArray()
var low_bit = {}  # 1 << n -> n, for the lowest set bit of a column

var depth_limit := 3
var beam := 8
var max_beam := 8  # the level's beam; BotPlayer narrows beam when the time between pieces is short
var beam_decay := 1.0  # each layer deeper keeps this much of the beam of the one before
var noise := 0.0
var sees_tslots := true
var rng := RandomNumberGenerator.new()


class SearchNode:
	var rows: PackedInt32Array
	var hold: int
	var next: int  # index of the current piece in the search's piece list
	var b2b: int
	var combo: int
	var incoming: int
	var score: float  # rewards collected on the way
	var value: float  # score plus the evaluation of the board
	var tslot: float  # the T-spin slot part of the value
	var cavities: int  # cavity cells on its board
	var first: Array  # the root's placement: [held, piece, cells, actions]


# Search state, kept between step() calls
var pieces: Array = []
var layer: Array = []
var children: Array = []
var layer_index := 0
var work: Array = []  # the piece options of the node being expanded, done one per call
var refine_index := -1  # the next of the layer's best boards to check for real T-spins, or -1
var refine_count := 0
var _tslot_bonus := 0.0  # the slot part of the last evaluate()
var _cavities := 0  # the cavity cells the last evaluate() found
# Holes and back-to-back. Measured at level 10 against steady garbage (6 runs of 300 pieces): with
# these, placements that leave a new hole fell from 10 % to 6 % (most of what is left are the
# overhangs that T-spin slots need), back-to-back broke 5.3 times a run instead of 9.7, and attack
# a piece rose from 0.70 to 0.79.
var b2b_chain_weight := 200.0  # on top of b2b_weight: for each step of ln(1 + 0.8 x chain), as S1 pays it
var b2b_break_weight := -600.0  # a clear that ends a chain of x1 or more
var hole_create_weight := -400.0  # each cavity cell a placement adds
var trace := false  # tests: evaluate() keeps its terms in terms
var terms := {}
var depth := 0
var best: SearchNode = null
var done := true
var stop := false  # set by the player's thread to end a search that runs on a worker (think)


func _init(level: int = 7):
	rng.randomize()
	set_level(level)
	popcount.resize(2048)
	for i in 2048:
		var n = 0
		var v = i
		while v:
			n += v & 1
			v >>= 1
		popcount[i] = n
	for i in 26:
		low_bit[1 << i] = i
	for type in 7:
		var per_rotation = []
		var piece = Piece.new(type)
		for rot in Piece.PIECE_ARRAYS[type].size():
			var grid = Piece.PIECE_ARRAYS[type][rot]
			var dys = PackedInt32Array()
			var masks = PackedInt32Array()
			var cells = []
			var min_x = 9
			var max_x = 0
			for j in grid.size():
				var mask = 0
				for i in grid[j].size():
					if grid[j][i] == 1:
						mask |= 1 << i
						cells.append(Vector2i(i, j))
						min_x = min(min_x, i)
						max_x = max(max_x, i)
				if mask:
					dys.append(j)
					masks.append(mask)
			per_rotation.append([dys, masks, min_x, max_x, cells])
		shapes.append(per_rotation)
		var table = KickTables.IWallKickData if type == Piece.Pieces.I_PIECE else KickTables.NonIWallKickData
		var turns = []
		for from in 4:
			var row = []
			for to in 4:
				var list = []
				if table.has(Vector2(from, to)):
					for k in table[Vector2(from, to)]:
						list.append(Vector2i(int(k.x), int(k.y)))
				row.append(list)
			turns.append(row)
		kicks.append(turns)


func set_style(name: String):
	var style = STYLES[name]
	clear_weights = style["clear"]
	combo_weight = style["combo"]
	b2b_weight = style["b2b"]
	b2b_clear_weight = style["b2b_clear"]
	small_send_weight = style["small_send"]


func set_level(level: int):
	# The clean style is for the levels that look far enough ahead to keep it up: none for 1-4,
	# half for 5-6
	small_send_weight = 0 if level <= 4 else (-150 if level <= 6 else -300)
	# Levels 1-4 look one piece ahead and cannot afford to protect back-to-back: they clear what
	# they can, as a beginner does, and only shy away from holes a little
	if level <= 4:
		b2b_chain_weight = 0.0
		b2b_break_weight = 0.0
		hole_create_weight = -150.0
	else:
		b2b_chain_weight = 200.0
		b2b_break_weight = -600.0
		hole_create_weight = -400.0
	var l = LEVELS[clampi(level, 1, 10)]
	depth_limit = l[0]
	beam = l[1]
	max_beam = l[1]
	noise = l[2]
	sees_tslots = l[3]


# ---- The board -------------------------------------------------------------------------------

static func rows_of(game) -> PackedInt32Array:
	var rows = PackedInt32Array()
	rows.resize(24)
	for y in 24:
		var row = 0
		for x in 10:
			if game.board[x][y].state == Tile.State.PLACED:
				row |= 1 << x
		rows[y] = row
	return rows


func fits(rows: PackedInt32Array, type: int, rot: int, x: int, y: int) -> bool:
	var s = shapes[type][rot]
	if x + s[2] < 0 or x + s[3] > 9:
		return false
	var dys: PackedInt32Array = s[0]
	var masks: PackedInt32Array = s[1]
	for i in dys.size():
		var ry = y + dys[i]
		if ry < 0 or ry > 23:
			return false
		var m = (masks[i] << x) if x >= 0 else (masks[i] >> -x)
		if rows[ry] & m:
			return false
	return true


func filled(rows: PackedInt32Array, x: int, y: int) -> bool:
	if x < 0 or x > 9 or y > 23:
		return true
	if y < 0:
		return false
	return (rows[y] >> x) & 1 == 1


# The spin a rotation made, as Game.detect_spin decides it (T-spins only)
func spin_of(rows: PackedInt32Array, type: int, from: int, to: int, x: int, y: int, kick: Vector2i) -> int:
	if type != T:
		return Game.Spin.NONE
	var corners = [Vector2i(x, y), Vector2i(x + 2, y), Vector2i(x + 2, y + 2), Vector2i(x, y + 2)]
	var count = 0
	var front = 0
	for k in 4:
		if filled(rows, corners[k].x, corners[k].y):
			count += 1
			if to == k or to == (k + 3) % 4:
				front += 1
	if count < 3:
		return Game.Spin.NONE
	var spin = Game.Spin.FULL if front == 2 else Game.Spin.MINI
	if (from == 0 or from == 2) and ((to == 1 and kick == Vector2i(-1, 2)) or (to == 3 and kick == Vector2i(1, 2))):
		spin = Game.Spin.FULL
	return spin


func rotate_by(type: int, rot: int, action: int) -> int:
	var states = Piece.NUMBER_OF_ROTATION_STATES[type]
	var amount = 1 if action == Action.CW else (3 if action == Action.CCW else 2)
	return (rot + amount) % states


# ---- Move generation -------------------------------------------------------------------------

const ACTIONS = [Action.LEFT, Action.RIGHT, Action.DROP, Action.CW, Action.CCW, Action.FLIP]

# Every placement of the piece: [cells (sorted board indices), spin, actions, rot, x, y]. A breadth
# first search over positions; each position keeps the one before it and the move that led there,
# and the moves are put together only for the placements. In the air the piece only moves and
# turns near the spawn (SPAWN_ZONE); lower down it drops to the floor first, and moves and turns
# from there: that finds the same places, tucks and spins, with far fewer positions to try.
const SPAWN_ZONE = 3
func placements(rows: PackedInt32Array, type: int) -> Array:
	var result = []
	if not fits(rows, type, 0, 3, 1):
		return result
	# Each column as bits (bit y set where row y is filled), for drops in one step
	var cols = PackedInt32Array()
	cols.resize(10)
	for y in 24:
		var row = rows[y]
		if row:
			for x in 10:
				if row & (1 << x):
					cols[x] |= 1 << y
	var is_t = type == T
	var visited = PackedByteArray()
	visited.resize(4 * 28 * 32 * 3)
	var seen_cells = {}
	var q_rot = PackedInt32Array([0])
	var q_x = PackedInt32Array([3])
	var q_y = PackedInt32Array([1])
	var q_spin = PackedInt32Array([0])
	var q_parent = PackedInt32Array([-1])
	var q_action = PackedInt32Array([-1])
	visited[_key(0, 3, 1, 0)] = 1
	var head = 0
	while head < q_rot.size():
		var rot: int = q_rot[head]
		var x: int = q_x[head]
		var y: int = q_y[head]
		var fall = _drop(cols, type, rot, x, y)
		# On the floor: a placement
		if fall == 0:
			var cells = _cells(type, rot, x, y)
			var key = cells[0] | (cells[1] << 8) | (cells[2] << 16) | (cells[3] << 24) | (q_spin[head] << 32)
			if not seen_cells.has(key):
				seen_cells[key] = true
				var path = []
				var at = head
				while q_parent[at] != -1:
					path.push_front(q_action[at])
					at = q_parent[at]
				result.append([cells, q_spin[head], path, rot, x, y])
		var free = fall == 0 or y <= SPAWN_ZONE  # moves and turns allowed here
		for action in ACTIONS:
			if not free and action != Action.DROP:
				continue
			var nr = rot
			var nx = x
			var ny = y
			var spin = 0
			if action == Action.LEFT:
				nx -= 1
				if not fits(rows, type, rot, nx, ny):
					continue
			elif action == Action.RIGHT:
				nx += 1
				if not fits(rows, type, rot, nx, ny):
					continue
			elif action == Action.DROP:
				if fall == 0:
					continue
				ny = y + fall
			else:
				if type == O:
					continue
				nr = rotate_by(type, rot, action)
				var list: Array = kicks[type][rot][nr]
				var moved = false
				for k in list:
					if fits(rows, type, nr, x + k.x, y + k.y):
						nx = x + k.x
						ny = y + k.y
						if is_t:
							spin = spin_of(rows, type, rot, nr, nx, ny, k)
						moved = true
						break
				if not moved:
					continue
			var key = _key(nr, nx, ny, spin)
			if visited[key]:
				continue
			visited[key] = 1
			q_rot.append(nr)
			q_x.append(nx)
			q_y.append(ny)
			q_spin.append(spin)
			q_parent.append(head)
			q_action.append(action)
		head += 1
	return result


# How far the piece falls before it lands: the least room under any of its cells
func _drop(cols: PackedInt32Array, type: int, rot: int, x: int, y: int) -> int:
	var fall = 99
	for c in shapes[type][rot][4]:
		var cy = y + c.y
		var below = cols[x + c.x] >> (cy + 1) if cy >= -1 else cols[x + c.x] << (-cy - 1)
		var room = 23 - cy if below == 0 else low_bit[below & -below]
		fall = min(fall, room)
	return fall


# rot 0-3, y -3 to 24, x -8 to 23, spin 0-2
func _key(rot: int, x: int, y: int, spin: int) -> int:
	return ((rot * 28 + (y + 3)) * 32 + (x + 8)) * 3 + spin


func _cells(type: int, rot: int, x: int, y: int) -> PackedInt32Array:
	var out = PackedInt32Array()
	for c in shapes[type][rot][4]:
		out.append((y + c.y) * 10 + (x + c.x))
	out.sort()
	return out


# ---- Placing and judging -----------------------------------------------------------------------

# The child node for one placement, or null if it tops out
func play(node: SearchNode, type: int, placement: Array, hold: int, next: int, held: bool) -> SearchNode:
	var rows = node.rows.duplicate()
	for idx in placement[0]:
		rows[idx / 10] |= 1 << (idx % 10)
	var out = PackedInt32Array()
	out.resize(24)
	var w = 23
	var lines = 0
	for y in range(23, -1, -1):
		if rows[y] == FULL:
			lines += 1
		else:
			out[w] = rows[y]
			w -= 1
	var spin: int = placement[1]
	var child = SearchNode.new()
	child.hold = hold
	child.next = next
	child.rows = out
	var score = node.score
	var b2b = node.b2b
	var combo = node.combo
	var incoming = node.incoming
	if lines > 0:
		combo += 1
		var difficult = spin != Game.Spin.NONE or lines >= 4
		var b2b_before = b2b
		b2b = b2b + 1 if difficult else -1
		var attack = Game.tetrio_attack(lines, spin, max(b2b, 0), combo - 1)
		var combo_extra = attack - Game.tetrio_attack(lines, spin, max(b2b, 0), 0)
		var pc = true
		for y in 24:
			if out[y] != 0:
				pc = false
				break
		if pc:
			attack += Game.ALL_CLEAR_ATTACK
			score += W["perfect_clear"]
		if spin == Game.Spin.FULL:
			score += tspin_weights[min(lines, 3)]
		elif spin == Game.Spin.MINI:
			score += MINI[min(lines, 2)]
		else:
			score += clear_weights[min(lines, 4)]  # (a piece clears 4 at most; a bad board cannot index past)
		if difficult and b2b_before >= 0:
			score += b2b_clear_weight
		if not difficult and b2b_before >= 1:
			score += b2b_break_weight
		score += combo_weight * combo_extra
		score += attack_weight * attack
		# An attack that, after cancelling, sends only 1 or 2 lines: a small chunk with its own hole,
		# cheese for the opponent (small_send_weight; 0 in Cold Clear's own style)
		# Only while the stack is low: full up to 6 rows high, none from 12, so a bot that is getting
		# high clears whatever it can
		var sent = attack - incoming
		if sent > 0 and sent <= 2 and small_send_weight != 0:
			var top = 24
			for y in 24:
				if out[y] != 0:
					top = y
					break
			score += small_send_weight * clamp((12.0 - (24 - top)) / 6.0, 0.0, 1.0)
		incoming = max(0, incoming - attack)
	else:
		combo = 0
	if type == T and not (spin != Game.Spin.NONE and lines > 0):
		score += wasted_t_weight
	# Garbage that rises after a placement with no clear: it raises the stack (as height in the
	# evaluation), and a stack it pushes into the spawn is a top out
	var rise = 0
	if lines == 0 and incoming > 0:
		rise = min(incoming, Garbage.GARBAGE_CAP)
		incoming -= rise
		score += GARBAGE_LINE * rise
	for y in range(rise):
		if out[y] != 0:
			return null
	if (out[min(23, 1 + rise)] | out[min(23, 2 + rise)]) & 120:  # the spawn, columns 3-6
		return null
	child.b2b = b2b
	child.combo = combo
	child.incoming = incoming
	child.score = score
	child.value = score + evaluate(out, b2b, rise)
	child.tslot = _tslot_bonus
	child.cavities = _cavities
	# A new cavity costs once more, as it is made, so the search does not count on clearing it later
	if hole_create_weight != 0.0 and _cavities > node.cavities and lines == 0:
		var made = (_cavities - node.cavities) * hole_create_weight
		child.score += made
		child.value += made
	child.first = node.first if not node.first.is_empty() else [held, type, placement[0], placement[2]]
	return child



# Cold Clear's board terms. rise: garbage lines that will push the stack up.
func evaluate(rows: PackedInt32Array, b2b: int, rise: int) -> float:
	var value = 0.0
	if b2b >= 0:
		value += b2b_weight + b2b_chain_weight * log(1.0 + 0.8 * b2b)
	var heights = PackedInt32Array()
	heights.resize(10)
	var top = 24
	var seen = 0
	for y in 24:
		var row = rows[y]
		if row == 0:
			continue
		if top == 24:
			top = y
		var fresh = row & ~seen
		if fresh:
			for x in 10:
				if fresh & (1 << x):
					heights[x] = 24 - y
			seen |= row
	var height = 24 - top + rise
	value += W["height"] * height
	value += W["top_half"] * max(height - 10, 0)
	value += W["top_quarter"] * max(height - 15, 0)

	# The well: the lowest column, and how many rows are full except for it
	var well = 0
	for x in range(1, 10):
		if heights[x] < heights[well]:
			well = x
	var depth_ = 0
	var open = FULL ^ (1 << well)
	var y = 23 - heights[well]
	while y >= 0 and rows[y] == open:
		depth_ += 1
		y -= 1
	depth_ = min(depth_, W["max_well_depth"])
	value += W["well_depth"] * depth_
	if depth_ > 0:
		value += WELL_COLUMN[well]

	# Bumpiness, stepping over the well
	var bump = 0
	var bump_sq = 0
	var prev = 1 if well == 0 else 0
	for x in range(1, 10):
		if x == well:
			continue
		var d = abs(heights[prev] - heights[x])
		bump += d
		bump_sq += d * d
		prev = x
	value += W["bumpiness"] * bump + W["bumpiness_sq"] * bump_sq

	# Row transitions, holes (a cavity, or an overhang if a piece can slide in from the side) and
	# the cells over each hole
	var transitions = 0
	var cavities = 0
	var overhangs = 0
	var covered = 0
	var covered_sq = 0
	var above = 0
	for yy in range(top, 24):
		var row = rows[yy]
		transitions += popcount[(((row << 1) | 1) ^ (row | 1024)) & 2047]
		var holes = above & ~row & FULL
		if holes:
			var level = 23 - yy
			for x in 10:
				if holes & (1 << x):
					# Cold Clear's test: an overhang has room beside it to slide a piece in (the next
					# column a row lower than the hole, and the one after no higher than it)
					if (x > 1 and heights[x - 1] <= level - 1 and heights[x - 2] <= level) \
							or (x < 8 and heights[x + 1] <= level - 1 and heights[x + 2] <= level):
						overhangs += 1
					else:
						cavities += 1
					var cells = min(6, heights[x] - level - 1)
					covered += cells
					covered_sq += cells * cells
		above |= row
	value += W["row_transitions"] * transitions
	value += cavity_weight * cavities + W["cavity_cells_sq"] * cavities * cavities
	value += overhang_weight * overhangs + W["overhang_cells_sq"] * overhangs * overhangs
	value += covered_weight * covered + W["covered_cells_sq"] * covered_sq

	_tslot_bonus = TSLOT[tslot_lines(rows, heights)] if sees_tslots else 0.0
	_cavities = cavities
	if trace:
		terms = {"height": height, "bump": bump, "bump_sq": bump_sq, "transitions": transitions, "cavities": cavities,
			"overhangs": overhangs, "covered": covered, "well": well, "well_depth": depth_, "tslot": _tslot_bonus, "value": value + _tslot_bonus}
	return value + _tslot_bonus


# The best T-spin double slot open from above (a "sky" slot): a T pointing down would sit with its
# stem on top of a column, both corners under its arms filled, one corner over its arms filled
# (the overhang it spins under) and the other side open. Returns the lines a T there would clear,
# 0 if there is no slot.
func tslot_lines(rows: PackedInt32Array, heights: PackedInt32Array) -> int:
	var best_lines = 0
	for x in range(1, 9):
		var r = 22 - heights[x]  # the row of the T's arms; its stem goes in the row under
		if r < 1 or r > 22:
			continue
		var arms = 7 << (x - 1)
		if rows[r] & arms or rows[r + 1] & (1 << x):
			continue
		var left_bit = 1 << (x - 1)
		var right_bit = 1 << (x + 1)
		if not (rows[r + 1] & left_bit) or not (rows[r + 1] & right_bit):
			continue
		var over_left = rows[r - 1] & left_bit != 0
		var over_right = rows[r - 1] & right_bit != 0
		if over_left == over_right:
			continue
		# The open side must be clear all the way up
		var open_bit = right_bit if over_left else left_bit
		var clear = true
		for yy in range(0, r):
			if rows[yy] & (open_bit | (1 << x)):
				clear = false
				break
		if not clear:
			continue
		var lines = int((rows[r] | arms) == FULL) + int((rows[r + 1] | (1 << x)) == FULL)
		best_lines = max(best_lines, lines)
	return best_lines


# ---- Search ----------------------------------------------------------------------------------

# Starts thinking about a position: the board, the current piece, the hold (-1 for none), the
# pieces after (the game's queue), the back-to-back and combo counts and the incoming garbage
func start(rows: PackedInt32Array, current: int, hold: int, queue: Array, b2b: int, combo: int, incoming: int):
	pieces = [current] + queue
	var root = SearchNode.new()
	root.rows = rows
	root.hold = hold
	root.next = 0
	root.b2b = b2b
	root.combo = combo
	root.incoming = incoming
	root.score = 0.0
	root.value = 0.0
	root.first = []
	evaluate(rows, b2b, 0)
	root.cavities = _cavities
	layer = [root]
	children = []
	work = []
	refine_index = -1
	layer_index = 0
	depth = 0
	best = null
	done = false


# Thinks for about budget_usec. Returns true when the search is complete.
func step(budget_usec: int) -> bool:
	var stop = Time.get_ticks_usec() + budget_usec
	while not done and Time.get_ticks_usec() < stop:
		if not work.is_empty():
			_expand_option(work.pop_back())
			continue
		if layer_index < layer.size():
			work = _options(layer[layer_index])
			layer_index += 1
			continue
		# The layer is done. First check its best boards for the T-spins a T could really make
		# there, then keep the best, and go one placement deeper.
		if children.is_empty():
			done = true
			break
		if refine_index == -1:
			children.sort_custom(func(a, b): return a.value > b.value)
			refine_index = 0
			refine_count = min(children.size(), clampi(beam / 2 + 2, 4, 8)) if sees_tslots else 0
		if refine_index < refine_count:
			_refine(children[refine_index])
			refine_index += 1
			continue
		refine_index = -1
		children.sort_custom(func(a, b): return a.value > b.value)
		best = children[0]
		depth += 1
		if depth >= depth_limit:
			done = true
			break
		layer = children.slice(0, max(2, int(beam * pow(beam_decay, depth - 1))))
		children = []
		layer_index = 0
	return done


# Swaps the board's estimated T-spin slot for the best T-spin a T can really reach there
func _refine(node: SearchNode):
	var exact = slot_weights[tspin_lines(node.rows)]
	node.value += exact - node.tslot
	node.tslot = exact


# The most lines a T-spin (a full one) clears that a T can reach on this board, 0 if none
func tspin_lines(rows: PackedInt32Array) -> int:
	var most = 0
	for placement in placements(rows, T):
		if placement[1] != Game.Spin.FULL:
			continue
		var lines = 0
		var counted = {}
		for idx in placement[0]:
			var y = idx / 10
			if counted.has(y):
				continue
			counted[y] = true
			var row = rows[y]
			for other in placement[0]:
				if other / 10 == y:
					row |= 1 << (other % 10)
			if row == FULL:
				lines += 1
		most = max(most, lines)
	return most


# The whole search, for a worker thread: it runs until it is done or told to stop
func think():
	while not done and not stop:
		step(2000)


# The chosen move so far: [held, piece, cells, actions], or [] if every move tops out
func decision() -> Array:
	return best.first if best != null else []


# The ways a node can go on: place the current piece, or hold it and place the held one (or, with
# nothing held yet, the next one). Each is [node, piece, hold after, next index, held].
func _options(node: SearchNode) -> Array:
	var n = node.next
	if n >= pieces.size():
		return []
	var current = pieces[n]
	var options = [[node, current, node.hold, n + 1, false]]
	if node.hold == -1:
		if n + 1 < pieces.size():
			options.append([node, pieces[n + 1], current, n + 2, true])
	elif node.hold != current:
		options.append([node, node.hold, current, n + 1, true])
	return options


func _expand_option(option: Array):
	var node: SearchNode = option[0]
	var type: int = option[1]
	for placement in placements(node.rows, type):
		var child = play(node, type, placement, option[2], option[3], option[4])
		if child == null:
			continue
		if depth == 0 and noise > 0.0:
			child.value += rng.randf_range(-noise, noise)
		children.append(child)


# Plays a decision on the game: hold if it says so, then the moves, which leave the piece where the
# bot planned it (the caller hard drops it). The game's own rules make every move.
static func apply(game, move: Array):
	if move[0]:
		game.hold()
	for action in move[3]:
		match action:
			Action.LEFT:
				game.move_piece(Game.MoveDirections.LEFT)
			Action.RIGHT:
				game.move_piece(Game.MoveDirections.RIGHT)
			Action.CW:
				game.rotate_piece(Piece.RotationAmount.NINETY_DEGREES)
			Action.CCW:
				game.rotate_piece(Piece.RotationAmount.TWO_HUNDRED_SEVENTY_DEGREES)
			Action.FLIP:
				game.rotate_piece(Piece.RotationAmount.ONE_HUNDRED_EIGHTY_DEGREES)
			Action.DROP:
				while game.move_piece(Game.MoveDirections.DOWN):
					pass


# The piece's cells in the game, as the bot numbers them (sorted y * 10 + x)
static func cells_in(game) -> PackedInt32Array:
	var out = PackedInt32Array()
	for p in game.current_piece_coordinates:
		out.append(int(p.y) * 10 + int(p.x))
	out.sort()
	return out
