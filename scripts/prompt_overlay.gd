@tool
class_name PromptOverlay
extends Control
## 待机提示层：每一列中间一块半透明小遮罩，上面写"请开始"，呼吸闪烁。

const FADE_TIME := 0.35

var machine: SlotMachine
var text := "请开始"
var _alpha := 0.0
var _target := 0.0
var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_prompt(on: bool, instant := false) -> void:
	_target = 1.0 if on else 0.0
	if instant:
		_alpha = _target
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	var before := _alpha
	_alpha = move_toward(_alpha, _target, delta / FADE_TIME)
	if _alpha > 0.0 or before > 0.0:  # 淡到 0 的那一帧也要重画，否则会残留最后一帧
		queue_redraw()


func _draw() -> void:
	if _alpha <= 0.0 or machine == null or machine.reels.is_empty():
		return
	var breathe := 0.5 + 0.5 * sin(_t * TAU * 0.8)
	var font := get_theme_default_font()
	var fs := maxi(int(machine.cell_size.y * 0.21), 12)
	var row := floori(machine.visible_rows / 2.0)
	for i in machine.reels.size():
		var cell := machine.cell_rect(i, row)
		var w := cell.size.x * 0.86
		var h := minf(cell.size.y * 0.48, fs * 2.2)
		var box := Rect2(cell.get_center() - Vector2(w, h) * 0.5, Vector2(w, h))
		_draw_round_box(box, Color(0.03, 0.02, 0.06, 0.82 * _alpha), Color(1.0, 0.82, 0.35, (0.35 + 0.6 * breathe) * _alpha))
		var baseline := box.get_center().y + fs * 0.36
		var col := Color(1.0, 0.93, 0.6).lerp(Color.WHITE, breathe) * Color(1, 1, 1, _alpha)
		draw_string_outline(font, Vector2(box.position.x, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, box.size.x, fs, 10, Color(0, 0, 0, 0.9 * _alpha))
		draw_string(font, Vector2(box.position.x, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, box.size.x, fs, col)


func _draw_round_box(r: Rect2, fill: Color, border: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(int(r.size.y * 0.3))
	sb.anti_aliasing = true
	draw_style_box(sb, r)
