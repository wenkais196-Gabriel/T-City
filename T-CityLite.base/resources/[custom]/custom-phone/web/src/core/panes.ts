// core/panes.ts — pane 契约：app 声明自己由哪几个面板组成，排布由容器宽度决定。
//
// 为什么是"容器宽度"而不是 surface 身份：surface 只是"这一台设备此刻的形态"，
// 而布局回答的是"这块屏幕有多宽"。用宽度，同一个 app 在窄窗口、手机、平板、超宽窗口
// 里都能正确降级；用身份，就得为每种组合再写一条分支。
//
// 纯函数、零副作用、不 import store —— 可以在 node 里直接单测。

export type PaneRole = 'list' | 'detail' | 'aux' | 'form' | 'solo';
export type NarrowMode = 'drill' | 'flow';

export interface PaneDef {
  /** 稳定标识，同时作为 Pane 组件的 id */
  id: string;
  /** 语义标签：只用于校验与可读性，不参与决策 */
  role: PaneRole;
  /** 横排时允许的最小宽度(px) */
  min: number;
  /** 上限：列表类给上限，详情类不给 */
  max?: number;
  /** 剩余空间权重，默认 1（只对无 max 的 pane 生效） */
  grow?: number;
  /** self=自己滚；none=不滚（内部再分，如聊天输入栏） */
  scroll?: 'self' | 'none';
  /** 允许在窄容器里被摘掉；未声明者永不摘 */
  collapsible?: boolean;
}

export interface PaneSpec {
  panes: PaneDef[];
  /** drill=一次只显示 active（手机主从）；flow=顺序堆叠 */
  narrow?: NarrowMode;
  /** 低于此宽度直接单栏 */
  stackBelow?: number;
}

export interface PaneLayout {
  mode: 'stack' | 'grid';
  columns: string;
  hidden: string[];
  active: string;
}

const DEFAULT_STACK_BELOW = 600;

export function resolvePanes(spec: PaneSpec, width: number, active: string): PaneLayout {
  const narrow: NarrowMode = spec.narrow ?? 'drill';
  const keep = spec.panes.slice();
  const fits = (panes: PaneDef[]) =>
    panes.reduce((sum, pane) => sum + pane.min, 0) <= width;

  // 只摘声明过 collapsible 的 pane，从右往左摘
  while (!fits(keep) && keep.some((pane) => pane.collapsible)) {
    for (let index = keep.length - 1; index >= 0; index -= 1) {
      if (keep[index].collapsible) {
        keep.splice(index, 1);
        break;
      }
    }
  }

  if (width < (spec.stackBelow ?? DEFAULT_STACK_BELOW) || !fits(keep)) {
    return {
      mode: 'stack',
      columns: 'minmax(0, 1fr)',
      hidden: narrow === 'drill'
        ? spec.panes.filter((pane) => pane.id !== active).map((pane) => pane.id)
        : [],
      active,
    };
  }

  return {
    mode: 'grid',
    columns: keep
      .map((pane) => (pane.max
        ? `minmax(${pane.min}px, ${pane.max}px)`
        : `minmax(${pane.min}px, ${pane.grow ?? 1}fr)`))
      .join(' '),
    hidden: [],
    active,
  };
}

/** 开发期校验：写错的 spec 在挂载时就炸，而不是在平板上悄悄挤成一栏。 */
export function definePanes(spec: PaneSpec): PaneSpec {
  const ids = new Set<string>();
  for (const pane of spec.panes) {
    if (ids.has(pane.id)) throw new Error(`pane id 重复: ${pane.id}`);
    ids.add(pane.id);
    if (!Number.isFinite(pane.min) || pane.min < 0) throw new Error(`pane ${pane.id} 缺少 min`);
  }
  if ((spec.narrow ?? 'drill') === 'drill' && !spec.panes.some((pane) => pane.role === 'list')) {
    throw new Error('drill 需要一个 role=list 的 pane 作为起点');
  }
  return spec;
}
