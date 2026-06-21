// ============================================================================
// map_sidebar.js — 地图侧边栏交互逻辑
// ============================================================================
// 核心功能:
//   1. 接收 NUI message → 渲染分类列表
//   2. < > 箭头在子项间切换，局部更新主标签文本 + 计数器
//   3. 📍 按钮 → post setWaypoint 回调给 Lua
//   4. ESC / ✕ 关闭侧边栏
// ============================================================================

(function () {
    'use strict';

    const $sidebar  = document.getElementById('sidebar');
    const $title    = document.getElementById('sidebar-title');
    const $catList  = document.getElementById('category-list');
    const $btnClose = document.getElementById('btn-close');

    let categories    = [];
    let activeIndex   = {};   // { catId: currentIdx }
    let resourceName  = '';

    function getResourceName() {
        if (resourceName) return resourceName;
        try {
            resourceName = (window.GetParentResourceName && GetParentResourceName()) || 'qb-core';
        } catch (_) {
            resourceName = 'qb-core';
        }
        return resourceName;
    }

    function post(action, data) {
        fetch('https://' + getResourceName() + '/' + action, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=utf-8' },
            body: JSON.stringify(data || {}),
        }).catch(function () { /* NUI closed, ignore */ });
    }

    function escapeHtml(str) {
        var div = document.createElement('div');
        div.textContent = str || '';
        return div.innerHTML;
    }

    // ── 全量渲染 ──
    function renderAll() {
        var html = '';
        for (var i = 0; i < categories.length; i++) {
            var cat   = categories[i];
            var idx   = activeIndex[cat.id] || 0;
            var item  = cat.items[idx];
            var total = cat.items.length;
            var multi = total > 1;

            html +=
                '<div class="category-item' + (multi ? '' : ' single') + '"' +
                ' data-cat="' + i + '" data-idx="' + idx + '">' +
                '<div class="cat-icon"><i class="' + escapeHtml(cat.icon || 'fa-solid fa-location-dot') + '"></i></div>' +
                '<div class="cat-info">' +
                '<div class="cat-label">' + escapeHtml(item.name) + '</div>' +
                (multi
                    ? '<div class="cat-subnav">' +
                      '<button class="nav-arrow" data-action="prev" data-cat="' + i + '">' +
                      '<i class="fa-solid fa-chevron-left"></i></button>' +
                      '<span class="cat-counter">&lt; ' + (idx + 1) + ' / ' + total + ' &gt;</span>' +
                      '<button class="nav-arrow" data-action="next" data-cat="' + i + '">' +
                      '<i class="fa-solid fa-chevron-right"></i></button>' +
                      '</div>'
                    : '') +
                '</div>' +
                '<button class="btn-locate" data-action="locate" data-cat="' + i + '" data-idx="' + idx + '">' +
                '<i class="fa-solid fa-location-crosshairs"></i></button>' +
                '</div>';
        }
        $catList.innerHTML = html;
    }

    // ── 单行局部更新 (不重绘全列表) ──
    function updateSingleRow(catIdx) {
        var cat   = categories[catIdx];
        var cur   = activeIndex[cat.id] || 0;
        var item  = cat.items[cur];
        var total = cat.items.length;

        var row = $catList.querySelector('[data-cat="' + catIdx + '"]');
        if (!row) { renderAll(); return; }

        row.setAttribute('data-idx', cur);
        var labelEl   = row.querySelector('.cat-label');
        var counterEl = row.querySelector('.cat-counter');
        var locateBtn = row.querySelector('.btn-locate');

        if (labelEl)   labelEl.textContent   = item.name;
        if (counterEl) counterEl.textContent = '< ' + (cur + 1) + ' / ' + total + ' >';
        if (locateBtn) locateBtn.setAttribute('data-idx', cur);
    }

    // ── 切换子项 ──
    function switchItem(catIdx, delta) {
        var cat = categories[catIdx];
        if (!cat || cat.items.length <= 1) return;

        var cur = activeIndex[cat.id] || 0;
        cur = (cur + delta + cat.items.length) % cat.items.length;
        activeIndex[cat.id] = cur;
        updateSingleRow(catIdx);
    }

    // ── GPS 定位 ──
    function locate(catIdx, idx) {
        var cat  = categories[catIdx];
        if (!cat) return;
        var item = cat.items[idx !== undefined ? idx : (activeIndex[cat.id] || 0)];
        if (!item) return;

        post('mapSidebar:setWaypoint', { coords: item.coords });

        // 视觉反馈
        var row = $catList.querySelector('[data-cat="' + catIdx + '"]');
        if (row) {
            row.classList.add('flash');
            setTimeout(function () { row.classList.remove('flash'); }, 350);
        }
    }

    // ── 关闭 ──
    function close() {
        $sidebar.classList.add('hidden');
        post('mapSidebar:close');
    }

    // ── 事件委托 ──
    $catList.addEventListener('click', function (e) {
        var btn = e.target.closest('[data-action]');
        if (!btn) return;

        var action = btn.getAttribute('data-action');
        var catIdx = parseInt(btn.getAttribute('data-cat'), 10);
        var idx    = parseInt(btn.getAttribute('data-idx'), 10);

        switch (action) {
            case 'prev':   switchItem(catIdx, -1); break;
            case 'next':   switchItem(catIdx, +1); break;
            case 'locate': locate(catIdx, idx);    break;
        }
    });

    $btnClose.addEventListener('click', close);

    // 点击行空白处 = 定位
    $catList.addEventListener('click', function (e) {
        var row = e.target.closest('.category-item');
        if (!row) return;
        // 只有在没点到按钮时才触发定位
        if (e.target.closest('[data-action]')) return;
        var catIdx = parseInt(row.getAttribute('data-cat'), 10);
        var idx    = parseInt(row.getAttribute('data-idx'), 10);
        locate(catIdx, idx);
    });

    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') close();
    });

    // ── NUI Message 接收 ──
    window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || !data.action) return;

        switch (data.action) {
            case 'mapSidebar:open':
                categories  = data.categories || [];
                activeIndex = {};
                for (var i = 0; i < categories.length; i++) {
                    activeIndex[categories[i].id] = 0;
                }
                if (data.title) {
                    $title.textContent = data.title;
                }
                $sidebar.classList.remove('hidden');
                renderAll();
                break;

            case 'mapSidebar:close':
                $sidebar.classList.add('hidden');
                break;
        }
    });

})();
