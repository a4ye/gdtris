extends Node
# Settings: handling, volume, survival and the keys, on one glass panel. Every change is saved at once.

const UI = preload("res://src/menu/ui.gd")
const Survival = preload("res://src/base/survival.gd")
const SURVIVAL_KEYS = ["interval", "size", "ramp", "random"]
const FRAME_MS = 1000.0 / 60.0
const SDF_INSTANT = 41  # the far right of the SDF slider; saved as 0, which the game takes as instant

const ACTIONS = [
	["left", "Move left"], ["right", "Move right"], ["soft_drop", "Soft drop"], ["hard_drop", "Hard drop"],
	["rotate_cw", "Rotate right"], ["rotate_ccw", "Rotate left"], ["rotate_180", "Rotate 180°"],
	["hold", "Hold"], ["restart", "Restart"],
]

var layer: CanvasLayer
var sliders = {}  # setting -> HSlider
var values = {}   # setting -> the Label showing its value
var keycaps = {}  # action -> Button
var listening = ""  # the action waiting for its new key, or ""
var survival_summary: Label
var sounds_on = false
var last_tick = 0


func _ready():
	GameConfig.create()
	UI.add_background(self)
	var made = UI.add_menu_layer(self)
	layer = made[0]
	var root: Control = made[1]

	var panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.box(UI.GLASS, Color(UI.ACCENT, 0.28), 2, 22, 40))
	panel.position = Vector2(80, 0)
	panel.size = Vector2(1760, 0)
	root.add_child(panel)

	var page = VBoxContainer.new()
	page.add_theme_constant_override("separation", 18)
	panel.add_child(page)

	var header = HBoxContainer.new()
	header.add_child(UI.heading("SETTINGS", 42, UI.TEXT))
	header.add_child(spacer())
	var saved = UI.label("Changes are saved as you make them", 20, UI.TEXT_DIM)
	saved.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(saved)
	page.add_child(header)
	page.add_child(rule())

	var columns = HBoxContainer.new()
	columns.add_theme_constant_override("separation", 70)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(columns)

	var left = VBoxContainer.new()
	left.custom_minimum_size.x = 500
	left.add_theme_constant_override("separation", 10)
	columns.add_child(left)
	left.add_child(UI.heading("HANDLING"))
	add_slider(left, "das", "DAS", 0, 333, "How long left or right is held before the piece starts to repeat.")
	add_slider(left, "arr", "ARR", 0, 100, "The time between moves once DAS has charged. 0 goes straight to the wall.")
	add_slider(left, "sdf", "SDF", 1, SDF_INSTANT, "Soft drop speed, as a multiple of gravity. All the way right is instant.")
	var gap = Control.new()
	gap.custom_minimum_size.y = 10
	left.add_child(gap)
	left.add_child(UI.heading("AUDIO"))
	add_slider(left, "volume", "VOLUME", 0, 100, "")

	var middle = VBoxContainer.new()
	middle.custom_minimum_size.x = 500
	middle.add_theme_constant_override("separation", 10)
	columns.add_child(middle)
	middle.add_child(UI.heading("SURVIVAL"))
	add_slider(middle, "interval", "ATTACK EVERY", 10, 100, "The average time between attacks at the start of a run.")
	add_slider(middle, "size", "ATTACK SIZE", 1, 8, "The average lines in an attack at the start of a run.")
	add_slider(middle, "ramp", "RAMP", 0, 300, "How fast it gets harder: every minute the attacks come more often and get bigger.")
	add_slider(middle, "random", "RANDOMNESS", 0, 100, "How much the size and timing of attacks vary, and how often a big spike comes.")
	survival_summary = UI.label("", 19, UI.GOLD)
	survival_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	middle.add_child(survival_summary)

	var right = VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	columns.add_child(right)
	right.add_child(UI.heading("CONTROLS"))
	for action in ACTIONS:
		var row = HBoxContainer.new()
		var name = UI.label(action[1], 27)
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(name)
		var cap = Button.new()
		cap.custom_minimum_size = Vector2(260, 50)
		cap.add_theme_font_size_override("font_size", 26)
		cap.pressed.connect(listen.bind(action[0]))
		cap.mouse_entered.connect(cap.grab_focus)
		cap.focus_entered.connect(tick)
		row.add_child(cap)
		keycaps[action[0]] = cap
		right.add_child(row)
	var how = UI.label("Choose a key, then press the new one. Esc cancels. A key that is already in use swaps over.", 19, UI.TEXT_DIM)
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(how)

	page.add_child(rule())
	var footer = HBoxContainer.new()
	var reset = footer_button("RESET DEFAULTS")
	reset.pressed.connect(reset_all)
	footer.add_child(reset)
	footer.add_child(spacer())
	var esc = UI.label("ESC  back", 20, UI.TEXT_DIM)
	esc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(esc)
	var back = footer_button("BACK")
	back.pressed.connect(go_back)
	footer.add_child(back)
	page.add_child(footer)

	refresh()
	center(panel)
	fit()
	get_tree().get_root().size_changed.connect(fit)
	sliders["das"].grab_focus()
	set_deferred("sounds_on", true)


