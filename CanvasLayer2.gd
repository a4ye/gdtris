extends CanvasLayer

# The settings screen is laid out for 1920 x 1080. Scale all of it to fit the window, so that in a
# smaller window the two columns do not overlap and the lower rows are not cut off.
const DESIGN_SIZE = Vector2(1920, 1080)

# Called when the node enters the scene tree for the first time.
func _ready():
	fit()
	get_tree().get_root().size_changed.connect(fit)

func fit():
	var window_size = Vector2(get_viewport().size)
	var s = min(window_size.x / DESIGN_SIZE.x, window_size.y / DESIGN_SIZE.y)
	scale = Vector2(s, s)
	offset = (window_size - DESIGN_SIZE * s) / 2
