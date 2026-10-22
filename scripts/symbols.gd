@tool
class_name SlotSymbols
extends RefCounted
## 符号表与默认滚轮带（reel strip）。
## 增删符号：在 DEFS 里加一项，并把同名贴图放进 assets/symbols/
## （可选再放一张 <id>_blur.png 作为高速转动时的模糊版）。

enum Tier { NORMAL, BIG, JACKPOT }

const SYMBOL_DIR := "res://assets/symbols/"

## tier 决定中奖演出的等级；color 用于高亮、连线和粒子。
const DEFS := {
	"seven": {"tier": Tier.JACKPOT, "color": Color(1.0, 0.3, 0.25)},
	"bar": {"tier": Tier.BIG, "color": Color(1.0, 0.82, 0.3)},
	"star": {"tier": Tier.BIG, "color": Color(0.35, 0.75, 1.0)},
	"bell": {"tier": Tier.NORMAL, "color": Color(1.0, 0.85, 0.25)},
	"melon": {"tier": Tier.NORMAL, "color": Color(0.45, 1.0, 0.45)},
	"grape": {"tier": Tier.NORMAL, "color": Color(0.8, 0.5, 1.0)},
	"cherry": {"tier": Tier.NORMAL, "color": Color(1.0, 0.4, 0.5)},
}

## 每列滚轮的符号序列（21 格）。列数多于 3 时循环使用。
## 转动时符号从上往下走，所以屏幕上从上到下看到的是序列的倒序。
const STRIPS := [
	["seven", "grape", "bell", "cherry", "melon", "bar", "grape", "bell", "star", "cherry", "melon",
		"seven", "grape", "bell", "star", "bar", "cherry", "grape", "melon", "bell", "star"],
	["seven", "bell", "grape", "star", "cherry", "melon", "bell", "bar", "grape", "cherry", "star",
		"seven", "melon", "bell", "grape", "bar", "cherry", "melon", "grape", "bell", "star"],
	["seven", "melon", "grape", "bell", "bar", "cherry", "star", "grape", "bell", "melon", "cherry",
		"seven", "star", "grape", "bell", "bar", "melon", "cherry", "grape", "bell", "star"],
]

static var _textures := {}


static func texture(id: String, blurred := false) -> Texture2D:
	var key := id + ("_blur" if blurred else "")
	if not _textures.has(key):
		var path := SYMBOL_DIR + key + ".png"
		_textures[key] = load(path) if ResourceLoader.exists(path) else null
	return _textures[key]


static func tier(id: String) -> int:
	return DEFS.get(id, {}).get("tier", Tier.NORMAL)


static func color(id: String) -> Color:
	return DEFS.get(id, {}).get("color", Color.WHITE)


static func strip(reel_index: int) -> PackedStringArray:
	return PackedStringArray(STRIPS[reel_index % STRIPS.size()])
