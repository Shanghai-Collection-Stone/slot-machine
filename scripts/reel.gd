@tool
class_name Reel
extends Control
## 单列滚轮：转动、停轮回弹、待机自转、绘制（鼓面透视、运动模糊、高亮、闪白）。
## 由 SlotMachine 创建和摆放，不需要手动放进场景。
## 这里只提供"机制"；什么时候闪、震多大，由 main.gd 决定。

signal impact(reel: Reel)   ## 停轮的那一瞬间（打击点）
signal settled(reel: Reel)  ## 回弹结束，完全静止
signal clicked(reel: Reel)

enum State { IDLE, ATTRACT, STARTING, SPINNING, STOPPING, SETTLING }

const WINDUP_TIME := 0.09   ## 起转前向上"蓄力"的时间
const WINDUP_DIST := 0.22   ## 蓄力回拉的距离（格）
const ACCEL_TIME := 0.22    ## 加速到全速的时间
const BOUNCE_DIST := 0.16   ## 停轮过冲距离（格）
const BOUNCE_FREQ := 7.5    ## 回弹频率（Hz）
const BOUNCE_DAMP := 11.0   ## 回弹衰减
const SETTLE_TIME := 0.42
const PUNCH_TIME := 0.5
const BLUR_LENGTH := 0.28   ## 全速时的拖影长度（以符号高度为 1）
const BLUR_SHADER := preload("res://shaders/reel_blur.gdshader")
const DRUM_SLICES := 32     ## 鼓面切片数（越多越圆滑）
const SYMBOL_SLICES := 10   ## 每个符号切片数（让图片跟着鼓面弯曲）
const EDGE_WIDTH := 16.0    ## 左右边缘压暗的宽度

var index := 0
var strip: Array[SlotSymbol] = []
var rows := 3
var cell_size := Vector2(300, 210)
var spin_speed := 16.0
var attract_speed := 1.6
var curvature := 0.8
var reel_color := Color(0.98, 0.96, 0.9)
var edge_shade := 0.75
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
var _blur_mat := ShaderMaterial.new()


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_blur_mat.shader = BLUR_SHADER
	material = _blur_mat


# ---------------------------------------------------------------- 状态查询

## 结果未知（还在转，或已按停但还没到全速）
func is_spinning() -> bool:
	return state == State.STARTING or state == State.SPINNING


## 已经砸下去了（回弹中或静止）
func has_landed() -> bool:
	return state == State.SETTLING or state == State.IDLE


## 没有在进行一局（静止或待机自转）
func is_resting() -> bool:
	return state == State.IDLE or state == State.ATTRACT


func can_stop() -> bool:
	return state == State.SPINNING or (state == State.STARTING and not _stop_queued)


## 最终会停的位置（停止中/回弹中返回目标，静止时返回当前位置）
func final_offset() -> float:
	return _target if state == State.STOPPING or state == State.SETTLING else offset


func symbol_at(row: int, at_offset: float) -> SlotSymbol:
	if strip.is_empty():
		return null
	return strip[posmod(int(roundf(at_offset)) - row, strip.size())]


func result_symbol(row: int) -> SlotSymbol:
	return symbol_at(row, final_offset())


## 某一行格子的矩形（本地坐标）：高度跟随鼓面弧度，宽度取该格中线处的透视宽度
func cell_rect(row: int) -> Rect2:
	var y0 := _map_y(row)
	var y1 := _map_y(row + 1)
	var hw := _half_width(row + 0.5)
	return Rect2(size.x * 0.5 - hw, y0, hw * 2.0, y1 - y0)


# ---------------------------------------------------------------- 控制

func start_spin(delay := 0.0) -> void:
	if is_spinning():
		return
	if state == State.STOPPING or state == State.SETTLING:
		offset = _target
	if state != State.ATTRACT:
		offset = roundf(offset)
	offset = fposmod(offset, maxf(strip.size(), 1))
	_base = offset
	_t = -delay
	velocity = 0.0
	_stop_queued = false
	state = State.STARTING
	_clear_marks()


## 待机自转：慢慢加速到 attract_speed 后一直匀速滚
func start_attract(delay := 0.0) -> void:
	if is_spinning() or state == State.STOPPING or state == State.ATTRACT:
		return
	if state == State.SETTLING:
		offset = _target
	_t = -delay
	velocity = 0.0
	state = State.ATTRACT
	_clear_marks()


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


func _clear_marks() -> void:
	highlights.clear()
	dim = 0.0
	reach_glow = false


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
		State.ATTRACT:
			_t += delta
			if _t >= 0.0:
				velocity = move_toward(velocity, attract_speed, attract_speed * 1.5 * delta)
				offset = fposmod(offset + velocity * delta, maxf(strip.size(), 1))
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


