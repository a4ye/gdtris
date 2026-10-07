extends RefCounted
# The look of the menus, shared by the home screen and the settings: colours, font, one theme for
# every control, the background, and the menu sounds. Menus are laid out at DESIGN_SIZE and scaled
# to the window, so they look the same at any size.

const DESIGN_SIZE = Vector2(1920, 1080)

const ACCENT = Color(0.62, 0.9, 0.78)  # the glow of the board's panel
const GOLD = Color(1.0, 0.8, 0.32)     # the back-to-back colour
const TEXT = Color(0.93, 0.96, 0.95)
const TEXT_DIM = Color(0.6, 0.67, 0.65)
const GLASS = Color(0.015, 0.03, 0.028, 0.8)

static var _font: Font
static var _sounds = {}


static func font() -> Font:
	if _font == null:
		_font = load("res://assets/JetBrainsMono-SemiBold.ttf")
	return _font


# The same font with wider letter spacing, for headings
static func spaced_font(spacing: int) -> FontVariation:
	var f = FontVariation.new()
	f.base_font = font()
	f.spacing_glyph = spacing
	return f


static func box(bg: Color, border: Color = Color(0, 0, 0, 0), border_width: int = 0, radius: int = 10, margin: float = 0) -> StyleBoxFlat:
	var b = StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(border_width)
	b.set_corner_radius_all(radius)
	b.set_content_margin_all(margin)
	b.anti_aliasing = true
	return b


static func circle(diameter: int, color: Color) -> ImageTexture:
	var img = Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var r = diameter / 2.0
	for y in diameter:
		for x in diameter:
			var d = Vector2(x + 0.5 - r, y + 0.5 - r).length()
			img.set_pixel(x, y, Color(color, clamp(r - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func theme() -> Theme:
	var t = Theme.new()
	t.default_font = font()
	t.default_font_size = 30
	t.set_color("font_color", "Label", TEXT)

	# Solid enough that the pieces falling behind do not show through
	t.set_stylebox("normal", "Button", box(Color(0.035, 0.055, 0.05, 0.82), Color(1, 1, 1, 0.1), 1, 12, 14))
	t.set_stylebox("hover", "Button", box(Color(0.06, 0.11, 0.095, 0.88), Color(ACCENT, 0.5), 1, 12, 14))
	t.set_stylebox("pressed", "Button", box(Color(0.12, 0.24, 0.2, 0.92), ACCENT, 2, 12, 14))
	t.set_stylebox("hover_pressed", "Button", box(Color(0.12, 0.24, 0.2, 0.92), ACCENT, 2, 12, 14))
	t.set_stylebox("focus", "Button", box(Color(0.08, 0.17, 0.14, 0.9), ACCENT, 2, 12, 14))
	t.set_stylebox("disabled", "Button", box(Color(0.035, 0.055, 0.05, 0.6), Color(1, 1, 1, 0.05), 1, 12, 14))
	for state in ["font_color", "font_hover_color", "font_focus_color", "font_hover_pressed_color"]:
		t.set_color(state, "Button", TEXT)
	t.set_color("font_pressed_color", "Button", ACCENT)

	var track = box(Color(1, 1, 1, 0.1), Color(0, 0, 0, 0), 0, 4)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", box(Color(ACCENT, 0.7), Color(0, 0, 0, 0), 0, 4))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(ACCENT, Color(0, 0, 0, 0), 0, 4))
	t.set_icon("grabber", "HSlider", circle(26, TEXT))
	t.set_icon("grabber_highlight", "HSlider", circle(26, ACCENT))
	var slider_focus = box(Color(0, 0, 0, 0), Color(ACCENT, 0.55), 2, 10)
	slider_focus.expand_margin_left = 12
	slider_focus.expand_margin_right = 12
	slider_focus.expand_margin_top = 6
	slider_focus.expand_margin_bottom = 6
	t.set_stylebox("focus", "HSlider", slider_focus)
	return t


static func label(text: String, size: int, color: Color = TEXT, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	return l


static func heading(text: String, size: int = 22, color: Color = ACCENT) -> Label:
	var l = label(text, size, color)
	l.add_theme_font_override("font", spaced_font(5))
	return l


# The photo behind the menus: blurred and darkened, slow falling pieces over it, and a vignette
static func add_background(owner: Node) -> void:
	var layer = CanvasLayer.new()
	layer.layer = -1
	owner.add_child(layer)

	var photo = TextureRect.new()
	photo.texture = load("res://assets/bg.jpg")
	photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	photo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	photo.set_anchors_preset(Control.PRESET_FULL_RECT)
	if ResourceLoader.exists("res://mods/bg_blur.gdshader"):
		var blur = ShaderMaterial.new()
		blur.shader = load("res://mods/bg_blur.gdshader")
		blur.set_shader_parameter("radius", 6.0)
		blur.set_shader_parameter("dim", 0.55)
		photo.material = blur
	else:
		photo.modulate = Color(0.5, 0.5, 0.5)
	layer.add_child(photo)

	layer.add_child(preload("res://src/menu/falling_pieces.gd").new())

	var vignette = ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader = Shader.new()
	shader.code = """shader_type canvas_item;
void fragment() {
	vec2 d = (UV - 0.5) * vec2(1.0, 0.8);
	COLOR = vec4(0.0, 0.0, 0.0, 0.12 + 0.6 * smoothstep(0.25, 0.75, length(d)));
}"""
	var material = ShaderMaterial.new()
	material.shader = shader
	vignette.material = material
	layer.add_child(vignette)


# A layer for the menu itself, laid out at DESIGN_SIZE; call fit() when the window changes size
static func add_menu_layer(owner: Node) -> Array:
	var layer = CanvasLayer.new()
	owner.add_child(layer)
	var root = Control.new()
	root.size = DESIGN_SIZE
	root.theme = theme()
	layer.add_child(root)
	return [layer, root]


static func fit(layer: CanvasLayer, window_size: Vector2) -> void:
	var s = min(window_size.x / DESIGN_SIZE.x, window_size.y / DESIGN_SIZE.y)
	layer.scale = Vector2(s, s)
	layer.offset = (window_size - DESIGN_SIZE * s) / 2


# The game's own sound effects, used for the menus. The player goes on the tree's root, not the
# scene, so a sound for a button that changes the scene is not cut off with it.
static func play(owner: Node, sound: String, volume_db: float = 0.0) -> void:
	if not _sounds.has(sound):
		var path = "res://assets/sfx/%s.ogg" % sound
		if not ResourceLoader.exists(path):
			path = "res://assets/sfx/%s.wav" % sound
		_sounds[sound] = load(path)
	var player = AudioStreamPlayer.new()
	player.stream = _sounds[sound]
	player.volume_db = volume_db
	owner.get_tree().root.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)
