extends Control
## 游戏流程与"打击感"演出。
## 启动后是待机画面（滚轮自己慢慢滚，每列显示"请开始"），闲置一段时间后也会回到待机。
## 空格 / 回车 / 点击：开始（转动中再按 = 从左到右停下一列）
## Z X C、1 2 3、← ↓ → 或点击滚轮：停对应的列
## Esc / F2：设置    F1：帮助    F11：全屏

enum Phase { ATTRACT, IDLE, SPINNING, RESULT }

## 项目设置 → 输入映射 里已定义的同名动作优先，这里只补缺。
const KEYS := {
	"slot_start": [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER],
	"slot_stop_1": [KEY_Z, KEY_1, KEY_LEFT],
	"slot_stop_2": [KEY_X, KEY_2, KEY_DOWN],
	"slot_stop_3": [KEY_C, KEY_3, KEY_RIGHT],
	"slot_stop_4": [KEY_V, KEY_4],
	"slot_stop_5": [KEY_B, KEY_5],
	"slot_settings": [KEY_ESCAPE, KEY_F2],
	"slot_help": [KEY_F1, KEY_H],
	"slot_fullscreen": [KEY_F11],
}
const JOY_BUTTONS := {
	"slot_start": [JOY_BUTTON_A, JOY_BUTTON_START],
	"slot_stop_1": [JOY_BUTTON_X, JOY_BUTTON_DPAD_LEFT],
	"slot_stop_2": [JOY_BUTTON_Y, JOY_BUTTON_DPAD_DOWN],
	"slot_stop_3": [JOY_BUTTON_B, JOY_BUTTON_DPAD_RIGHT],
	"slot_settings": [JOY_BUTTON_BACK],
}

@export_group("目押补正")
## 停轮时最多允许多"滑"几格去凑连线/听牌（0 = 纯目押，按哪停哪）
@export_range(0, 4) var assist_slip := 2
## 能凑成时，实际去凑的概率
@export_range(0.0, 1.0, 0.05) var assist_chance := 0.35

@export_group("打击感")
## 震屏强度倍率（0 = 关闭）
@export_range(0.0, 2.0, 0.05) var shake_strength := 1.0:
	set(v):
		shake_strength = v
		if is_node_ready():
			shaker.strength = v
## 中奖瞬间的顿帧
@export var hitstop := true
## 手柄震动
@export var gamepad_rumble := true

@export_group("待机")
## 一局结束后闲置多少秒回到待机画面（0 = 不回）
@export_range(0.0, 600.0, 1.0, "suffix:s") var attract_delay := 15.0

@onready var machine: SlotMachine = $ShakeRoot/SlotMachine
@onready var shaker: ScreenShaker = $ShakeRoot
@onready var fx: SlotFX = $ShakeRoot/FX
@onready var sfx: Sfx = $Sfx
@onready var background: ColorRect = $Background
@onready var flash_rect: ColorRect = $Flash
@onready var toast: Label = $Toast
@onready var help: Label = $Help

var phase := Phase.IDLE
var settings_panel: SettingsPanel
var _settings: GameSettings
var _defaults: GameSettings
var _idle_t := 0.0
var _applied_sfx := -1.0
var _stops := 0
var _spin_id := 0
var _reached := false
var _bg_color: Color
var _flash_tween: Tween
var _toast_tween: Tween
var _bg_tween: Tween


func _ready() -> void:
	_setup_input()
	_bg_color = background.color
	shaker.strength = shake_strength
	flash_rect.color = Color(1, 1, 1, 0)
	toast.modulate.a = 0.0
	machine.stop_resolver = _resolve_stop
	machine.reel_impact.connect(_on_reel_impact)
	machine.reel_clicked.connect(_on_reel_clicked)

	# 设置：场景里 Inspector 上的值是默认值，保存过的设置覆盖它
	_defaults = GameSettings.new()
	_defaults.reel_gap = machine.reel_gap
	_defaults.spin_speed = machine.spin_speed
	_settings = GameSettings.load_or(_defaults)
	_apply_settings(_settings)
	settings_panel = SettingsPanel.new()
	settings_panel.name = "SettingsPanel"
	add_child(settings_panel)
	settings_panel.preview.connect(_apply_settings)
	settings_panel.saved.connect(_on_settings_saved)
	settings_panel.cancelled.connect(_apply_settings)

	sfx.play_bgm()
	_enter_attract(true)
	get_tree().auto_accept_quit = false  # 关窗口时先收掉声音再退出，见 quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit()


