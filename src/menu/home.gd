extends Node
# The first screen: the logo, then PLAY, SURVIVAL, VS BOT and SETTINGS

const UI = preload("res://src/menu/ui.gd")
const BUTTON_WIDTH = 440

var layer: CanvasLayer
var sounds_on = false
var last_tick = 0


func _ready():
	GameConfig.create()
	UI.add_background(self)
	var made = UI.add_menu_layer(self)
	layer = made[0]
	var root: Control = made[1]

	var logo = preload("res://src/menu/logo.gd").new()
	logo.position = Vector2(0, 270)
	logo.size = Vector2(UI.DESIGN_SIZE.x, 180)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(logo)

	var buttons = VBoxContainer.new()
	buttons.add_theme_constant_override("separation", 18)
	buttons.position = Vector2((UI.DESIGN_SIZE.x - BUTTON_WIDTH) / 2, 520)
	buttons.size = Vector2(BUTTON_WIDTH, 0)
	root.add_child(buttons)
	var play = menu_button("PLAY", buttons)
	play.pressed.connect(func(): start("play"))
	var survival = menu_button("SURVIVAL", buttons)
	survival.pressed.connect(func(): start("survival"))
	var versus = menu_button("VS BOT", buttons)
	versus.pressed.connect(func():
		UI.play(self, "rotate")
		get_tree().change_scene_to_file("res://vs_setup.tscn"))
	var settings = menu_button("SETTINGS", buttons)
	settings.pressed.connect(func():
		UI.play(self, "rotate")
		get_tree().change_scene_to_file("res://settings.tscn"))

	var hint = UI.label("↑ ↓  choose      ENTER  select      ESC  return to main menu", 20, UI.TEXT_DIM, HORIZONTAL_ALIGNMENT_CENTER)
	hint.position = Vector2(0, 990)
	hint.size = Vector2(UI.DESIGN_SIZE.x, 30)
	root.add_child(hint)

	fit()
	get_tree().get_root().size_changed.connect(fit)
	play.grab_focus()
	# The first focus is not a choice: no sound for it
	set_deferred("sounds_on", true)


# "play" or "survival" (see MainGame.mode)
func start(mode: String):
	MainGame.mode = mode
	get_tree().change_scene_to_file("res://game.tscn")


func menu_button(text: String, parent: Control) -> Button:
	var b = Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(BUTTON_WIDTH, 80)
	b.add_theme_font_size_override("font_size", 36)
	b.add_theme_font_override("font", UI.spaced_font(8))
	b.mouse_entered.connect(b.grab_focus)
	b.focus_entered.connect(tick)
	parent.add_child(b)
	return b


func tick():
	if sounds_on and Time.get_ticks_msec() - last_tick > 40:
		last_tick = Time.get_ticks_msec()
		UI.play(self, "move")


func fit():
	UI.fit(layer, get_viewport().get_visible_rect().size)