# ---------------------------------------------------------------- 鼓面几何
# 把滚轮当成一个横放的圆筒，正对着屏幕。u = 从上往下第几格（可以是小数）。
# 中间一格离眼睛最近：最高、最宽、最亮；越往上下越远：被压扁、变窄、变暗。

func _half_angle() -> float:
	return curvature * 1.1


func _perspective() -> float:
	return curvature * 0.45


func _theta(u: float) -> float:
	return (u - rows * 0.5) / (rows * 0.5) * _half_angle()


## 透视缩放（中间 = 1，越靠边越小）。窗口外按边缘处理。
func _depth_scale(theta: float) -> float:
	var t := clampf(theta, -_half_angle(), _half_angle())
	return 1.0 / (1.0 + _perspective() * (1.0 - cos(t)))


func _half_width(u: float) -> float:
	return size.x * 0.5 * _depth_scale(_theta(u))


## 亮度：中间 1，往上下边缘按 edge_shade 变暗
func _light(u: float) -> float:
	var c := cos(clampf(_theta(u), -PI * 0.5, PI * 0.5))
	return clampf(1.0 - edge_shade * 1.4 * pow(1.0 - c, 0.75), 0.15, 1.0)


func _map_y(u: float) -> float:
	var h := cell_size.y * rows
	var half := _half_angle()
	if half < 0.001:
		return u * cell_size.y
	var p := _perspective()
	var s_edge := _depth_scale(half)
	var k := (h * 0.5) / (sin(half) * s_edge)
	var th := _theta(u)
	var a := absf(th)
	var y: float
	if a <= half:
		y = k * sin(a) * _depth_scale(a)
	else:
		# 窗口外：沿边缘的斜率继续延伸，保证单调（反正会被裁掉）
		var slope := k * (cos(half) * (1.0 + p) - p) * s_edge * s_edge
		y = h * 0.5 + (a - half) * maxf(slope, k * 0.2)
	return h * 0.5 + signf(th) * y


# ---------------------------------------------------------------- 绘制

func _draw() -> void:
	var blur := 0.0
	if state == State.STARTING or state == State.SPINNING or state == State.STOPPING:
		blur = clampf(velocity / maxf(spin_speed, 0.01), 0.0, 1.0)
	_blur_mat.set_shader_parameter("blur", BLUR_LENGTH * blur)

	_draw_band(0.0, rows, reel_color, reel_color, DRUM_SLICES, true)

	if not strip.is_empty():
		var base := floorf(offset)
		var frac := offset - base
		for r in range(-1, rows):
			var sym := strip[posmod(int(base) - r, strip.size())]
			_draw_cell(sym, roundi(float(r) + frac), float(r) + frac, blur)

	# 鼓面高光：中线稍上方一道横向反光
	var mid := rows * 0.5
	var shine := Color(1, 1, 1, 0.28)
	var none := Color(1, 1, 1, 0)
	_draw_band(mid - 0.62, mid - 0.4, none, shine, 6)
	_draw_band(mid - 0.4, mid - 0.18, shine, none, 6)
	_draw_side_shade()

	if reach_glow:
		var p := 0.5 + 0.5 * sin(_anim_t * TAU * 3.0)
		for i in 4:
			var c := Color(reach_color, (0.75 - i * 0.17) * (0.45 + 0.55 * p))
			draw_polyline(_silhouette(3.0 + i * 6.0), c, 6.0)

	if flash > 0.0:
		_draw_band(0.0, rows, Color(1, 1, 1, flash), Color(1, 1, 1, flash), 12)


func _draw_cell(sym: SlotSymbol, row: int, u: float, blur: float) -> void:
	if _map_y(u + 1.0) <= 0.0 or _map_y(u) >= size.y:
		return
	var lit := highlights.has(row)
	var pulse := 0.5 + 0.5 * sin(_anim_t * TAU * 2.2)
	if lit:
		var hl: Color = highlights[row]
		var c := Color(hl, 0.25 + 0.2 * pulse)
		_draw_band(u, u + 1.0, c, c, 8)

	var tex: Texture2D = sym.texture if sym else null
	# 按图片比例缩放进格子（留一点边）
	var box := Vector2(cell_size.x * 0.8, cell_size.y * 0.86) * (sym.size_scale if sym else 1.0)
	var tex_size := tex.get_size() if tex else box
	var fit := minf(box.x / maxf(tex_size.x, 1.0), box.y / maxf(tex_size.y, 1.0))
	var draw_size := tex_size * fit
	var k := 1.0 + (0.08 * pulse if lit else 0.0)
	var uc := u + 0.5
	var half_u := draw_size.y / cell_size.y * 0.5 * k
	half_u += half_u * 0.3 * blur  # 高速时略微拉长，配合着色器的纵向模糊

	if tex:
		_draw_symbol(tex, uc - half_u, uc + half_u, draw_size.x * 0.5 * k)
	elif sym and blur < 0.3:
		var font := ThemeDB.fallback_font
		var fs := int(40 * _depth_scale(_theta(uc)))
		var y := _map_y(uc) + fs * 0.35
		draw_string(font, Vector2(0, y), sym.label(), HORIZONTAL_ALIGNMENT_CENTER, size.x, fs, Color(0, 0, 0, _light(uc)))

	if dim > 0.0 and not lit:
		_draw_band(u, u + 1.0, Color(0, 0, 0, dim), Color(0, 0, 0, dim), 8)


