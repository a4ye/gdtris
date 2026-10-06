extends LineEdit

var regex = RegEx.new()
var oldtext = ""

func _ready():
	regex.compile("^[0-9]*$")
	text = str(GameConfig.get_setting("handling", "das"))
	# What an invalid edit goes back to; empty here would wipe the field on the first bad key
	oldtext = text
	text_changed.connect(on_text_changed)
	on_window_resize()
	get_tree().get_root().size_changed.connect(on_window_resize) 

func on_text_changed(new_text):
	if regex.search(new_text) && int(new_text) >= 0:
		oldtext = new_text
		GameConfig.change_setting("handling", "das", int(text))
	else:
		text = oldtext
		
	set_caret_column(text.length())

func get_value():
	return(int(text))

func on_window_resize():
	# The settings layer (CanvasLayer2.gd) scales this design size to the window
	var window_size = Vector2(1920, 1080)
	add_theme_font_size_override("font_size", window_size.x / 1920.0 * 64)
	position.x = window_size.x / 2 - size.x / 2
	# Just under its label, which is on row 4 of 10 (see the label scripts)
	position.y = window_size.y / 10 * 4 + 84
