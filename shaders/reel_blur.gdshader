shader_type canvas_item;
// 滚轮高速转动时的纵向运动模糊。
// 直接对符号贴图采样，所以换图只需要一张 PNG，不需要单独准备模糊版。

// 拖影长度，以单张贴图的高度为 1（0 = 不模糊）
uniform float blur : hint_range(0.0, 1.0) = 0.0;

const int TAPS = 16;

varying vec4 vertex_color;

void vertex() {
	vertex_color = COLOR;
}

void fragment() {
	if (blur > 0.001) {
		vec4 acc = vec4(0.0);
		float wsum = 0.0;
		for (int i = 0; i < TAPS; i++) {
			float t = float(i) / float(TAPS - 1) - 0.5;
			float w = 1.0 - abs(t) * 1.5;
			vec4 c = texture(TEXTURE, UV + vec2(0.0, t * blur));
			acc += vec4(c.rgb * c.a, c.a) * w; // 预乘 alpha，透明边缘不发黑
			wsum += w;
		}
		acc /= wsum;
		COLOR = vec4(acc.rgb / max(acc.a, 0.0001), acc.a) * vertex_color;
	}
}
