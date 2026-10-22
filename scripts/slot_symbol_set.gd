@tool
class_name SlotSymbolSet
extends Resource
## 一套中奖内容：用哪些符号 + 每列滚轮带怎么排。
## 换一整套内容 = 新建/复制一个符号组，在 SlotMachine 节点的 Symbol Set 里换掉。

## 用到的符号
@export var symbols: Array[SlotSymbol] = []:
	set(v):
		for s in symbols:
			if s and s.changed.is_connected(emit_changed):
				s.changed.disconnect(emit_changed)
		symbols = v
		for s in symbols:
			if s and not s.changed.is_connected(emit_changed):
				s.changed.connect(emit_changed)
		emit_changed()

## 手写滚轮带（可选）：第 N 项是第 N 列，从上往下依次写符号的 id。
## 某一列留空或没写 = 按各符号的 Count 自动均匀排布。
@export var custom_strips: Array[PackedStringArray] = []:
	set(v):
		custom_strips = v
		emit_changed()


## 第 reel_index 列的滚轮带（转动时符号从上往下走）
func build_strip(reel_index: int) -> Array[SlotSymbol]:
	var out: Array[SlotSymbol] = []
	if reel_index < custom_strips.size() and not custom_strips[reel_index].is_empty():
		var by_id := {}
		for s in symbols:
			if s and not s.id.is_empty():
				by_id[s.id] = s
		# 手写顺序是"从上往下看到的顺序"，而转动时序号越大越靠上，所以倒过来存
		var ids := custom_strips[reel_index]
		for i in range(ids.size() - 1, -1, -1):
			var id := ids[i].strip_edges()
			if by_id.has(id):
				out.append(by_id[id])
			elif not id.is_empty():
				push_warning("符号组 %s：第 %d 列的滚轮带里有未知 id \"%s\"" % [resource_path, reel_index + 1, id])
		if not out.is_empty():
			return out

	# 自动：每个符号按 count 在整条带上等间距分布，不同符号/不同列错开相位
	var entries := []
	for si in symbols.size():
		var s := symbols[si]
		if s == null or s.count <= 0:
			continue
		var phase := fposmod(si * 0.618034 + reel_index * 0.381966, 1.0)
		for k in s.count:
			entries.append([(k + phase) / s.count, si])
	entries.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	for e in entries:
		out.append(symbols[e[1]])
	return out


func is_usable() -> bool:
	for s in symbols:
		if s and s.count > 0:
			return true
	return not custom_strips.is_empty()
