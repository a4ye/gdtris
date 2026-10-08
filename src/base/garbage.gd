extends RefCounted
# Incoming garbage, by TETR.IO's rules (season 1 TETRA LEAGUE settings):
# - An attack waits GARBAGE_DELAY ("garbage speed", 20 frames) in the queue before it can rise.
# - Block: a placement that clears lines sends its attack against the queue, which cancels that
#   many incoming lines, oldest first. Here what is left over goes nowhere. A clear never lets
#   garbage rise.
# - Tank: a placement that clears nothing lets the ready garbage rise into the board, at most
#   GARBAGE_CAP lines a placement. The rest waits for the next placement.
# - All the lines of one attack have their hole in the same column; each attack gets a new random
#   column.

const GARBAGE_DELAY = 20 / 60.0  # seconds
const GARBAGE_CAP = 8  # lines

# Oldest first: {"lines": int, "time": arrival on the game clock (s), "column": the hole}
var queue: Array = []
var rng := RandomNumberGenerator.new()


func _init():
	rng.randomize()


func clear():
	queue.clear()


func receive(lines: int, time: float):
	queue.append({"lines": lines, "time": time, "column": rng.randi_range(0, 9)})


func total() -> int:
	var lines = 0
	for attack in queue:
		lines += attack["lines"]
	return lines


func is_ready(attack: Dictionary, now: float) -> bool:
	return now - attack["time"] >= GARBAGE_DELAY


# Cancels incoming lines with an attack, oldest first, ready or not. Returns the lines cancelled.
func cancel(attack: int) -> int:
	var cancelled = 0
	while attack > 0 and not queue.is_empty():
		var used = min(attack, queue[0]["lines"])
		queue[0]["lines"] -= used
		attack -= used
		cancelled += used
		if queue[0]["lines"] == 0:
			queue.pop_front()
	return cancelled


# Takes the garbage that rises at a placement with no clear: the ready attacks, oldest first, up to
# GARBAGE_CAP lines, as [lines, hole column] pairs. An attack cut by the cap keeps its hole.
func take(now: float) -> Array:
	var rising = []
	var room = GARBAGE_CAP
	while room > 0 and not queue.is_empty() and is_ready(queue[0], now):
		var lines = min(room, queue[0]["lines"])
		rising.append([lines, queue[0]["column"]])
		queue[0]["lines"] -= lines
		room -= lines
		if queue[0]["lines"] == 0:
			queue.pop_front()
	return rising
