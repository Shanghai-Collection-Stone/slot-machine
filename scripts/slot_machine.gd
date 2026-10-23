@tool
class_name SlotMachine
extends Control
## 拉霸机本体：只有"屏幕内容"——若干列滚轮 + 中奖连线层，没有外壳。
## 在编辑器里选中本节点即可调整列数、可见格数、间距等，改动会实时预览。

signal reel_impact(reel: Reel)
signal reel_settled(reel: Reel)
signal reel_clicked(reel: Reel)

## 滚轮列数
@export_range(1, 5) var reel_count := 3:
	set(v):
		reel_count = v
		_rebuild()
## 每列可见格数
@export_range(1, 5) var visible_rows := 3:
	set(v):
		visible_rows = v
		_rebuild()
## 滚轮之间的间距（像素）。运行时也可以用 [ ] 键调整。
@export_range(0, 1000, 1, "or_greater", "suffix:px") var reel_gap := 40.0:
	set(v):
		reel_gap = maxf(v, 0.0)
		_layout()
## 每一格的尺寸（宽 × 高）
@export var cell_size := Vector2(300, 210):
	set(v):
		cell_size = v
		_layout()
## 圆柱弧度感：0 = 平面，1 = 很弯
@export_range(0.0, 1.0, 0.01) var curvature := 0.35:
	set(v):
		curvature = v
		_apply_settings()
## 转速（格/秒），目押难度主要由它决定
@export_range(4.0, 40.0, 0.5) var spin_speed := 16.0:
	set(v):
		spin_speed = v
		_apply_settings()

@export_group("外观")
## 滚轮底色
@export var reel_color := Color(0.98, 0.96, 0.9):
	set(v):
		reel_color = v
		_apply_settings()
## 上下边缘压暗程度（圆柱立体感）
@export_range(0.0, 1.0, 0.01) var edge_shade := 0.6:
	set(v):
		edge_shade = v
		_apply_settings()

var reels: Array[Reel] = []
var overlay: WinOverlay
## 停轮落点决策（由 main 注入，用于"滑动补正"）
var stop_resolver: Callable:
	set(v):
		stop_resolver = v
		_apply_settings()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()


func _rebuild() -> void:
	if not is_node_ready():
		return
	for r in reels:
		remove_child(r)
		r.queue_free()
	reels.clear()
	if overlay:
		remove_child(overlay)
		overlay.queue_free()

	for i in reel_count:
		var reel := Reel.new()
		reel.name = "Reel%d" % (i + 1)
		reel.index = i
		reel.strip = SlotSymbols.strip(i)
		reel.rows = visible_rows
		if Engine.is_editor_hint():
			reel.offset = float((i * 7) % reel.strip.size())
		else:
			reel.offset = float(randi() % reel.strip.size())
		reel.impact.connect(reel_impact.emit)
		reel.settled.connect(reel_settled.emit)
		reel.clicked.connect(reel_clicked.emit)
		add_child(reel)
		reels.append(reel)

	overlay = WinOverlay.new()
	overlay.name = "WinOverlay"
	overlay.machine = self
	add_child(overlay)
	_apply_settings()
	_layout()


func _apply_settings() -> void:
	for r in reels:
		r.curvature = curvature
		r.spin_speed = spin_speed
		r.reel_color = reel_color
		r.edge_shade = edge_shade
		r.stop_resolver = stop_resolver
		r.queue_redraw()


func _layout() -> void:
	if not is_node_ready():
		return
	var reel_size := Vector2(cell_size.x, cell_size.y * visible_rows)
	var total := Vector2(reel_count * cell_size.x + (reel_count - 1) * reel_gap, reel_size.y)
	var origin := ((size - total) * 0.5).floor()
	for i in reels.size():
		var r := reels[i]
		r.cell_size = cell_size
		r.position = origin + Vector2(i * (cell_size.x + reel_gap), 0)
		r.size = reel_size
		r.pivot_offset = reel_size * 0.5
		r.queue_redraw()
	if overlay:
		overlay.position = Vector2.ZERO
		overlay.size = size
		overlay.queue_redraw()


# ---------------------------------------------------------------- 查询

## 中奖线：每行一条横线；行数 ≥ 2 时再加两条对角线（3×3 时就是经典 5 线）
func get_lines() -> Array[PackedInt32Array]:
	var lines: Array[PackedInt32Array] = []
	for row in visible_rows:
		var line := PackedInt32Array()
		for i in reel_count:
			line.append(row)
		lines.append(line)
	if visible_rows >= 2 and reel_count >= 2:
		var down := PackedInt32Array()
		var up := PackedInt32Array()
		for i in reel_count:
			var row := roundi(float(i) * (visible_rows - 1) / (reel_count - 1))
			down.append(row)
			up.append(visible_rows - 1 - row)
		lines.append(down)
		lines.append(up)
	return lines


## 第 reel_index 列第 row 行格子的矩形（本节点坐标）
func cell_rect(reel_index: int, row: int) -> Rect2:
	var r := reels[reel_index]
	var cr := r.cell_rect(row)
	return Rect2(r.position + cr.position, cr.size)


func reel_rect(reel_index: int) -> Rect2:
	var r := reels[reel_index]
	return Rect2(r.position, r.size)


# ---------------------------------------------------------------- 演出

## wins: [{line: PackedInt32Array, symbol: String}]
func show_wins(wins: Array, rainbow := false) -> void:
	for r in reels:
		r.highlights.clear()
		r.reach_glow = false
		r.dim = 0.45
	for w in _by_tier(wins):
		var col := SlotSymbols.color(w.symbol)
		for i in reels.size():
			reels[i].highlights[w.line[i]] = col
	overlay.show_wins(wins, rainbow)


## 听牌：已停的格子高亮，还在转的那一列发光
func show_reach(lines: Array) -> void:
	for w in _by_tier(lines):
		var col := SlotSymbols.color(w.symbol)
		for i in reels.size():
			var r := reels[i]
			if r.has_landed():
				r.highlights[w.line[i]] = col
			else:
				r.reach_glow = true
				r.reach_color = col


## 低等级在前：同一格/同一列被多条线覆盖时，最终显示高等级符号的颜色
static func _by_tier(lines: Array) -> Array:
	var sorted := lines.duplicate()
	sorted.sort_custom(func(a, b): return SlotSymbols.tier(a.symbol) < SlotSymbols.tier(b.symbol))
	return sorted


func clear_wins() -> void:
	for r in reels:
		r.highlights.clear()
		r.dim = 0.0
		r.reach_glow = false
	overlay.clear()
