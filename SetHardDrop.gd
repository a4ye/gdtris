extends Button


# Called when the node enters the scene tree for the first time.
func _ready():
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	
func _input(event):
	if event is InputEventKey && event.pressed && not event.echo && button_pressed:
		# Escape cancels and keeps the old key; binding it would also leave the settings screen
		if event.keycode != KEY_ESCAPE:
			GameConfig.change_setting("controls", "hard_drop", event.keycode)
		button_pressed = false
		# Stop the key here, so that Escape does not leave the screen and Space does not press this button again
		get_viewport().set_input_as_handled()