# Centred on the screen by its real height, after the first layout: the wrapped text only knows its
# height once it has its width
func center(panel: PanelContainer):
	panel.modulate.a = 0.0
	await get_tree().process_frame
	await get_tree().process_frame
	panel.position.y = round((UI.DESIGN_SIZE.y - panel.size.y) / 2)
	panel.modulate.a = 1.0


func spacer() -> Control:
	var s = Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func rule() -> ColorRect:
	var r = ColorRect.new()
	r.color = Color(1, 1, 1, 0.08)
	r.custom_minimum_size.y = 2
	return r


func footer_button(text: String) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, 64)
	b.add_theme_font_size_override("font_size", 24)
	b.add_theme_font_override("font", UI.spaced_font(4))
	b.mouse_entered.connect(b.grab_focus)
	b.focus_entered.connect(tick)
	return b


func add_slider(parent: Control, key: String, title: String, low: int, high: int, description: String):
	var block = VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)
	var top = HBoxContainer.new()
	var name = UI.label(title, 27)
	top.add_child(name)
	top.add_child(spacer())
	var value = UI.label("", 27, UI.ACCENT)
	top.add_child(value)
	block.add_child(top)
	var slider = HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = 1
	slider.custom_minimum_size.y = 30
	slider.value_changed.connect(changed.bind(key))
	slider.focus_entered.connect(tick)
	# The title turns the accent colour while the slider has focus, so it is clear which one the arrows move
	slider.focus_entered.connect(func(): name.add_theme_color_override("font_color", UI.ACCENT))
	slider.focus_exited.connect(func(): name.add_theme_color_override("font_color", UI.TEXT))
	slider.mouse_entered.connect(slider.grab_focus)
	block.add_child(slider)
	if description != "":
		var text = UI.label(description, 19, UI.TEXT_DIM)
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		block.add_child(text)
	parent.add_child(block)
	sliders[key] = slider
	values[key] = value


func section_of(key: String) -> String:
	if key == "volume":
		return "audio"
	return "survival" if key in SURVIVAL_KEYS else "handling"


func describe(key: String, value: int) -> String:
	match key:
		"das", "arr":
			if value == 0:
				return "0 ms · instant"
			var frames = value / FRAME_MS
			var f = ("%dF" % roundi(frames)) if abs(frames - roundi(frames)) < 0.05 else ("%.1fF" % frames)
			return "%d ms · %s" % [value, f]
		"sdf":
			return "∞" if value == 0 else "%d×" % value
		"volume":
			return "OFF" if value == 0 else "%d %%" % value
		"interval":
			return "%.1f s" % (value / 10.0)
		"size":
			return "1 line" if value == 1 else "%d lines" % value
		"ramp":
			return "OFF · steady" if value == 0 else "%d %%" % value
		"random":
			return "OFF · fixed" if value == 0 else "%d %%" % value
	return str(value)


