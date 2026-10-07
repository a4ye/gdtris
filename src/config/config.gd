class_name GameConfig

static var config = ConfigFile.new()

# Every setting and its default. Handling as in TETR.IO: DAS 10 frames, ARR 2 frames (at 60 fps),
# SDF 6x (0 means instant). Volume is a percentage of full.
const DEFAULTS = {
	"handling": {"das": 167, "arr": 33, "sdf": 6},
	"audio": {"volume": 80},
	"controls": {
		"left": KEY_LEFT, "right": KEY_RIGHT, "soft_drop": KEY_DOWN, "hard_drop": KEY_SPACE,
		"rotate_cw": KEY_C, "rotate_ccw": KEY_Z, "rotate_180": KEY_X, "hold": KEY_SHIFT, "restart": KEY_R,
	},
}

# Called when the node enters the scene tree for the first time.
static func create():
	config.load("user://config.cfg")

	# Set default values if they don't exist
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			if not config.has_section_key(section, key):
				config.set_value(section, key, DEFAULTS[section][key])
	apply_volume()

static func change_setting(section: String, key: String, value):
	config.set_value(section, key, value)
	config.save("user://config.cfg")
	if section == "audio":
		apply_volume()

static func get_setting(section: String, key: String):
	return config.get_value(section, key)

static func reset_to_defaults():
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			config.set_value(section, key, DEFAULTS[section][key])
	config.save("user://config.cfg")
	apply_volume()

static func apply_volume():
	var volume = float(config.get_value("audio", "volume", 80)) / 100.0
	AudioServer.set_bus_mute(0, volume <= 0.0)
	AudioServer.set_bus_volume_db(0, linear_to_db(max(volume, 0.0001)))