## 符号贴图按切片贴到鼓面上：越靠上下越扁、越窄、越暗
func _draw_symbol(tex: Texture2D, u0: float, u1: float, half_w: float) -> void:
	var cx := size.x * 0.5
	for j in SYMBOL_SLICES:
		var a := lerpf(u0, u1, float(j) / SYMBOL_SLICES)
		var b := lerpf(u0, u1, float(j + 1) / SYMBOL_SLICES)
		var ya := _map_y(a)
		var yb := _map_y(b)
		if yb <= 0.0 or ya >= size.y:
			continue
		var wa := half_w * _depth_scale(_theta(a))
		var wb := half_w * _depth_scale(_theta(b))
		var la := _light(a)
		var lb := _light(b)
		var va := float(j) / SYMBOL_SLICES
		var vb := float(j + 1) / SYMBOL_SLICES
		draw_polygon(
			PackedVector2Array([Vector2(cx - wa, ya), Vector2(cx + wa, ya), Vector2(cx + wb, yb), Vector2(cx - wb, yb)]),
			PackedColorArray([Color(la, la, la), Color(la, la, la), Color(lb, lb, lb), Color(lb, lb, lb)]),
			PackedVector2Array([Vector2(0, va), Vector2(1, va), Vector2(1, vb), Vector2(0, vb)]),
			tex
		)


## 沿鼓面画一条横带（u0~u1），颜色从 c0 渐变到 c1；lit = 叠加鼓面明暗
func _draw_band(u0: float, u1: float, c0: Color, c1: Color, slices: int, lit := false) -> void:
	var cx := size.x * 0.5
	for i in slices:
		var ta := float(i) / slices
		var tb := float(i + 1) / slices
		var a := lerpf(u0, u1, ta)
		var b := lerpf(u0, u1, tb)
		var ya := _map_y(a)
		var yb := _map_y(b)
		if yb <= 0.0 or ya >= size.y:
			continue
		var wa := _half_width(a)
		var wb := _half_width(b)
		var ca := c0.lerp(c1, ta)
		var cb := c0.lerp(c1, tb)
		if lit:
			var la := _light(a)
			var lb := _light(b)
			ca = Color(ca.r * la, ca.g * la, ca.b * la, ca.a)
			cb = Color(cb.r * lb, cb.g * lb, cb.b * lb, cb.a)
		draw_polygon(
			PackedVector2Array([Vector2(cx - wa, ya), Vector2(cx + wa, ya), Vector2(cx + wb, yb), Vector2(cx - wb, yb)]),
			PackedColorArray([ca, ca, cb, cb])
		)


## 左右边缘压暗，加强圆柱感
func _draw_side_shade() -> void:
	var cx := size.x * 0.5
	var dark := Color(0, 0, 0, 0.3 * edge_shade + 0.1)
	var clear := Color(0, 0, 0, 0)
	for i in DRUM_SLICES:
		var a := float(rows) * i / DRUM_SLICES
		var b := float(rows) * (i + 1) / DRUM_SLICES
		var ya := _map_y(a)
		var yb := _map_y(b)
		var wa := _half_width(a)
		var wb := _half_width(b)
		for side: float in [-1.0, 1.0]:
			var oa := cx + side * wa
			var ob := cx + side * wb
			var ia := cx + side * (wa - EDGE_WIDTH)
			var ib := cx + side * (wb - EDGE_WIDTH)
			draw_polygon(
				PackedVector2Array([Vector2(oa, ya), Vector2(ia, ya), Vector2(ib, yb), Vector2(ob, yb)]),
				PackedColorArray([dark, clear, clear, dark])
			)


## 鼓面轮廓（闭合折线），inset = 向内缩进的像素
func _silhouette(inset: float) -> PackedVector2Array:
	var cx := size.x * 0.5
	var h := cell_size.y * rows
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in DRUM_SLICES + 1:
		var u := float(rows) * i / DRUM_SLICES
		var y := clampf(_map_y(u), inset, h - inset)
		var w := _half_width(u) - inset
		left.append(Vector2(cx - w, y))
		right.append(Vector2(cx + w, y))
	right.reverse()
	var pts := left + right
	pts.append(pts[0])
	return pts
