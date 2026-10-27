<script lang="ts">
  // AppSurface.svelte — 把 pane 契约翻译成 CSS grid。它不认识业务，也不认识 surface：
  // 唯一的输入是容器宽度（ResizeObserver），唯一的输出是 columns / 可见性。
  import { onMount, setContext } from 'svelte';
  import { resolvePanes, type PaneLayout, type PaneSpec } from '../core/panes';

  let {
    spec,
    activePane = '',
    mode = $bindable('stack'),
    children,
  }: {
    spec: PaneSpec;
    activePane?: string;
    mode?: PaneLayout['mode'];
    children?: any;
  } = $props();

  let width = $state(0);
  let host = $state<HTMLDivElement | null>(null);

  const layout = $derived(width > 0
    ? resolvePanes(spec, width, activePane)
    : { mode: 'stack' as const, columns: 'minmax(0, 1fr)', hidden: [], active: activePane });

  // 回写给父组件：app 用它决定"要不要渲染平板专属 pane / 隐藏手机上的分段切换"
  $effect(() => {
    if (mode !== layout.mode) mode = layout.mode;
  });

  setContext('pane', {
    active: () => activePane,
    hidden: (id: string) => layout.hidden.includes(id),
  });

  onMount(() => {
    // 先同步量一次：width 初始是 0，layout 会退回 stack；等 ResizeObserver 的第一次
    // 回调才切两栏的话，快机器上看不出来，慢机器上就是"平板只剩一栏"（CI 上偶发）。
    if (host) width = host.getBoundingClientRect().width;
    const observer = new ResizeObserver(([entry]) => {
      width = entry.contentRect.width;
    });
    if (host) observer.observe(host);
    return () => observer.disconnect();
  });
</script>

<div
  class="app-surface"
  bind:this={host}
  data-mode={layout.mode}
  data-narrow={spec.narrow ?? 'drill'}
  style={`--pane-cols:${layout.columns}`}
>
  {@render children?.()}
</div>

<style>
  .app-surface {
    flex: 1;
    min-height: 0;
    min-width: 0;
    height: 100%;
    display: grid;
    /* 三个 minmax(0, …) 是必须的：少了任何一个，grid 子项会被内容撑开，
       pane 自己的 overflow-y:auto 就永远不生效（整个 .mdt 变成一根长滚动条）。 */
    grid-template-columns: var(--pane-cols);
    grid-template-rows: minmax(0, 1fr);
    column-gap: 0;
  }

  /* drill：窄容器里一次只显示一个 pane（手机的主从切换） */
  .app-surface[data-mode='stack'][data-narrow='drill'] :global(.pane[data-active='false']) {
    display: none;
  }
</style>
