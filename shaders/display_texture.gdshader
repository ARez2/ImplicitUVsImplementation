shader_type spatial;
// Prevent the quad from being affected by lighting and fog. This also improves performance.
render_mode unshaded, fog_disabled, depth_draw_opaque;

uniform sampler2D tex;
uniform sampler2D depth_tex : filter_nearest, repeat_disable;
uniform bool display_depth = false;

void vertex() {
	//POSITION = vec4(VERTEX, 1.0);
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 uv = vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y);
	float view_depth = texture(depth_tex, uv).r;
	if (view_depth <= 0.0) {
	    discard;
	}
	vec4 col = texture(tex, uv);
	if (col.a < 0.001) {
        discard;
    }
	ALBEDO = col.rgb;
	
	vec4 clip = PROJECTION_MATRIX * vec4(0.0, 0.0, -view_depth, 1.0);
	DEPTH = clip.z / clip.w;
	
	if (display_depth) {
		ALBEDO = vec3(clamp(view_depth / 10.0, 0.0, 1.0));
	}
}