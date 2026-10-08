extends Node
# Before a versus match: the bot's level and speed, saved as they change, then START

const UI = preload("res://src/menu/ui.gd")
const WIDTH = 980

# What each level does (Bot.LEVELS), and its attack a piece, measured in real time at 2 pieces a
# second against steady garbage (about half a line a second), twice over 90 s or until it topped
# out (the lowest levels smoothed: they top out early). Above 8 pieces a second the bot has less
# time to think than it uses and plays a little worse: level 10 made 0.73 a piece at 6, 0.67 at 10
# and 0.51 at 20 (speed_factor). Remeasured after the bot learned to avoid holes and to keep its
# back-to-back (level 10: 0.78 at 2 pieces a second, about 290 APM at 6).
const LEVEL_NAMES = ["", "NOVICE", "BEGINNER", "CASUAL", "REGULAR", "SKILLED", "INTERMEDIATE", "ADVANCED", "STRONG", "EXPERT", "MASTER"]
const LEVEL_TEXT = [
	"",
	"Looks at one piece only and makes many mistakes. Mostly singles and doubles.",
	"Looks at one piece only and makes some mistakes. Mostly singles and doubles.",
	"Looks at one piece, makes a few mistakes, and starts to build T-spins.",
	"Looks at one piece and seldom makes a mistake. Quads and some T-spins.",
	"Plans two pieces ahead, avoids holes and keeps its back-to-back going with T-spins and quads.",
	"Plans two pieces ahead and keeps more options open.",
	"Plans three pieces ahead, makes no random mistakes and sends big, clean attacks.",
	"Plans three pieces ahead and keeps more options open.",
	"Plans four pieces ahead.",
	"Plans four pieces ahead and keeps the most options open. Its best play.",
]
const ATTACK_PER_PIECE = [0.0, 0.28, 0.32, 0.34, 0.38, 0.53, 0.58, 0.6, 0.68, 0.72, 0.78]

var layer: CanvasLayer
var level_value: Label
var level_text: Label
var speed_value: Label
var summary: Label
var lives: Button
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
	panel.position = Vector2((UI.DESIGN_SIZE.x - WIDTH) / 2, 170)
	panel.size = Vector2(WIDTH, 0)
	root.add_child(panel)
	var page = VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	panel.add_child(page)

	var header = HBoxContainer.new()
	header.add_child(UI.heading("VS BOT", 42, UI.TEXT))
	header.add_child(spacer())
	var saved = UI.label("Saved as you change it", 20, UI.TEXT_DIM)
	saved.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(saved)
	page.add_child(header)
	page.add_child(rule())

	var level = slider_row(page, "LEVEL", 1, 10)
	level_value = level[1]
	level_text = UI.label("", 20, UI.TEXT_DIM)
	level_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	level_text.custom_minimum_size.y = 56
	page.add_child(level_text)
	level[0].value_changed.connect(func(v): changed("level", int(v)))

	var speed = slider_row(page, "SPEED", 5, 200)
	speed_value = speed[1]
	var speed_text = UI.label("Pieces a second, up to 20. A new player places about 1 a second, a fast one 3 or more.", 20, UI.TEXT_DIM)
	speed_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(speed_text)
	speed[0].value_changed.connect(func(v): changed("pps", int(v)))

	var lives_row = HBoxContainer.new()
	var lives_name = UI.label("UNLIMITED LIVES", 27)
	lives_name.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lives_row.add_child(lives_name)
	lives_row.add_child(spacer())
	lives = Button.new()
	lives.custom_minimum_size = Vector2(170, 50)
	lives.add_theme_font_size_override("font_size", 24)
	lives.mouse_entered.connect(lives.grab_focus)
	lives.focus_entered.connect(tick)
	lives.pressed.connect(func():
		GameConfig.change_setting("bot", "unlimited", not GameConfig.get_setting("bot", "unlimited"))
		UI.play(self, "rotate")
		describe())
	lives_row.add_child(lives)
	page.add_child(lives_row)
	var lives_text = UI.label("When you top out, your board starts again and the round goes on until the bot tops out.", 20, UI.TEXT_DIM)
	lives_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(lives_text)

	summary = UI.label("", 22, UI.GOLD)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(summary)
	page.add_child(rule())

	var footer = HBoxContainer.new()
	var back = button("BACK")
	back.pressed.connect(go_back)
	footer.add_child(back)
	footer.add_child(spacer())
	var keys = UI.label("ENTER  start      ESC  back", 20, UI.TEXT_DIM)
	keys.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	footer.add_child(keys)
	footer.add_child(spacer())
	var start = button("START")
	start.pressed.connect(func():
		MainGame.mode = "versus"
		get_tree().change_scene_to_file("res://game.tscn"))
	footer.add_child(start)
	page.add_child(footer)

	level[0].set_value_no_signal(GameConfig.get_setting("bot", "level"))
	speed[0].set_value_no_signal(GameConfig.get_setting("bot", "pps"))
	describe()
	fit()
	get_tree().get_root().size_changed.connect(fit)
	start.grab_focus()
	set_deferred("sounds_on", true)


# A title, its value on the right, and the slider under them: returns [slider, value label]
func slider_row(parent: Control, title: String, low: int, high: int) -> Array:
	var top = HBoxContainer.new()
	var name = UI.label(title, 27)
	top.add_child(name)
	top.add_child(spacer())
	var value = UI.label("", 27, UI.ACCENT)
	top.add_child(value)
	parent.add_child(top)
	var slider = HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = 1
	slider.custom_minimum_size.y = 30
	slider.focus_entered.connect(tick)
	slider.focus_entered.connect(func(): name.add_theme_color_override("font_color", UI.ACCENT))
	slider.focus_exited.connect(func(): name.add_theme_color_override("font_color", UI.TEXT))
	slider.mouse_entered.connect(slider.grab_focus)
	parent.add_child(slider)
	return [slider, value]


func changed(key: String, value: int):
	GameConfig.change_setting("bot", key, value)
	describe()
	tick()


func describe():
	var level = int(GameConfig.get_setting("bot", "level"))
	var pps = GameConfig.get_setting("bot", "pps") / 10.0
	level_value.text = "%d · %s" % [level, LEVEL_NAMES[level]]
	level_text.text = LEVEL_TEXT[level]
	speed_value.text = "%.1f PPS" % pps
	var on = GameConfig.get_setting("bot", "unlimited")
	lives.text = "ON" if on else "OFF"
	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		lives.add_theme_color_override(state, UI.GOLD if on else UI.TEXT)
	var speed_factor = clamp(1.0 - (pps - 8.0) * 0.025, 0.65, 1.0)
	summary.text = "About %d APM (lines of attack a minute), as measured in matches" % roundi(ATTACK_PER_PIECE[level] * speed_factor * pps * 60.0)


func button(text: String) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(260, 70)
	b.add_theme_font_size_override("font_size", 28)
	b.add_theme_font_override("font", UI.spaced_font(6))
	b.mouse_entered.connect(b.grab_focus)
	b.focus_entered.connect(tick)
	return b


func spacer() -> Control:
	var s = Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s


func rule() -> ColorRect:
	var r = ColorRect.new()
	r.color = Color(1, 1, 1, 0.08)
	r.custom_minimum_size.y = 2
	return r


func _input(event):
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		go_back()


func go_back():
	UI.play(self, "softdrop")
	get_tree().change_scene_to_file("res://home.tscn")


func tick():
	if sounds_on and Time.get_ticks_msec() - last_tick > 40:
		last_tick = Time.get_ticks_msec()
		UI.play(self, "move")


func fit():
	UI.fit(layer, get_viewport().get_visible_rect().size)
