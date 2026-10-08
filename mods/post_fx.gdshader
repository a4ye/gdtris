// Full screen pass for GDTris effects: camera zoom/tilt, clear shockwaves, lens bulge,
// chromatic aberration, bloom and an optional lens grade (vignette, grain, colour).
// Driven by mods/fx.gd; replaces postprocessing.gdshader on the CanvasLayer ColorRect.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

uniform float ca_base = 0.009;
uniform float ca_amount = 0.0;
uniform vec2 ca_center = vec2(0.5);
// xy = centre (screen uv), z = age in seconds, w = strength (0 = unused)
uniform vec4 wave0 = vec4(0.0);
uniform vec4 wave1 = vec4(0.0);
uniform vec4 wave2 = vec4(0.0);
uniform vec4 wave3 = vec4(0.0);
// Packet width scale of each ripple (1 = a plain T-spin double)
uniform vec4 wave_size = vec4(1.0);
uniform float bloom = 0.0;
uniform float lens = 0.0;
uniform float time = 0.0;
uniform float zoom = 1.0;
// Danger (fx.gd): red creeps in from the edges of the screen, and as it grows the picture loses
// some of its colour, so the red stands out. 0 is none, 1 is the next placement would kill.
uniform float danger = 0.0;
// Lightning (fx.gd), with the thunder of a big spike: the picture flashes a cold white. 0 is none.
uniform float flash = 0.0;
uniform vec2 tilt = vec2(0.0);

// Clear shockwave, after TETR.IO: a packet of gentle radial ripples running outward from the
// clear. Several wavelengths are on screen at once, so edges and text take on a few soft S-bends
// rather than one bulge. The packet spreads and fades as it travels, and every term is smooth,
// so nothing ever shows a hard edge or a seam.
// w = (centre.x, centre.y, age in seconds, amplitude in screen heights); size widens the packet.
// Distances are in screen heights; the furthest corner is about 1.2 away.
uniform float wave_freq = 22.0;   // radians per screen height (~0.29 height per wavelength)
uniform float wave_speed = 2.6;   // screen heights per second
uniform float wave_decay = 0.24;  // seconds

void ripple(inout vec2 uv, vec4 w, float size, float aspect) {
	if (w.w <= 0.0) {
		return;
	}
	vec2 d = uv - w.xy;
	d.x *= aspect;
	float dist = length(d);
	float front = 0.05 + w.z * wave_speed;
	float rel = dist - front;
	// The packet widens as it travels, which spreads the ripples out behind the front
	float sigma = 0.22 * size + 0.25 * w.z;
	float env = exp(-rel * rel / (2.0 * sigma * sigma));
	float amp = w.w * env * exp(-w.z / wave_decay) / (1.0 + 0.9 * front);
	if (amp < 0.00001) {
		return;
	}
	vec2 dir = dist > 0.0001 ? d / dist : vec2(0.0);
	dir.x /= aspect;
	// smoothstep: no pinch at the centre, where the direction is undefined
	uv -= dir * sin(rel * wave_freq) * amp * smoothstep(0.0, 0.05, dist);
}

void fragment() {
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 uv = SCREEN_UV;

	// Camera: zoom about the centre and a slight perspective tilt
	vec2 p = (uv - 0.5) / zoom;
	p /= 1.0 + tilt.x * p.x + tilt.y * p.y;
	uv = p + 0.5;

	ripple(uv, wave0, wave_size.x, aspect);
	ripple(uv, wave1, wave_size.y, aspect);
	ripple(uv, wave2, wave_size.z, aspect);
	ripple(uv, wave3, wave_size.w, aspect);

	vec2 dir = uv - ca_center;
	float spread = ca_base + ca_amount;
	vec3 col;
	col.r = texture(screen_tex, uv + dir * spread).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - dir * spread).b;

	// Soft halo around bright pixels; wide samples so block faces keep their bevels
	if (bloom > 0.0) {
		vec3 glow = vec3(0.0);
		for (int i = 0; i < 12; i++) {
			float a = float(i) * 0.5236 + 0.26;
			vec2 o = vec2(cos(a), sin(a)) * SCREEN_PIXEL_SIZE;
			vec3 near = texture(screen_tex, uv + o * 14.0).rgb;
			vec3 far = texture(screen_tex, uv + o * 32.0).rgb;
			glow += near * smoothstep(0.55, 1.0, max(near.r, max(near.g, near.b)));
			glow += far * smoothstep(0.55, 1.0, max(far.r, max(far.g, far.b))) * 0.7;
		}
		col += glow / 20.4 * bloom * 0.55;
	}

	col += vec3(0.7, 0.78, 1.0) * flash * 0.25;

	if (danger > 0.0) {
		vec2 dv = (SCREEN_UV - 0.5) * vec2(aspect, 1.0);
		float edge = smoothstep(0.3, 1.0, length(dv));
		float grey = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(col, vec3(grey), 0.35 * smoothstep(0.4, 1.0, danger));
		// Squared, so being near the top is a hint and the next placement killing is loud
		float d2 = danger * danger;
		col = mix(col, col * vec3(1.0, 0.5, 0.5), edge * d2 * 0.7);
		col += vec3(0.6, 0.02, 0.04) * edge * edge * d2;
	}

	if (lens > 0.0) {
		float lum = dot(col, vec3(0.299, 0.587, 0.114));
		// Cool shadows, warm highlights
		col = mix(col, col * vec3(1.04, 1.0, 0.95) + vec3(-0.012, 0.004, 0.02) * (1.0 - lum), lens);
		vec2 v = (SCREEN_UV - 0.5) * vec2(aspect, 1.0);
		col *= mix(1.0, smoothstep(1.05, 0.25, length(v)), 0.4 * lens);
		float n = fract(sin(dot(SCREEN_UV * 1000.0 + time * 61.0, vec2(12.9898, 78.233))) * 43758.5453);
		col += (n - 0.5) * 0.035 * lens;
	}

	COLOR = vec4(col, 1.0);
}
