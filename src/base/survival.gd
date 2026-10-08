extends RefCounted
# The survival mode's opponent. It sends attacks of random size at random times, and it presses
# harder the longer the run goes. The settings (SETTINGS > SURVIVAL, see configure) set how. With
# the default ones, on average:
#   start:   an attack every 5 s, about 1.4 lines each      (about 0.3 lines a second)
#   2 min:   every 3.6 s, about 2.9 lines                    (0.8 a second)
#   4 min:   every 2.6 s, about 4.5 lines                    (1.7 a second)
#   6 min:   every 1.9 s, about 6.1 lines                    (3.2 a second)
# Every wait and every size is drawn at random around those averages, and some attacks are spikes.

const FIRST_ATTACK = 4.0  # seconds into the run
const INTERVAL_MIN = 1.5  # the ramp does not take the average wait below this

var interval_start := 5.0  # average seconds between attacks at the start
var interval_decay := 0.85  # the average wait is this much of what it was a minute before
var interval_spread := 0.45  # each wait is the average, give or take this part of it
var size_start := 1.0  # average lines an attack at the start
var size_growth := 0.7  # more lines an attack each minute
var size_spread := 0.5  # each attack is the average, give or take this part of it
var spike_chance := 0.125  # a spike is twice as big, plus 2
const SIZE_MAX = 15

var rng := RandomNumberGenerator.new()
var next_time := FIRST_ATTACK


func _init():
	rng.randomize()


# The settings, as saved (GameConfig section "survival"):
#   interval: the average wait at the start, in tenths of a second
#   size:     the average attack at the start, in lines
#   ramp:     how fast it gets harder, in % (100: the wait shrinks 15 % and attacks grow 0.7 lines
#             a minute; 0: it never gets harder)
#   random:   how much attacks vary, in % (50: waits 55-145 % of the average, sizes 50-150 %, one
#             attack in 8 a spike; 0: every attack is the same; 100: twice that)
func configure(options: Dictionary):
	interval_start = options["interval"] / 10.0
	size_start = float(options["size"])
	var ramp = options["ramp"] / 100.0
	interval_decay = pow(0.85, ramp)
	size_growth = 0.7 * ramp
	var random = options["random"] / 100.0
	interval_spread = 0.9 * random
	size_spread = 1.0 * random
	spike_chance = 0.25 * random


static func saved_options() -> Dictionary:
	var options = {}
	for key in GameConfig.DEFAULTS["survival"]:
		options[key] = GameConfig.get_setting("survival", key)
	return options


func reset():
	next_time = FIRST_ATTACK


# Called every frame with the run's clock; sends the attacks that are due into the garbage queue.
# Returns their sizes, for the sounds.
func update(now: float, garbage) -> Array:
	var sent = []
	while now >= next_time:
		var lines = attack_size(next_time)
		garbage.receive(lines, next_time)
		sent.append(lines)
		next_time += interval(next_time)
	return sent


func average_interval(time: float) -> float:
	return max(min(INTERVAL_MIN, interval_start), interval_start * pow(interval_decay, time / 60.0))


func average_size(time: float) -> float:
	return size_start + size_growth * time / 60.0


func interval(time: float) -> float:
	return average_interval(time) * rng.randf_range(1.0 - interval_spread, 1.0 + interval_spread)


func attack_size(time: float) -> int:
	var lines = average_size(time) * rng.randf_range(1.0 - size_spread, 1.0 + size_spread)
	if rng.randf() < spike_chance:
		lines = lines * 2.0 + 2.0
	return clampi(roundi(lines), 1, SIZE_MAX)


# About how many lines a second come in at a time, for the settings screen (rounding and the
# limits on size are left out)
func average_rate(time: float) -> float:
	var size = average_size(time)
	return (size * (1.0 + spike_chance) + 2.0 * spike_chance) / average_interval(time)
