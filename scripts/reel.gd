@tool
class_name Reel
extends Control
## 单列滚轮：转动、停轮回弹、绘制（圆柱弧度、运动模糊、高亮、闪白）。
## 由 SlotMachine 创建和摆放，不需要手动放进场景。
## 这里只提供"机制"；什么时候闪、震多大，由 main.gd 决定。

signal impact(reel: Reel)   ## 停轮的那一瞬间（打击点）
signal settled(reel: Reel)  ## 回弹结束，完全静止
signal clicked(reel: Reel)

enum State { IDLE, STARTING, SPINNING, STOPPING, SETTLING }

const WINDUP_TIME := 0.09   ## 起转前向上"蓄力"的时间
const WINDUP_DIST := 0.22   ## 蓄力回拉的距离（格）
const ACCEL_TIME := 0.22    ## 加速到全速的时间
const BOUNCE_DIST := 0.16   ## 停轮过冲距离（格）
const BOUNCE_FREQ := 7.5    ## 回弹频率（Hz）
const BOUNCE_DAMP := 11.0   ## 回弹衰减
const SETTLE_TIME := 0.42
const PUNCH_TIME := 0.5

var index := 0
var strip := PackedStringArray()
var rows := 3
var cell_size := Vector2(300, 210)
var spin_speed := 16.0
var curvature := 0.35
var reel_color := Color(0.98, 0.96, 0.9)
var edge_shade := 0.6
## 停轮时决定最终停在哪一格：func(reel: Reel, natural_target: float) -> float
var stop_resolver: Callable

var state := State.IDLE
var offset := 0.0    ## 当前转到的位置（格），转动时向下走
var velocity := 0.0

# —— 演出参数：外部设置，自身衰减 ——
var flash := 0.0               ## 闪白强度 0~1
var dim := 0.0                 ## 非高亮格变暗程度
var highlights := {}           ## row -> Color
var reach_glow := false
var reach_color := Color(1, 0.8, 0.2)

var _t := 0.0
var _base := 0.0
var _target := 0.0
var _stop_queued := false
var _punch_t := -1.0
var _punch_amp := 1.0
var _anim_t := 0.0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


# ---------------------------------------------------------------- 状态查询

## 结果未知（还在转，或已按停但还没到全速）
func is_spinning() -> bool:
	return state == State.STARTING or state == State.SPINNING


## 已经砸下去了（回弹中或静止）
func has_landed() -> bool:
	return state == State.SETTLING or state == State.IDLE


func can_stop() -> bool:
	return state == State.SPINNING or (state == State.STARTING and not _stop_queued)


## 最终会停的位置（停止中/回弹中返回目标，静止时返回当前位置）
func final_offset() -> float:
	return _target if state == State.STOPPING or state == State.SETTLING else offset


func symbol_at(row: int, at_offset: float) -> String:
	if strip.is_empty():
		return ""
	return strip[posmod(int(roundf(at_offset)) - row, strip.size())]


func result_symbol(row: int) -> String:
	return symbol_at(row, final_offset())


## 某一行格子的矩形（本地坐标，含圆柱弧度）
func cell_rect(row: int) -> Rect2:
	var y0 := _map_y(row)
	var y1 := _map_y(row + 1)
	return Rect2(0, y0, size.x, y1 - y0)


# ---------------------------------------------------------------- 控制

func start_spin(delay := 0.0) -> void:
	if is_spinning():
		return
	if state != State.IDLE:
		offset = _target
	offset = fposmod(roundf(offset), maxf(strip.size(), 1))
	_base = offset
	_t = -delay
	velocity = 0.0
	_stop_queued = false
	state = State.STARTING
	highlights.clear()
	dim = 0.0
	reach_glow = false


## 请求停轮。加速阶段按下会排队，到全速后立刻停。
func request_stop() -> bool:
	if not can_stop():
		return false
	if state == State.STARTING:
		_stop_queued = true
	else:
		_begin_stop()
	return true


## 冲击挤压（停轮时由外部调用，amount 越大越狠）
func punch(amount := 1.0) -> void:
	_punch_t = 0.0
	_punch_amp = amount


func _begin_stop() -> void:
	var natural := floorf(offset) + 1.0
	_target = natural
	if stop_resolver.is_valid():
		_target = maxf(natural, float(stop_resolver.call(self, natural)))
	state = State.STOPPING


func _hit() -> void:
	state = State.SETTLING
	_t = 0.0
	offset = _target
	velocity = 0.0
	impact.emit(self)


# ---------------------------------------------------------------- 更新

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_anim_t += delta
	match state:
		State.STARTING:
			_process_start(delta)
		State.SPINNING:
			velocity = spin_speed
			offset += spin_speed * delta
		State.STOPPING:
			velocity = spin_speed
			offset += spin_speed * delta
			if offset >= _target:
				_hit()
		State.SETTLING:
			_t += delta
			offset = _target + BOUNCE_DIST * exp(-BOUNCE_DAMP * _t) * sin(TAU * BOUNCE_FREQ * _t)
			if _t >= SETTLE_TIME:
				_target = fposmod(_target, strip.size())
				offset = _target
				state = State.IDLE
				settled.emit(self)
	flash = move_toward(flash, 0.0, delta * 4.0)
	_process_punch(delta)
	queue_redraw()


func _process_start(delta: float) -> void:
	_t += delta
	if _t < 0.0:
		return
	if _t < WINDUP_TIME:
		offset = _base - WINDUP_DIST * sin(_t / WINDUP_TIME * PI * 0.5)
		velocity = 0.0
		return
	var k := (_t - WINDUP_TIME) / ACCEL_TIME
	velocity = spin_speed * minf(k, 1.0)
	offset += velocity * delta
	if k >= 1.0:
		state = State.SPINNING
		if _stop_queued:
			_begin_stop()