## 先停掉所有声音，等音频线程释放播放中的 BGM，再退出（直接退出会在输出里报资源泄漏）
func quit() -> void:
	sfx.stop_all()
	await get_tree().create_timer(0.3, true, false, true).timeout
	get_tree().quit()


func _setup_input() -> void:
	for action in KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in KEYS[action]:
			var e := InputEventKey.new()
			e.physical_keycode = key
			InputMap.action_add_event(action, e)
		for button in JOY_BUTTONS.get(action, []):
			var j := InputEventJoypadButton.new()
			j.button_index = button
			InputMap.action_add_event(action, j)


## 任何操作都重置闲置计时
func _input(event: InputEvent) -> void:
	if event.is_pressed():
		_idle_t = 0.0


func _process(delta: float) -> void:
	if attract_delay <= 0.0 or settings_panel.is_open():
		return
	if phase == Phase.IDLE or phase == Phase.RESULT:
		_idle_t += delta
		if _idle_t >= attract_delay:
			_enter_attract()


func _unhandled_input(event: InputEvent) -> void:
	if settings_panel.is_open():
		return
	if event.is_action_pressed("slot_start"):
		_on_lever()
	elif event.is_action_pressed("slot_settings"):
		_open_settings()
	elif event.is_action_pressed("slot_help"):
		help.visible = not help.visible
	elif event.is_action_pressed("slot_fullscreen"):
		var win := get_window()
		win.mode = Window.MODE_WINDOWED if win.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_lever()
	else:
		for i in mini(machine.reels.size(), 5):
			if event.is_action_pressed("slot_stop_%d" % (i + 1)):
				_stop_reel(i)
				get_viewport().set_input_as_handled()
		return
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- 流程

func _on_lever() -> void:
	if phase == Phase.SPINNING:
		for r in machine.reels:
			if r.can_stop():
				_stop_reel(r.index)
				return
	else:
		_start_spin()


func _on_reel_clicked(reel: Reel) -> void:
	if phase == Phase.SPINNING:
		_stop_reel(reel.index)
	else:
		_start_spin()


## 待机：滚轮自己慢慢滚，每列显示"请开始"
func _enter_attract(instant := false) -> void:
	phase = Phase.ATTRACT
	_reset_presentation()
	sfx.stop_loop()
	machine.start_attract()
	machine.show_prompt(true, instant)


## 收掉上一局的所有演出（中奖高亮、金币雨、背景闪烁、顿帧）
func _reset_presentation() -> void:
	_spin_id += 1
	_idle_t = 0.0
	Engine.time_scale = 1.0
	machine.clear_wins()
	fx.stop_showers()
	if _bg_tween:
		_bg_tween.kill()
	background.color = _bg_color


func _start_spin() -> void:
	_reset_presentation()
	phase = Phase.SPINNING
	_stops = 0
	_reached = false
	machine.show_prompt(false)

	sfx.play("lever")
	sfx.start_loop(machine.spin_speed / Sfx.LOOP_TICK_RATE)
	shaker.kick(Vector2(0, -260))
	shaker.add_trauma(0.12)
	_rumble(0.2, 0.0, 0.08)
	for r in machine.reels:
		r.start_spin(r.index * 0.06)


func _stop_reel(i: int) -> void:
	if phase != Phase.SPINNING or i >= machine.reels.size():
		return
	if machine.reels[i].request_stop():
		sfx.play("press", randf_range(0.96, 1.04))


## 停轮落点：natural 是"按下那一刻的下一格"。在 assist_slip 格内能凑成线/听牌时，按概率滑过去。
func _resolve_stop(reel: Reel, natural: float) -> float:
	if assist_slip <= 0 or machine.reels.size() < 2:
		return natural
	var others := 0
	for r in machine.reels:
		if r != reel and r.is_spinning():
			others += 1
	if others > 1 or randf() >= assist_chance:
		return natural
	for k in assist_slip + 1:
		if not _match_lines(others, reel, natural + k).is_empty():
			return natural + k
	return natural


