// core/surface.ts — 同一台设备的两种形态（手机 / 平板）的类型与外壳预设。
//
// 这里只放"长什么样"，不放"谁能开"：形态由服务端/客户端 Lua 决定（surface_rules.lua），
// NUI 只负责渲染 Lua 下发的那个值。零 import，任何人都可以安全依赖它。
//
// 谁负责什么：
//   * Surface（'phone' | 'tablet'）—— 这一台设备此刻的形态，由 Lua 决定
//   * 排布 —— 由容器宽度决定（app 用容器查询），不读 surface 身份，避免 app 越权
export type Surface = 'phone' | 'tablet';

export const SURFACE_PHONE: Surface = 'phone';
export const SURFACE_TABLET: Surface = 'tablet';
export const SURFACES: readonly Surface[] = [SURFACE_PHONE, SURFACE_TABLET];

export function isSurface(value: unknown): value is Surface {
  return value === SURFACE_PHONE || value === SURFACE_TABLET;
}

export interface SurfacePreset {
  /** 设计尺寸（CSS px）。窗口更小时用 min() 收，不靠缩放，避免字糊 */
  width: number;
  height: number;
  radius: number;
  bezel: number;
  /** 刘海 + 前摄 + 听筒：只有手机有 */
  notch: boolean;
  /** 电源/音量侧键：只有手机有 */
  sideButtons: boolean;
  /** 底部手势条：只有手机有 */
  homeBar: boolean;
  /** 背板：手机透明（不挡视野），平板压暗（收注意力） */
  mask: string;
  /** 状态栏高度 */
  statusBar: number;
  /** 平板没有电源键，必须给显式的关闭按钮 */
  closeLabel: string | null;
}

// 375×780 / 48px / 13px 来自原 PhoneShell（手机壳的唯一真值）。
// 1034×676 / 26px / 7px 来自 docs/server-design/assets/11-tablet-demo.html。
export const PRESETS: Record<Surface, SurfacePreset> = {
  phone: {
    width: 375, height: 780, radius: 48, bezel: 13,
    notch: true, sideButtons: true, homeBar: true,
    mask: 'transparent', statusBar: 38, closeLabel: null,
  },
  tablet: {
    width: 1034, height: 676, radius: 26, bezel: 7,
    notch: false, sideButtons: false, homeBar: false,
    mask: 'rgba(3, 6, 14, 0.45)', statusBar: 34, closeLabel: '关闭',
  },
};

export function presetOf(surface: Surface): SurfacePreset {
  return PRESETS[surface] ?? PRESETS.phone;
}
