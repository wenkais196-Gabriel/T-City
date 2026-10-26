// 警用终端的 pane 契约。组件 import 它，静态闸门也读它——只有一个来源。
import { definePanes } from '../../core/panes';

export const APP_ID = 'police_mdt';

export const PANE_CONTRACT = definePanes({
  panes: [
    // 左手：谁在值班（顺带放"请求支援"）
    { id: 'units', role: 'aux', min: 232, max: 300, collapsible: true, scroll: 'self' },
    // 中间：接警列表。行内保留"前往/清场"，巡逻时一击不能变两击
    { id: 'incidents', role: 'list', min: 296, max: 348, scroll: 'self' },
    // 右手：选中的那一单。手机上不存在（drill 只显示 active），平板才并出来
    { id: 'detail', role: 'detail', min: 320, grow: 1, scroll: 'self' },
  ],
  narrow: 'drill',
  stackBelow: 720,
});

// 平板形态不允许新增任何查询/动作/字段：看得更宽不等于看得更多。
// 闸门会把这个对象钉住——一旦有人往这里塞东西，就必须在服务端注册并带权限守卫。
export const TABLET_GRANTS = { queries: [], actions: [], fields: [] };
