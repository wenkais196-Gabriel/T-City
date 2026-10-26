// 任务：手机上完全不动（列表内联一切），平板上加一条详情栏（flow）。
import { definePanes } from '../../core/panes';

export const APP_ID = 'quests';

export const PANE_CONTRACT = definePanes({
  panes: [
    { id: 'list', role: 'list', min: 300, max: 344, scroll: 'self' },
    { id: 'quest', role: 'detail', min: 340, grow: 1, scroll: 'self' },
  ],
  narrow: 'flow',
  stackBelow: 660,
});

export const TABLET_GRANTS = { queries: [], actions: [], fields: [] };
