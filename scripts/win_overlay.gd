@tool
class_name WinOverlay
extends Control
## 中奖连线层：画在所有滚轮之上，线可以跨过滚轮间距。

const DRAW_IN_TIME := 0.22  ## 连线从左到右"划"出来的时间

var machine: SlotMachine
var wins: Array = []
var rainbow := false
var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func show_wins(list: Array, use_rainbow := false) -> void:
	wins = list
	rainbow = use_rainbow
	_t = 0.0
	queue_redraw()


func clear() -> void:
	wins = []
	queue_redraw()


func _process(delta: float) -> void:
	if wins.is_empty():
		return
	_t += delta
	queue_redraw()


func _draw() -> void:
	if wins.is_empty() or machine == null:
		return
	var pulse := 0.5 + 0.5 * sin(_t * TAU * 2.0)
	var grow := clampf(_t / DRAW_IN_TIME, 0.0, 1.0)
	for wi in wins.size():
		var w: Dictionary = wins[wi]
		var line: PackedInt32Array = w.line
		var col := SlotSymbols.color(w.symbol)
		if rainbow:
			col = Color.from_hsv(fmod(_t * 0.7 + wi * 0.17, 1.0), 0.7, 1.0)

		var pts := PackedVector2Array()
		for i in line.size():
			pts.append(machine.cell_rect(i, line[i]).get_center())
		if pts.size() >= 2:
			var ext := machine.cell_size.x * 0.55
			pts.insert(0, pts[0] + (pts[0] - pts[1]).normalized() * ext)
			pts.append(pts[-1] + (pts[-1] - pts[-2]).normalized() * ext)
		pts = _partial(pts, grow)
		if pts.size() >= 2:
			draw_polyline(pts, Color(0, 0, 0, 0.45), 24.0, true)
			draw_polyline(pts, Color(col, 0.6 + 0.35 * pulse), 15.0, true)
			draw_polyline(pts, Color(1, 1, 1, 0.9), 4.0, true)

		if grow >= 1.0:
			for i in line.size():
				var rc := machine.cell_rect(i, line[i]).grow(-6.0)
				draw_rect(rc, Color(0, 0, 0, 0.5), false, 11.0)
				draw_rect(rc, Color(col, 0.65 + 0.35 * pulse), false, 6.0)


## 只取折线的前 t（0~1）部分，用来做"划线"动画
static func _partial(pts: PackedVector2Array, t: float) -> PackedVector2Array:
	if t >= 1.0 or pts.size() < 2:
		return pts
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	var remain := total * t
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var seg := pts[i - 1].distance_to(pts[i])
		if remain >= seg:
			out.append(pts[i])
			remain -= seg
		else:
			out.append(pts[i - 1].lerp(pts[i], remain / maxf(seg, 0.001)))
			break
	return out
