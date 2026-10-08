extends RefCounted
# The bot's side of a versus match: its own Game, and the Bot that plays it in real time. It thinks
# about each piece on a worker thread (WorkerThreadPool), from the moment the piece appears to the
# moment its speed lets it place it (1 / pps seconds after the last one), so it can use all of that
# time without holding up the game's frames. If the search is not finished by then, it stops it
# and plays the best move found so far.

const Bot = preload("res://src/versus/bot.gd")

var game: Game
var bot: Bot
var level: int
var pps: float
var next_time := 0.0  # game clock of the next placement
var thinking := false
var pieces_placed := 0
var attack_sent := 0
var last_cells := PackedInt32Array()  # where the last piece went (board indices y * 10 + x)
var rushed := 0  # pieces placed before the search was finished (its best move so far)
var done_time := -1.0  # game clock when the search for this piece finished
var task := -1  # the worker thread's task, or -1


func _init(level_: int, pps_: float):
	level = level_
	pps = pps_
	bot = Bot.new(level)
	game = Game.new()
	game.enable_garbage()
	game.auto_restart = false


# Ends the search on the worker thread, if one runs, and waits for it. Call before the bot's game
# or the bot change, and before the bot goes away.
func halt():
	if task != -1:
		bot.stop = true
		WorkerThreadPool.wait_for_task_completion(task)
		task = -1


func reset(now: float):
	halt()
	game.restart()
	game.topped_out = false
	pieces_placed = 0
	attack_sent = 0
	next_time = now + 1.0 / pps
	thinking = false


func _think():
	var queue = []
	for p in game.piece_queue:
		queue.append(p.piece_type)
	var hold = game.hold_piece.piece_type if game.hold_piece != null else -1
	bot.start(Bot.rows_of(game), game.current_piece.piece_type, hold, queue, game.b2b, game.combo, game.garbage.total())
	bot.stop = false
	task = WorkerThreadPool.add_task(bot.think)
	thinking = true


# Called every frame while the round is on. Returns the game's placement result when the bot
# placed a piece this frame, else an empty Dictionary.
func update(now: float) -> Dictionary:
	if game.game_ended:
		return {}
	if not thinking:
		_think()
		done_time = -1.0
	if bot.done and done_time < 0.0:
		done_time = now
	if now < next_time:
		return {}
	if not bot.done and bot.depth == 0:
		return {}  # nothing found yet: think on
	var finished = bot.done
	halt()
	var move = bot.decision()
	# Keep the search to the time there is: narrower when it ran out of time, wider again (up to the
	# level's width) when it finished with time to spare
	var interval = 1.0 / pps
	if not finished:
		rushed += 1
		bot.beam = max(2, int(bot.beam * 0.75))
	elif next_time - done_time > 0.4 * interval:
		bot.beam = min(bot.max_beam, bot.beam + 1)
	last_cells = PackedInt32Array()
	if not move.is_empty():
		Bot.apply(game, move)
		last_cells = move[2]
	var info = game.hard_drop()
	pieces_placed += 1
	attack_sent += info["attack"]
	thinking = false
	# Keep to the schedule, unless it fell a whole piece behind (a long think)
	next_time = next_time + interval if now - next_time < interval else now + interval
	return info
