// Blurred, darker background so the board stands out (fx preset "all").
// Set on the CanvasLayer2/TextureRect by mods/fx.gd.
shader_type canvas_item;

uniform float radius = 2.5;
uniform float dim = 0.8;

void fragment() {
	vec2 texel = TEXTURE_PIXEL_SIZE * radius;
	vec3 sum = vec3(0.0);
	float weight = 0.0;
	for (int x = -3; x <= 3; x++) {
		for (int y = -3; y <= 3; y++) {
			float k = exp(-float(x * x + y * y) / 6.0);
			sum += texture(TEXTURE, UV + vec2(float(x), float(y)) * texel).rgb * k;
			weight += k;
		}
	}
	COLOR = vec4(sum / weight * dim, 1.0);
}
