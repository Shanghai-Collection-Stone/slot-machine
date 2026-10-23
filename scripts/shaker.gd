class_name ScreenShaker
extends Control
## 屏幕震动：trauma 抖动 + 弹簧冲击位移 + 缩放冲击。作用于所有子节点（滚轮和粒子）。

@export var max_offset := 26.0       ## trauma = 1 时的最大抖动（像素）
@export var max_roll_deg := 1.2      ## trauma = 1 时的最大旋转（度）
@export var trauma_decay := 1.8      ## 每秒衰减量
@export_range(0.0, 2.0, 0.05) var strength := 1.0

const STIFFNESS := 700.0
const DAMPING := 22.0

var trauma := 0.0
var _kick := Vector2.ZERO
var _kick_vel := Vector2.ZERO
var _zoom := 0.0
var _zoom_vel := 0.0
var _noise := FastNoiseLite.new()
var _t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0


## 持续抖动（叠加，最大 1）
func add_trauma(amount: float) -> void:
	trauma = minf(trauma + amount * strength, 1.0)


## 方向性冲击：给一个速度冲量，弹簧会把画面拉回原位
func kick(impulse: Vector2) -> void:
	_kick_vel += impulse * strength


## 缩放冲击：正数 = 先放大再弹回
func zoom_punch(amount: float) -> void:
	_zoom_vel += amount * strength


func _process(delta: float) -> void:
	_t += delta
	trauma = maxf(trauma - trauma_decay * delta, 0.0)
	_kick_vel += (-STIFFNESS * _kick - DAMPING * _kick_vel) * delta
	_kick += _kick_vel * delta
	_zoom_vel += (-STIFFNESS * _zoom - DAMPING * _zoom_vel) * delta
	_zoom += _zoom_vel * delta

	var s := trauma * trauma
	var n := _t * 38.0
	var shake := Vector2(_noise.get_noise_2d(n, 0.0), _noise.get_noise_2d(0.0, n + 100.0)) * max_offset * s
	pivot_offset = size * 0.5
	position = shake + _kick
	rotation = deg_to_rad(max_roll_deg) * s * _noise.get_noise_2d(n + 200.0, n)
	scale = Vector2.ONE * (1.0 + _zoom)
