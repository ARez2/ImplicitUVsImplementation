shader_type spatial;
// Prevent the quad from being affected by lighting and fog. This also improves performance.
render_mode fog_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

uniform sampler2D tex;

void vertex() {
	//POSITION = vec4(VERTEX, 1.0);
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec4 col = texture(tex, vec2(SCREEN_UV.x, 1.0 - SCREEN_UV.y));
	ALBEDO = col.rgb;
	ALPHA = col.a;
}
