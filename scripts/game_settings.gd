class_name GameSettings
extends RefCounted
## 运行时设置（设置界面里能改的那些），保存在 user://settings.cfg。
## 没有保存过时，用场景里 Inspector 上的值作为默认值。

const PATH := "user://settings.cfg"

var reel_gap := 40.0      ## 屏间距（像素）
var spin_speed := 16.0    ## 转速（格/秒）
var bgm_volume := 0.7     ## 背景音乐音量 0~1
var sfx_volume := 1.0     ## 音效音量 0~1


func copy() -> GameSettings:
	var s := GameSettings.new()
	s.reel_gap = reel_gap
	s.spin_speed = spin_speed
	s.bgm_volume = bgm_volume
	s.sfx_volume = sfx_volume
	return s


## 读取已保存的设置；没有的项保留 defaults 里的值
static func load_or(defaults: GameSettings) -> GameSettings:
	var s := defaults.copy()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return s
	s.reel_gap = float(cfg.get_value("display", "reel_gap", s.reel_gap))
	s.spin_speed = float(cfg.get_value("game", "spin_speed", s.spin_speed))
	s.bgm_volume = clampf(float(cfg.get_value("audio", "bgm_volume", s.bgm_volume)), 0.0, 1.0)
	s.sfx_volume = clampf(float(cfg.get_value("audio", "sfx_volume", s.sfx_volume)), 0.0, 1.0)
	return s


func save() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "reel_gap", reel_gap)
	cfg.set_value("game", "spin_speed", spin_speed)
	cfg.set_value("audio", "bgm_volume", bgm_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	return cfg.save(PATH)
