// 短消息：手机上列表/会话二选一（drill），平板上并排。
import { definePanes } from '../../core/panes';

export const APP_ID = 'messages';

export const PANE_CONTRACT = definePanes({
  panes: [
    { id: 'threads', role: 'list', min: 240, max: 316, scroll: 'self' },
    { id: 'chat', role: 'detail', min: 320, grow: 1, scroll: 'none' },
  ],
  narrow: 'drill',
  stackBelow: 560,
});

export const TABLET_GRANTS = { queries: [], actions: [], fields: [] };
