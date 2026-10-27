// 任务：手机上完全不动（列表内联一切），平板上加一条详情栏（flow）。
import { definePanes } from '../../core/panes';

export const APP_ID = 'quests';

export const PANE_CONTRACT = definePanes({
  panes: [
    { id: 'list', role: 'list', min: 300, max: 344, scroll: 'self' },
    { id: 'quest', role: 'detail', min: 340, grow: 1, scroll: 'self' },
  ],
  narrow: 'flow',
  // 等于两栏 min 之和（300 + 340）：resolvePanes 先看 stackBelow 再看 fits，
  // 写成 660 会在 640–659 这条带上明明装得下却挤成一栏。
  stackBelow: 640,
});

export const TABLET_GRANTS = { queries: [], actions: [], fields: [] };
