class_name SettingsPanel
extends Control
## 设置界面（Esc / F2 打开）：屏间距、转速、背景音乐 / 音效音量。
## 拖动时实时预览；"保存"写入 user://settings.cfg，下次启动自动生效；"取消"恢复打开前的值。
## 全键盘可操作：↑↓ 选择，←→ 调整，Enter 按按钮，Esc 取消。

signal preview(settings: GameSettings)   ## 值改变时（实时预览）
signal saved(settings: GameSettings)
signal cancelled(original: GameSettings)

## 设置项：属性名、标题、最小、最大、步长（←→ 每按一下变化多少）
const ITEMS := [
	["reel_gap", "屏间距", 0.0, 600.0, 5.0],
	["spin_speed", "转速（目押难度）", 6.0, 30.0, 0.5],
	["bgm_volume", "背景音乐音量", 0.0, 1.0, 0.05],
	["sfx_volume", "音效音量", 0.0, 1.0, 0.05],
]
const FONT_SIZE := 30
const GOLD := Color(1.0, 0.82, 0.35)

var _current: GameSettings
var _original: GameSettings
var _defaults: GameSettings
var _sliders := {}
var _labels := {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP  # 打开时挡住点击，不会误触开始
	visible = false
	_build()


func is_open() -> bool:
	return visible


func open(current: GameSettings, defaults: GameSettings) -> void:
	_original = current.copy()
	_current = current.copy()
	_defaults = defaults
	_sync()
	visible = true
	(_sliders[ITEMS[0][0]] as Control).grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("slot_settings"):
		_cancel()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- 构建界面

func _build() -> void:
	var ui_theme := _make_theme()

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	# 面板贴在屏幕下方，上方的滚轮保持可见，调间距时能直接看到效果
	var panel := PanelContainer.new()
	panel.theme = ui_theme
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -560
	panel.offset_right = 560
	panel.offset_top = -24
	panel.offset_bottom = -24
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.06, 0.11, 0.94)
	sb.border_color = Color(1.0, 0.82, 0.35, 0.8)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(18)
	sb.set_content_margin_all(30)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)

	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 28)
	grid.add_theme_constant_override("v_separation", 16)
	box.add_child(grid)
	for item in ITEMS:
		var key: String = item[0]
		var name_label := Label.new()
		name_label.text = item[1]
		grid.add_child(name_label)

		var slider := HSlider.new()
		slider.min_value = item[2]
		slider.max_value = item[3]
		slider.step = item[4]
		slider.allow_greater = key == "reel_gap"
		slider.custom_minimum_size = Vector2(560, 44)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.value_changed.connect(_on_value_changed.bind(key))
		# 键盘选中哪一行，哪一行的标题就变金色
		slider.focus_entered.connect(name_label.add_theme_color_override.bind("font_color", GOLD))
		slider.focus_exited.connect(name_label.remove_theme_color_override.bind("font_color"))
		grid.add_child(slider)
		_sliders[key] = slider

		var value_label := Label.new()
		value_label.custom_minimum_size = Vector2(170, 0)
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(value_label)
		_labels[key] = value_label

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 28)
	box.add_child(buttons)
	for b in [["恢复默认", _reset], ["取消", _cancel], ["保存", _save]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.custom_minimum_size = Vector2(210, 64)
		btn.pressed.connect(b[1])
		buttons.add_child(btn)

	var hint := Label.new()
	hint.text = "↑↓ 选择　←→ 调整　Enter 确认　Esc 取消"
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT_SIZE
	var track := _box(Color(1, 1, 1, 0.15), 6)
	track.content_margin_top = 5
	track.content_margin_bottom = 5
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", _box(GOLD.darkened(0.3), 6))
	t.set_stylebox("grabber_area_highlight", "HSlider", _box(GOLD, 6))
	t.set_icon("grabber", "HSlider", _circle(26, Color(0.92, 0.92, 0.92)))
	t.set_icon("grabber_highlight", "HSlider", _circle(32, GOLD))
	var focus := _box(Color(0, 0, 0, 0), 10)
	focus.draw_center = false
	focus.border_color = GOLD
	focus.set_border_width_all(3)
	focus.set_expand_margin_all(8)
	t.set_stylebox("focus", "HSlider", focus)
	t.set_stylebox("focus", "Button", focus)
	t.set_stylebox("normal", "Button", _box(Color(1, 1, 1, 0.08), 10))
	t.set_stylebox("hover", "Button", _box(Color(1, 1, 1, 0.16), 10))
	t.set_stylebox("pressed", "Button", _box(GOLD.darkened(0.4), 10))
	t.set_color("font_focus_color", "Button", GOLD)
	t.set_color("font_hover_color", "Button", GOLD)
	return t


static func _box(color: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	return sb


## 圆形滑块图标（抗锯齿）
static func _circle(d: int, color: Color) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var r := d * 0.5
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			img.set_pixel(x, y, Color(color, clampf(r - dist, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- 交互

func _on_value_changed(value: float, key: String) -> void:
	_current.set(key, value)
	_update_label(key)
	preview.emit(_current)


func _sync() -> void:
	for item in ITEMS:
		var key: String = item[0]
		(_sliders[key] as HSlider).set_value_no_signal(float(_current.get(key)))
		_update_label(key)


func _update_label(key: String) -> void:
	var v := float(_current.get(key))
	var text := ""
	match key:
		"reel_gap":
			text = "%d px" % roundi(v)
		"spin_speed":
			text = "%.1f 格/秒" % v
		_:
			text = "%d%%" % roundi(v * 100.0)
	(_labels[key] as Label).text = text


func _reset() -> void:
	_current = _defaults.copy()
	_sync()
	preview.emit(_current)


func _cancel() -> void:
	visible = false
	cancelled.emit(_original)


func _save() -> void:
	var err := _current.save()
	if err != OK:
		push_error("设置保存失败：%s" % error_string(err))
	visible = false
	saved.emit(_current)
