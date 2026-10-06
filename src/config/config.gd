class_name GameConfig

static var config = ConfigFile.new()

# Called when the node enters the scene tree for the first time.
static func create():
	config.load("user://config.cfg")

	# Set default values if they don't exist
	# Handling defaults as in TETR.IO: DAS 10 frames, ARR 2 frames (at 60 fps), SDF 6x
	if not config.has_section_key("handling", "das"):
		config.set_value("handling", "das", 167)
	if not config.has_section_key("handling", "arr"):
		config.set_value("handling", "arr", 33)
	if not config.has_section_key("handling", "sdf"):
		config.set_value("handling", "sdf", 6)
	if not config.has_section_key("controls", "left"):
		config.set_value("controls", "left", Key.KEY_LEFT)
	if not config.has_section_key("controls", "right"):
		config.set_value("controls", "right", Key.KEY_RIGHT)
	if not config.has_section_key("controls", "soft_drop"):
		config.set_value("controls", "soft_drop", Key.KEY_DOWN)
	if not config.has_section_key("controls", "hard_drop"):
		config.set_value("controls", "hard_drop", Key.KEY_SPACE)
	if not config.has_section_key("controls", "rotate_cw"):
		config.set_value("controls", "rotate_cw", Key.KEY_C)
	if not config.has_section_key("controls", "rotate_ccw"):
		config.set_value("controls", "rotate_ccw", Key.KEY_Z)
	if not config.has_section_key("controls", "rotate_180"):
		config.set_value("controls", "rotate_180", Key.KEY_X)
	if not config.has_section_key("controls", "hold"):
		config.set_value("controls", "hold", Key.KEY_SHIFT)
	if not config.has_section_key("controls", "restart"):
		config.set_value("controls", "restart", Key.KEY_R)
		

static func change_setting(section: String, key: String, value):
	config.set_value(section, key, value)
	config.save("user://config.cfg")

static func get_setting(section: String, key: String):
	return config.get_value(section, key)