## 计算成立的线：已知列的符号全部相同，且未知（还在转）的列数 == unknown_needed。
## unknown_needed = 0 → 中奖线；= 1 → 听牌线。
## hypo / hypo_offset：假设某列停在某处（用于补正）。landed_only：只把已经砸下去的列算作已知。
func _match_lines(unknown_needed: int, hypo: Reel = null, hypo_offset := 0.0, landed_only := false) -> Array:
	var result := []
	if machine.reels.size() < 2:
		return result
	for line in machine.get_lines():
		var sym: SlotSymbol = null
		var ok := true
		var unknown := 0
		for i in machine.reels.size():
			var r := machine.reels[i]
			var s: SlotSymbol
			if r == hypo:
				s = r.symbol_at(line[i], hypo_offset)
			elif r.is_spinning() or (landed_only and not r.has_landed()):
				unknown += 1
				continue
			else:
				s = r.result_symbol(line[i])
			if s == null or not s.pays() or (sym != null and s != sym):
				ok = false
				break
			sym = s
		if ok and unknown == unknown_needed and sym != null:
			result.append({"line": line, "symbol": sym})
	return result


# ---------------------------------------------------------------- 打击感

func _on_reel_impact(reel: Reel) -> void:
	if phase != Phase.SPINNING:
		return
	_stops += 1
	var moving := 0
	for r in machine.reels:
		if not r.has_landed():
			moving += 1
	var last := moving == 0
	var heavy := 1.6 if last else 1.0

	sfx.play("stop", 1.0 - 0.035 * (_stops - 1) + randf_range(-0.015, 0.015))
	sfx.duck_bgm(10.0 if last else 6.0, 0.06, 0.4)  # 重击瞬间压一下 BGM，打击更突出
	if last:
		sfx.play("boom", 1.0, -5.0)
		sfx.stop_loop()
	else:
		var level := float(moving) / machine.reels.size()
		sfx.set_loop(linear_to_db(0.35 + 0.65 * level) - 3.0, machine.spin_speed / Sfx.LOOP_TICK_RATE * (1.0 - 0.03 * _stops))

	reel.punch(heavy)
	reel.flash = 0.75 if last else 0.55
	shaker.add_trauma(0.28 * heavy)
	shaker.kick(Vector2(0, 520 * heavy))
	if last:
		shaker.zoom_punch(0.35)
	_rumble(0.4 * heavy, 0.7 * heavy, 0.12)

	var rect := machine.reel_rect(reel.index)
	var mid := rect.get_center()
	var spark_col := Color(1.0, 0.75, 0.35)
	fx.sparks(Vector2(rect.position.x, mid.y), Vector2.LEFT, spark_col, int(14 * heavy))
	fx.sparks(Vector2(rect.end.x, mid.y), Vector2.RIGHT, spark_col, int(14 * heavy))
	fx.ring(mid, Color(1.0, 0.9, 0.6, 0.8), rect.size.y * 0.55 * heavy, 0.32, 12.0)

	if last:
		_on_all_stopped()
	elif moving == 1:
		_check_reach()


func _check_reach() -> void:
	if _reached:
		return
	var lines := _match_lines(1, null, 0.0, true)
	if lines.is_empty():
		return
	_reached = true
	var top := _top_symbol(lines)
	var big := top.tier == SlotSymbol.Tier.JACKPOT
	machine.show_reach(lines)
	sfx.duck_bgm(6.0, 1.0, 0.6)
	sfx.play("reach", 1.06 if big else 1.0)
	sfx.set_loop(0.0, machine.spin_speed / Sfx.LOOP_TICK_RATE * 1.08)  # 紧张感：转动声变大变尖
	shaker.add_trauma(0.25 if big else 0.15)
	_flash(top.color, 0.45 if big else 0.22, 0.4)
	_rumble(0.3, 0.2, 0.2)


func _on_all_stopped() -> void:
	var wins := _match_lines(0)
	if wins.is_empty():
		phase = Phase.IDLE
		machine.clear_wins()
		if _reached:
			sfx.play("miss")
		return
	phase = Phase.RESULT
	var top := _top_symbol(wins)
	var id := _spin_id
	if hitstop:
		await _hitstop(0.05 + 0.04 * top.tier)
		if id != _spin_id:
			return
	_celebrate(wins, top)


## 多条线同时成立时，取中奖等级最高的符号来决定演出
func _top_symbol(lines: Array) -> SlotSymbol:
	var top: SlotSymbol = lines[0].symbol
	for l in lines:
		if l.symbol.tier > top.tier:
			top = l.symbol
	return top


func _hitstop(duration: float) -> void:
	Engine.time_scale = 0.03
	await get_tree().create_timer(duration, true, false, true).timeout
	Engine.time_scale = 1.0


