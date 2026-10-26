// src/utils/time.ts — 唯一的时间格式化出口
//
// 以前这个函数被复制了四份（通知 / 城市动态 / 消息 / 帮派频道），每份都是：
//   new Date(v).getHours() + ':' + getMinutes()
// 一旦 v 不是可解析的值（undefined、对象、被序列化成 {} 的字段），界面就直接显示
// "NaN:NaN"——比显示"--:--"糟糕得多，因为玩家会以为手机坏了。
//
// 这里做三件事：
// 1. 接受四类输入：Date、毫秒/秒时间戳、ISO 字符串、MySQL 的 "YYYY-MM-DD HH:MM:SS"
// 2. 解析不出来就返回占位符，永远不让 NaN 出现在界面上
// 3. 解析失败时打一条 warn，带上原始值——下次再出现，控制台直接告诉我们是谁

const PLACEHOLDER = '--:--';

/** 每个来源只警告一次：一屏 50 条坏数据不该刷满控制台。 */
const warned = new Set<string>();

/** 秒级时间戳阈值：小于这个数量级的是"秒"，大于的是"毫秒"。 */
const SECONDS_UPPER_BOUND = 1e11;

function toDate(value: unknown): Date | null {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value === 'number' && Number.isFinite(value)) {
    const ms = value < SECONDS_UPPER_BOUND ? value * 1000 : value;
    const d = new Date(ms);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  if (typeof value === 'string') {
    const raw = value.trim();
    if (raw === '') return null;
    // MySQL DATETIME 在某些驱动下会带空格而不是 'T'；Safari/旧 CEF 不认，补成 ISO。
    const normalised = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$/.test(raw)
      ? raw.replace(' ', 'T')
      : raw;
    const d = new Date(normalised);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  return null;
}

/**
 * 把任意时间值格式化成 HH:MM。
 * 解析不出来时返回 "--:--"，并且只在第一次遇到坏的输入时打 warn。
 */
export function formatClock(value: unknown, tag = 'clock'): string {
  const date = toDate(value);
  if (!date) {
    if (!warned.has(tag)) {
      warned.add(tag);
      console.warn(`[phone] ${tag}: 时间字段无法解析，已回退为 ${PLACEHOLDER}`, value);
    }
    return PLACEHOLDER;
  }
  const hh = String(date.getHours()).padStart(2, '0');
  const mm = String(date.getMinutes()).padStart(2, '0');
  return `${hh}:${mm}`;
}

/** 给测试用：清掉"已经警告过"的记录。 */
export function resetClockWarnings(): void {
  warned.clear();
}
