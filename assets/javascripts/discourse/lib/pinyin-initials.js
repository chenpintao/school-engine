// 真实姓名 → 拼音首字母（如 "张三" → "zs"）
// 仅用于同学录"找人"检索，结果随表单提交存入隐藏 custom field，不公开输出。
import { pinyin } from "pinyin-pro";

export function nameInitials(name) {
  return pinyin(name || "", {
    pattern: "first",
    toneType: "none",
    type: "array",
  })
    .join("")
    .replace(/[^a-zA-Z]/g, "")
    .toLowerCase();
}