func _celebrate(wins: Array, top: SlotSymbol) -> void:
	var tier := top.tier
	machine.show_wins(wins, tier == SlotSymbol.Tier.JACKPOT)
	var main_col := top.color
	if top.win_sound:
		sfx.play_stream(top.win_sound)
	for w in wins:
		var col: Color = w.symbol.color
		for i in machine.reels.size():
			var c := machine.cell_rect(i, w.line[i]).get_center()
			fx.burst(c, col, 14 + 10 * tier)
			fx.ring(c, col, 150.0 + 40.0 * tier, 0.45, 10.0)

	var area := Rect2(Vector2.ZERO, machine.size)
	sfx.duck_bgm(9.0 + 3.5 * tier, 1.2 + 1.3 * tier, 1.2)  # 中奖音乐期间 BGM 让位
	match tier:
		SlotSymbol.Tier.NORMAL:
			if not top.win_sound:
				sfx.play("win")
			shaker.add_trauma(0.3)
			shaker.zoom_punch(0.25)
			_flash(main_col, 0.25, 0.3)
			_coins(6, 0.6)
			_rumble(0.3, 0.3, 0.2)
		SlotSymbol.Tier.BIG:
			if not top.win_sound:
				sfx.play("win_big")
			sfx.play("boom", 0.9, -4.0)
			shaker.add_trauma(0.6)
			shaker.zoom_punch(0.5)
			_flash(Color.WHITE, 0.5, 0.45)
			fx.coin_burst(Vector2(area.get_center().x, area.end.y), 40)
			_coins(16, 1.2)
			_rumble(0.6, 0.8, 0.35)
		_:
			if not top.win_sound:
				sfx.play("jackpot")
			sfx.play("boom", 0.8)
			shaker.add_trauma(1.0)
			shaker.zoom_punch(0.9)
			_flash(Color.WHITE, 0.9, 0.8)
			fx.coin_burst(Vector2(area.get_center().x, area.end.y), 60)
			fx.coin_shower(area, 3.0)
			_coins(45, 3.2)
			_rumble(1.0, 1.0, 0.6)
			_jackpot_pulse()


## 777：背景和滚轮跟着节奏闪
func _jackpot_pulse() -> void:
	if _bg_tween:
		_bg_tween.kill()
	_bg_tween = create_tween().set_loops(8)
	_bg_tween.tween_callback(_jackpot_beat)
	_bg_tween.tween_property(background, "color", _bg_color.lerp(Color(0.55, 0.08, 0.05), 0.7), 0.08)
	_bg_tween.tween_property(background, "color", _bg_color, 0.22)


func _jackpot_beat() -> void:
	for r in machine.reels:
		r.flash = 0.45
	shaker.add_trauma(0.15)


## 金币声"哗啦啦"：在 duration 内随机时刻、随机音调连发
func _coins(count: int, duration: float) -> void:
	for i in count:
		get_tree().create_timer(randf() * duration).timeout.connect(_coin_tick.bind(_spin_id))


func _coin_tick(spin_id: int) -> void:
	if spin_id == _spin_id:
		sfx.play("coin", randf_range(0.9, 1.25), randf_range(-9.0, -3.0))


func _flash(color: Color, strength: float, duration: float) -> void:
	if _flash_tween:
		_flash_tween.kill()
	flash_rect.color = Color(color, strength)
	_flash_tween = create_tween()
	_flash_tween.tween_property(flash_rect, "color:a", 0.0, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)


func _rumble(weak: float, strong: float, duration: float) -> void:
	if not gamepad_rumble:
		return
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, clampf(weak, 0.0, 1.0), clampf(strong, 0.0, 1.0), duration)


# ---------------------------------------------------------------- 设置 / 提示

func _open_settings() -> void:
	if phase == Phase.SPINNING:
		_show_toast("转动中不能打开设置")
		return
	settings_panel.open(_settings, _defaults)


func _apply_settings(s: GameSettings) -> void:
	machine.reel_gap = s.reel_gap
	machine.spin_speed = s.spin_speed
	sfx.set_bgm_volume(s.bgm_volume)
	sfx.set_sfx_volume(s.sfx_volume)
	if is_node_ready() and settings_panel and settings_panel.is_open() and not is_equal_approx(s.sfx_volume, _applied_sfx):
		sfx.play("coin")  # 调音效音量时用新音量试听
	_applied_sfx = s.sfx_volume


func _on_settings_saved(s: GameSettings) -> void:
	_settings = s.copy()
	_apply_settings(_settings)
	_show_toast("设置已保存")


func _show_toast(text: String) -> void:
	toast.text = text
	if _toast_tween:
		_toast_tween.kill()
	toast.modulate.a = 1.0
	_toast_tween = create_tween()
	_toast_tween.tween_interval(0.8)
	_toast_tween.tween_property(toast, "modulate:a", 0.0, 0.4)
