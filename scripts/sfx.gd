class_name Sfx
extends Node
## 声音：背景音乐 + 池化的音效播放器（同一音效可重叠播放）+ 循环的滚轮转动声。
## 每个声音都是 Inspector 里的一个槽位，把 .wav / .ogg / .mp3 拖进去就能替换；留空 = 不播放。
## BGM 和音效分别走 "BGM"、"SFX" 两条音频总线，设置界面里的两个音量调的就是它们。

const BUS_BGM := &"BGM"
const BUS_SFX := &"SFX"
const POOL_SIZE := 24
## 默认 spin_loop.wav 里"咔嗒"声的频率（次/秒）。播放音调 = 转速 / 此值，让声音和画面同步。
const LOOP_TICK_RATE := 16.0
const LOOP_FADE_DB_PER_SEC := 900.0

@export_range(-40.0, 6.0, 0.5, "suffix:dB") var master_db := 0.0

@export_group("背景音乐")
## 背景音乐（会自动循环播放）
@export var bgm: AudioStream:
	set(v):
		bgm = v
		if v:
			_make_looping(v)
		if _bgm:
			_bgm.stream = v
## 背景音乐相对音效的基础音量
@export_range(-40.0, 6.0, 0.5, "suffix:dB") var bgm_db := -7.0

@export_group("操作")
## 按停止键
@export var press: AudioStream
## 开始转动（拉杆）
@export var lever: AudioStream
## 转动中的循环声（会自动循环播放）
@export var spin_loop: AudioStream:
	set(v):
		spin_loop = v
		if v:
			_make_looping(v)
		if _loop:
			_loop.stream = v
## 停轮重击
@export var stop: AudioStream
## 最后一列停下、中奖时叠加的低频轰击
@export var boom: AudioStream

@export_group("中奖")
## 听牌
@export var reach: AudioStream
## 小奖（Tier = NORMAL）
@export var win: AudioStream
## 中奖（Tier = BIG）
@export var win_big: AudioStream
## 大奖（Tier = JACKPOT）
@export var jackpot: AudioStream
## 金币声（随机音调连发）
@export var coin: AudioStream
## 听牌后没中
@export var miss: AudioStream

var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _loop: AudioStreamPlayer
var _loop_db := -80.0
var _loop_pitch := 1.0
var _bgm: AudioStreamPlayer
var _duck := 0.0        # 当前 BGM 被压低的分贝数
var _duck_hold := 0.0
var _duck_release := 20.0
var _closing := false   # 正在退出：不再播放任何声音


func _ready() -> void:
	_ensure_bus(BUS_BGM)
	_ensure_bus(BUS_SFX)
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		add_child(p)
		_pool.append(p)
	_loop = AudioStreamPlayer.new()
	_loop.bus = BUS_SFX
	add_child(_loop)
	_loop.stream = spin_loop
	_loop.volume_db = -80.0
	_bgm = AudioStreamPlayer.new()
	_bgm.bus = BUS_BGM
	add_child(_bgm)
	_bgm.stream = bgm
	_add_limiter()


## 停掉所有声音并不再接受新的播放（退出前调用：等音频线程释放播放实例后再退出，否则会报资源泄漏）
func stop_all() -> void:
	_closing = true
	_bgm.stop()
	_loop.stop()
	for p in _pool:
		p.stop()


func play_bgm() -> void:
	if _bgm.stream and not _bgm.playing and not _closing:
		_bgm.volume_db = bgm_db + master_db
		_bgm.play()


## 暂时压低 BGM：amount_db 压多少，hold 保持多久（秒），release_time 用多久恢复
func duck_bgm(amount_db: float, hold: float, release_time := 0.35) -> void:
	if amount_db >= _duck:
		_duck = amount_db
		_duck_release = amount_db / maxf(release_time, 0.01)
	_duck_hold = maxf(_duck_hold, hold)


## 音量 0~1（0 = 静音）
func set_bgm_volume(linear: float) -> void:
	_set_bus_volume(BUS_BGM, linear)


func set_sfx_volume(linear: float) -> void:
	_set_bus_volume(BUS_SFX, linear)


## 按槽位名播放，例如 play("stop")
func play(sound: String, pitch := 1.0, volume_db := 0.0) -> void:
	play_stream(get(sound) as AudioStream, pitch, volume_db)


func play_stream(stream: AudioStream, pitch := 1.0, volume_db := 0.0) -> void:
	if stream == null or _closing:
		return
	var p := _free_player()
	p.stream = stream
	p.pitch_scale = maxf(pitch, 0.01)
	p.volume_db = volume_db + master_db
	p.play()


## 开始转动声。立即满音量（拉杆那一下要"冲"）
func start_loop(pitch := 1.0, volume_db := -3.0) -> void:
	if _loop.stream == null or _closing:
		return
	_loop_db = volume_db
	_loop_pitch = pitch
	_loop.volume_db = volume_db + master_db
	_loop.pitch_scale = pitch
	if not _loop.playing:
		_loop.play()


func set_loop(volume_db: float, pitch: float) -> void:
	_loop_db = volume_db
	_loop_pitch = pitch


## 停止转动声（快速淡出，让最后一下重击之后突然安静）
func stop_loop() -> void:
	_loop_db = -80.0


func _process(delta: float) -> void:
	# 用真实时间：顿帧（time_scale 很小）时声音的变化不能跟着变慢
	var real := delta / maxf(Engine.time_scale, 0.001)
	if _duck_hold > 0.0:
		_duck_hold -= real
	else:
		_duck = move_toward(_duck, 0.0, _duck_release * real)
	if _bgm.playing:
		_bgm.volume_db = bgm_db + master_db - _duck
	if not _loop.playing:
		return
	_loop.volume_db = move_toward(_loop.volume_db, _loop_db + master_db, LOOP_FADE_DB_PER_SEC * real)
	_loop.pitch_scale = lerpf(_loop.pitch_scale, _loop_pitch, 1.0 - exp(-real * 12.0))
	if _loop_db <= -79.0 and _loop.volume_db <= -60.0:
		_loop.stop()


func _free_player() -> AudioStreamPlayer:
	for i in POOL_SIZE:
		var p := _pool[(_next + i) % POOL_SIZE]
		if not p.playing:
			_next = (_next + i + 1) % POOL_SIZE
			return p
	# 全忙：抢占最早的那个
	var p := _pool[_next]
	_next = (_next + 1) % POOL_SIZE
	return p


static func _make_looping(s: AudioStream) -> void:
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = roundi(w.get_length() * w.mix_rate)
	elif "loop" in s:
		s.set("loop", true)


static func _ensure_bus(bus: StringName) -> void:
	if AudioServer.get_bus_index(bus) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus)
	AudioServer.set_bus_send(idx, &"Master")


static func _set_bus_volume(bus: StringName, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return
	AudioServer.set_bus_mute(idx, linear <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.001)))


## 主总线加一个限幅器：大量音效叠加时不爆音，整体也更"紧"
static func _add_limiter() -> void:
	if not ClassDB.class_exists("AudioEffectHardLimiter"):
		return
	for i in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, i).get_class() == "AudioEffectHardLimiter":
			return
	AudioServer.add_bus_effect(0, ClassDB.instantiate("AudioEffectHardLimiter"))