# What the survival settings add up to, in lines a second, at a few points in a run
func update_survival_summary():
	var opponent = Survival.new()
	opponent.configure(Survival.saved_options())
	var parts = []
	for minute in [0, 2, 4]:
		parts.append("%.1f" % opponent.average_rate(minute * 60.0) + (" at the start" if minute == 0 else " at %d min" % minute))
	survival_summary.text = "About " + ", ".join(parts) + " (lines a second)"


func changed(value: float, key: String):
	var saved = int(value)
	if key == "sdf" and saved >= SDF_INSTANT:
		saved = 0
	GameConfig.change_setting(section_of(key), key, saved)
	values[key].text = describe(key, saved)
	if key in SURVIVAL_KEYS:
		update_survival_summary()
	# A real game sound for the volume, so its level can be heard; a tick for the rest
	if sounds_on and Time.get_ticks_msec() - last_tick > (140 if key == "volume" else 50):
		last_tick = Time.get_ticks_msec()
		UI.play(self, "harddrop" if key == "volume" else "move")


func key_name(code: int) -> String:
	match code:
		KEY_LEFT:
			return "←"
		KEY_RIGHT:
			return "→"
		KEY_UP:
			return "↑"
		KEY_DOWN:
			return "↓"
	return OS.get_keycode_string(code).to_upper()


func refresh():
	for key in sliders:
		var saved = int(GameConfig.get_setting(section_of(key), key))
		sliders[key].set_value_no_signal(SDF_INSTANT if key == "sdf" and saved == 0 else saved)
		values[key].text = describe(key, saved)
	update_survival_summary()
	for action in keycaps:
		var cap: Button = keycaps[action]
		for state in ["normal", "hover", "focus", "pressed"]:
			cap.remove_theme_stylebox_override(state)
		cap.remove_theme_color_override("font_color")
		cap.remove_theme_color_override("font_hover_color")
		cap.remove_theme_color_override("font_focus_color")
		if action == listening:
			cap.text = "press a key"
			var gold = UI.box(Color(UI.GOLD, 0.14), UI.GOLD, 2, 12, 14)
			for state in ["normal", "hover", "focus", "pressed"]:
				cap.add_theme_stylebox_override(state, gold)
			for state in ["font_color", "font_hover_color", "font_focus_color"]:
				cap.add_theme_color_override(state, UI.GOLD)
		else:
			cap.text = key_name(GameConfig.get_setting("controls", action))


func listen(action: String):
	listening = "" if listening == action else action
	UI.play(self, "rotate")
	refresh()


func bind(action: String, code: int):
	var old = GameConfig.get_setting("controls", action)
	for other in ACTIONS:
		if other[0] != action and GameConfig.get_setting("controls", other[0]) == code:
			GameConfig.change_setting("controls", other[0], old)
	GameConfig.change_setting("controls", action, code)
	listening = ""
	UI.play(self, "lock")
	refresh()


func _input(event):
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if listening != "":
		# The key is for the binding, not for moving around the menu
		get_viewport().set_input_as_handled()
		if event.keycode == KEY_ESCAPE:
			listening = ""
			UI.play(self, "softdrop")
			refresh()
		elif event.keycode != KEY_NONE:
			bind(listening, event.keycode)
		return
	if event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		go_back()


func reset_all():
	GameConfig.reset_to_defaults()
	listening = ""
	UI.play(self, "rotate")
	refresh()


func go_back():
	UI.play(self, "softdrop")
	get_tree().change_scene_to_file("res://home.tscn")


func tick():
	if sounds_on and Time.get_ticks_msec() - last_tick > 40:
		last_tick = Time.get_ticks_msec()
		UI.play(self, "move")


func fit():
	UI.fit(layer, get_viewport().get_visible_rect().size)
