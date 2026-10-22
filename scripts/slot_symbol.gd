@tool
class_name SlotSymbol
extends Resource
## 一个滚轮符号（= 一种中奖内容）。
## 新增符号最省事的办法：在 FileSystem 里复制一个现有的 symbols/*.tres，改图片和参数，
## 再把它加进符号组（symbols/default_set.tres）的 Symbols 列表。

enum Tier {
	NONE = -1,   ## 不参与中奖（空白格、装饰）
	NORMAL = 0,  ## 小奖
	BIG = 1,     ## 中奖
	JACKPOT = 2, ## 大奖
}

## 唯一标识。只有在符号组里手写滚轮带（Custom Strips）时才用到
@export var id := "":
	set(v):
		id = v
		emit_changed()
## 显示名（备注用，不显示在画面上）
@export var display_name := ""
## 符号图片：任意尺寸，透明背景的 PNG 效果最好，会按比例缩放进格子
@export var texture: Texture2D:
	set(v):
		texture = v
		emit_changed()
## 中奖等级：决定连成一线时的演出强度
@export var tier: Tier = Tier.NORMAL:
	set(v):
		tier = v
		emit_changed()
## 主题色：中奖高亮、连线、粒子用这个颜色
@export var color := Color.WHITE:
	set(v):
		color = v
		emit_changed()
## 每列滚轮上出现几次（越多越容易连线；一列的总格数 = 所有符号的次数之和）
@export_range(0, 30) var count := 3:
	set(v):
		count = v
		emit_changed()
## 在格子里的大小（1 = 默认大小）
@export_range(0.3, 1.5, 0.01) var size_scale := 1.0:
	set(v):
		size_scale = v
		emit_changed()
## 中奖音效。留空 = 按中奖等级用默认音效（Sfx 节点上的 Win / Win Big / Jackpot）
@export var win_sound: AudioStream


func label() -> String:
	if not display_name.is_empty():
		return display_name
	if not id.is_empty():
		return id
	return resource_path.get_file().get_basename()


## 能否参与中奖
func pays() -> bool:
	return tier != Tier.NONE
