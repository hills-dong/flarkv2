# Lark 表情资源接入约定

Flark 的表情库由 `Flark/Resources/Emoji/` 这个**文件夹引用**驱动（蓝色 folder
reference，整目录原样进包，子路径保留为 `Emoji/`）。

## 目录

```
Flark/Resources/Emoji/
  manifest.json          # 表情清单（必需）
  <file>.png / .webp     # 你后续投放的 Lark 表情图片（可选）
```

## manifest.json 格式

```json
{
  "items": [
    { "id": "lark_done", "file": "lark_done.png", "unicode": "✅",
      "category": "lark", "keywords": ["DONE", "完成"] }
  ]
}
```

- `id`：稳定唯一标识，**事件/反应里存的就是它**，改名会丢历史，请勿变更已用 id。
- `file`：相对 `Emoji/` 的图片文件名。**缺省或文件不存在时自动回退到 `unicode`**，
  所以现在没有图也能正常跑。
- `unicode`：兜底字符（占位）。
- `category`：分组，决定在选择器里的分区。已识别：`most_used`→最常使用，
  `default`→默认表情，`lark`→Lark 贴纸；其他值原样作为分区标题。
- `keywords`：可选，未来做搜索用。

## 投放 Lark 表情图片的步骤

1. 把 Lark 表情图片（建议 PNG，128×128 左右）放进 `Flark/Resources/Emoji/`。
2. 在 `manifest.json` 里给对应条目补上 `"file": "你的文件名.png"`，并按需调整
   `category` / `keywords`。
3. 重新构建即可生效（无需改代码）。`EmojiGlyph` 会优先用图片，找不到才用
   `unicode`。

> 说明：仓库内目前只提供 Unicode 占位（不含字节跳动版权资源）。Lark 官方表情
> 图片请自行获取并按上述约定放入。