func _process_punch(delta: float) -> void:
	if _punch_t < 0.0:
		return
	_punch_t += delta
	if _punch_t >= PUNCH_TIME:
		_punch_t = -1.0
		scale = Vector2.ONE
		return
	# 落地挤压：先变矮变宽，再弹回
	var p := _punch_amp * exp(-_punch_t * 12.0) * cos(_punch_t * TAU * 6.0)
	scale = Vector2(1.0 + 0.022 * p, 1.0 - 0.032 * p)


func _gui_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(self)
		accept_event()


# ---------------------------------------------------------------- 绘制

## 把"第 u 格的上沿"映射到屏幕 y，模拟圆柱：中间的格子高，上下边缘的格子被压扁。
func _map_y(u: float) -> float:
	var h := cell_size.y * rows
	var half_angle := curvature * 1.25
	if half_angle < 0.001:
		return u * cell_size.y
	var v := (u - rows * 0.5) / (rows * 0.5)
	var ang := clampf(v * half_angle, -PI * 0.5, PI * 0.5)
	return h * 0.5 + h * 0.5 * sin(ang) / sin(half_angle)


func _draw() -> void:
	var w := size.x
	var h := size.y
	_draw_vgradient(Rect2(0, 0, w, h * 0.5), reel_color.darkened(0.3 * edge_shade), reel_color)
	_draw_vgradient(Rect2(0, h * 0.5, w, h * 0.5), reel_color, reel_color.darkened(0.3 * edge_shade))

	if not strip.is_empty():
		var base := floorf(offset)
		var frac := offset - base
		var blur := 0.0
		if state == State.STARTING or state == State.SPINNING or state == State.STOPPING:
			blur = clampf(velocity / maxf(spin_speed, 0.01), 0.0, 1.0)
		for r in range(-1, rows):
			var id := strip[posmod(int(base) - r, strip.size())]
			_draw_cell(id, roundi(float(r) + frac), float(r) + frac, blur)

	# 圆柱明暗：上下压暗 + 一道横向高光
	var dark := Color(0, 0, 0, 0.55 * edge_shade)
	var clear := Color(0, 0, 0, 0)
	_draw_vgradient(Rect2(0, 0, w, h * 0.3), dark, clear)
	_draw_vgradient(Rect2(0, h * 0.7, w, h * 0.3), clear, dark)
	var shine := Color(1, 1, 1, 0.14)
	_draw_vgradient(Rect2(0, h * 0.30, w, h * 0.05), Color(1, 1, 1, 0), shine)
	_draw_vgradient(Rect2(0, h * 0.35, w, h * 0.05), shine, Color(1, 1, 1, 0))
	_draw_hgradient(Rect2(0, 0, 14, h), Color(0, 0, 0, 0.25), clear)
	_draw_hgradient(Rect2(w - 14, 0, 14, h), clear, Color(0, 0, 0, 0.25))

	if reach_glow:
		var p := 0.5 + 0.5 * sin(_anim_t * TAU * 3.0)
		for i in 4:
			var c := Color(reach_color, (0.75 - i * 0.17) * (0.45 + 0.55 * p))
			draw_rect(Rect2(Vector2.ZERO, size).grow(-3.0 - i * 6.0), c, false, 6.0)

	if flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, flash))


func _draw_cell(id: String, row: int, u: float, blur: float) -> void:
	var y0 := _map_y(u)
	var y1 := _map_y(u + 1.0)
	if y1 <= 0.0 or y0 >= size.y:
		return
	var cell := Rect2(0, y0, size.x, y1 - y0)
	var lit := highlights.has(row)
	var pulse := 0.5 + 0.5 * sin(_anim_t * TAU * 2.2)
	if lit:
		var hl: Color = highlights[row]
		draw_rect(cell, Color(hl, 0.25 + 0.2 * pulse))

	var sym := minf(cell_size.x * 0.8, cell_size.y * 0.86)
	var pad := (1.0 - sym / cell_size.y) * 0.5
	var sy0 := _map_y(u + pad)
	var sy1 := _map_y(u + 1.0 - pad)
	var k := 1.0 + (0.08 * pulse if lit else 0.0)
	var sz := Vector2(sym, sy1 - sy0) * k
	var rect := Rect2(Vector2(size.x * 0.5, (sy0 + sy1) * 0.5) - sz * 0.5, sz)

	var tex := SlotSymbols.texture(id)
	var tex_blur: Texture2D = SlotSymbols.texture(id, true) if blur > 0.01 else null
	if tex_blur:
		# 高速时换成纵向模糊版，并略微拉长
		draw_texture_rect(tex_blur, rect.grow_individual(0, sz.y * 0.15, 0, sz.y * 0.15), false, Color(1, 1, 1, blur))
		if tex and blur < 0.99:
			draw_texture_rect(tex, rect, false, Color(1, 1, 1, 1.0 - blur))
	elif tex:
		draw_texture_rect(tex, rect, false)
	else:
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(0, rect.get_center().y + 16), id.to_upper(), HORIZONTAL_ALIGNMENT_CENTER, size.x, 40, Color.BLACK)

	if dim > 0.0 and not lit:
		draw_rect(cell, Color(0, 0, 0, dim))


func _draw_vgradient(r: Rect2, top: Color, bottom: Color) -> void:
	draw_polygon(
		PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
		PackedColorArray([top, top, bottom, bottom])
	)


func _draw_hgradient(r: Rect2, left: Color, right: Color) -> void:
	draw_polygon(
		PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
		PackedColorArray([left, right, right, left])
	)
