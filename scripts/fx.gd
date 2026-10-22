class_name SlotFX
extends Node2D
## 粒子与冲击波：火花、星光、金币、冲击环。坐标与 SlotMachine 本地坐标一致。

const FX_DIR := "res://assets/fx/"

var _tex := {}
var _add_mat := CanvasItemMaterial.new()
var _rings: Array = []
var _showers: Array[CPUParticles2D] = []


func _ready() -> void:
	_add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = _add_mat  # 冲击环用叠加混合（子粒子各自设置材质）
	for n in ["spark", "glow", "star", "coin"]:
		var path: String = FX_DIR + n + ".png"
		_tex[n] = load(path) if ResourceLoader.exists(path) else null


## 扩散的冲击环
func ring(pos: Vector2, color: Color, radius := 220.0, duration := 0.35, width := 14.0) -> void:
	_rings.append({"pos": pos, "color": color, "r": radius, "dur": duration, "w": width, "t": 0.0})
	queue_redraw()


## 定向火花（停轮时从滚轮两侧喷出）
func sparks(pos: Vector2, dir: Vector2, color: Color, amount := 18, speed := 900.0) -> void:
	var p := _emitter(amount, 0.35, "spark", true)
	p.position = pos
	p.direction = dir
	p.spread = 38.0
	p.initial_velocity_min = speed * 0.45
	p.initial_velocity_max = speed
	p.gravity = Vector2(0, 1600)
	p.damping_min = 300.0
	p.damping_max = 700.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.3
	p.particle_flag_align_y = true
	p.color_ramp = _ramp(Color.WHITE, color)
	p.emitting = true


## 四散的星光
func burst(pos: Vector2, color: Color, amount := 20, speed := 520.0) -> void:
	var p := _emitter(amount, 0.7, "star", true)
	p.position = pos
	p.spread = 180.0
	p.initial_velocity_min = speed * 0.3
	p.initial_velocity_max = speed
	p.gravity = Vector2(0, 300)
	p.damping_min = 200.0
	p.damping_max = 400.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.6
	p.scale_amount_curve = _shrink_curve()
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	p.color_ramp = _ramp(Color.WHITE, color)
	p.emitting = true


## 金币喷泉（从下往上喷）
func coin_burst(pos: Vector2, amount := 30) -> void:
	var p := _emitter(amount, 1.6, "coin", false)
	p.position = pos
	p.direction = Vector2.UP
	p.spread = 50.0
	p.initial_velocity_min = 700.0
	p.initial_velocity_max = 1300.0
	p.gravity = Vector2(0, 1800)
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.2
	p.emitting = true


## 金币雨，持续 duration 秒
func coin_shower(area: Rect2, duration: float, rate := 60) -> void:
	var p := _emitter(int(rate * 2.2), 2.2, "coin", false)
	p.one_shot = false
	p.explosiveness = 0.0
	p.position = Vector2(area.get_center().x, area.position.y - 60.0)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(area.size.x * 0.5, 10.0)
	p.direction = Vector2.DOWN
	p.spread = 15.0
	p.initial_velocity_min = 100.0
	p.initial_velocity_max = 400.0
	p.gravity = Vector2(0, 900)
	p.angular_velocity_min = -540.0
	p.angular_velocity_max = 540.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.3
	p.emitting = true
	_showers.append(p)
	get_tree().create_timer(duration).timeout.connect(_end_shower.bind(p))


func stop_showers() -> void:
	for p in _showers.duplicate():
		_end_shower(p)


## p 不标类型：定时器回调时它可能已被释放
func _end_shower(p) -> void:
	if not is_instance_valid(p) or not _showers.has(p):
		return
	_showers.erase(p)
	p.emitting = false
	get_tree().create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)


func _emitter(amount: int, lifetime: float, tex_name: String, additive: bool) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 1.0
	p.texture = _tex.get(tex_name)
	p.material = _add_mat if additive else null
	p.finished.connect(p.queue_free)
	add_child(p)
	return p


func _ramp(from: Color, to: Color) -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	g.colors = PackedColorArray([from, to, Color(to, 0.0)])
	return g


func _shrink_curve() -> Curve:
	var c := Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	return c


func _process(delta: float) -> void:
	if _rings.is_empty():
		return
	for r in _rings:
		r.t += delta
	_rings = _rings.filter(func(r): return r.t < r.dur)
	queue_redraw()


func _draw() -> void:
	for r in _rings:
		var k: float = r.t / r.dur
		var e := 1.0 - pow(1.0 - k, 3.0)
		var col: Color = r.color
		draw_arc(r.pos, lerpf(r.r * 0.15, r.r, e), 0.0, TAU, 72, Color(col, 1.0 - k), r.w * (1.0 - 0.7 * k), true)
