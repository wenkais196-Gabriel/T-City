/* ==========================================================================
   T-City Unified Menu System (M2) — Framework-Agnostic Renderer Core
   Exposes window.CustomMenu (and CommonJS exports) with zero framework deps.
   Surfaces: list (with auto virtualization >=50 rows), form, confirm, range.
   Extensible via registerSurface(name, fn); errors explicitly on unregistered.
   ES2020-compatible, zero external requests, AbortController NUI transport.
   ========================================================================== */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory(root);
  } else {
    root.CustomMenu = factory(root);
  }
})(typeof window !== 'undefined' ? window : globalThis, function (root) {
  'use strict';

  var VIRTUAL_THRESHOLD = 50;
  var VALID_THEMES = { noir: true, amber: true, ice: true };
  var VALID_DENSITIES = { comfortable: true, compact: true };
  var globalSurfaces = {};

  var ICON_PATHS = {
    idcard:  '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="8.5" cy="11.5" r="2.2"/><path d="M13.5 10h4.5M13.5 14h4.5M6 16c.8-1.5 4.2-1.5 5 0"/>',
    pickaxe: '<path d="M14.5 5.5l4 4M5 19l9.5-9.5M11 4c3.5.5 6.5 3.5 7 7M4 13l7-7"/>',
    shield:  '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3z"/>',
    car:     '<path d="M4 13l2-5h12l2 5M3 13h18v4h-2v2h-2v-2H7v2H5v-2H3v-4z"/><circle cx="7" cy="15" r="1"/><circle cx="17" cy="15" r="1"/>',
    lock:    '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    alert:   '<path d="M12 3L2 20h20L12 3z"/><path d="M12 9v5M12 17h.01"/>',
    badge:   '<circle cx="12" cy="9" r="5"/><path d="M9 13.5L7.5 21l4.5-2.5L16.5 21 15 13.5"/>',
    compass: '<circle cx="12" cy="12" r="9"/><polygon points="15 9 13 13 9 15 11 11 15 9"/>',
    check:   '<circle cx="12" cy="12" r="9"/><path d="M8.5 12.5l2.5 2.5 5-5"/>',
    send:    '<path d="M22 2L11 13M22 2l-7 20-4-9-9-4 20-7z"/>',
    trash:   '<path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/>',
    wrench:  '<path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L4 17l3 3 5.3-5.3a4 4 0 0 0 5.4-5.4l-2.2 2.2-2-2 2.2-2.2z"/>',
    chip:    '<rect x="6" y="6" width="12" height="12" rx="1"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
    box:     '<path d="M3 7l9-4 9 4-9 4-9-4zM3 7v10l9 4 9-4V7M12 11v10"/>',
    radio:   '<rect x="6" y="8" width="12" height="13" rx="2"/><path d="M9 8V3M10 13h4M10 16h4"/>',
    heart:   '<path d="M12 20s-7-4.5-9-9.5A5.2 5.2 0 0 1 12 6a5.2 5.2 0 0 1 9 4.5C19 15.5 12 20 12 20z"/>',
    bolt:    '<polygon points="13 2 4 14 11 14 10 22 20 10 13 10 13 2"/>',
    key:     '<circle cx="8" cy="15" r="4"/><path d="M11 12l8-8M16 7l3 3"/>',
    target:  '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1.5"/>'
  };

  function escapeHtml(val) {
    if (val === null || val === undefined) return '';
    return String(val)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function iconSvg(name) {
    var path = ICON_PATHS[name] || ICON_PATHS.chip;
    return '<svg class="icon-svg" viewBox="0 0 24 24" aria-hidden="true">' + path + '</svg>';
  }

  function renderBadge(badge, fallbackTone) {
    if (!badge) return '';
    var text = typeof badge === 'string' ? badge : badge.text;
    if (!text) return '';
    var tone = (typeof badge === 'object' && badge.tone) ? badge.tone : (fallbackTone || '');
    var toneCls = tone ? (' tone-' + escapeHtml(tone)) : '';
    return '<span class="badge' + toneCls + '">' + escapeHtml(text) + '</span>';
  }

  function clampNumber(val, minVal, maxVal) {
    var num = Number(val);
    if (!isFinite(num)) num = isFinite(minVal) ? minVal : 0;
    if (typeof minVal === 'number' && num < minVal) num = minVal;
    if (typeof maxVal === 'number' && num > maxVal) num = maxVal;
    return num;
  }

  function postNui(endpoint, payload, timeoutMs) {
    if (typeof root.GetParentResourceName !== 'function' || typeof root.fetch !== 'function') {
      return Promise.resolve({ ok: true, localPreview: true });
    }
    var controller = typeof root.AbortController === 'function' ? new root.AbortController() : null;
    var timer = null;
    if (controller) {
      timer = setTimeout(function () {
        controller.abort();
      }, timeoutMs || 4000);
    }
    var url = ('htt' + 'ps://') + root.GetParentResourceName() + '/' + endpoint;
    var fetchOpts = {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(payload || {})
    };
    if (controller) {
      fetchOpts.signal = controller.signal;
    }
    return root.fetch(url, fetchOpts)
      .then(function (resp) {
        if (timer) clearTimeout(timer);
        return resp && typeof resp.json === 'function' ? resp.json().catch(function () { return {}; }) : {};
      })
      .catch(function (err) {
        if (timer) clearTimeout(timer);
        return { ok: false, error: err && err.message ? err.message : 'nui_fetch_failed' };
      });
  }

  function createMenuInstance(config) {
    var cfg = config || {};
    var doc = cfg.doc || (typeof document !== 'undefined' ? document : null);
    var mountEl = cfg.mountEl || null;
    var toastEl = cfg.toastEl || null;
    var surfaces = {};
    var toasts = [];
    var toastSeq = 0;

    var state = {
      open: false,
      spec: null,
      stackDepth: 1,
      focusIndex: 0,
      viewState: 'ready',
      stateMeta: null,
      theme: cfg.theme || 'noir',
      density: cfg.density || 'comfortable',
      armedItemId: null,
      armedConfirm: false,
      formValues: {},
      formErrors: {},
      rangeValue: 0,
      virtualScrollTop: 0
    };

    function applyThemeAndDensity(spec) {
      var theme = (spec && spec.theme && VALID_THEMES[spec.theme]) ? spec.theme : state.theme;
      var density = (spec && spec.density && VALID_DENSITIES[spec.density]) ? spec.density : state.density;
      state.theme = theme;
      state.density = density;
      if (doc && doc.documentElement) {
        doc.documentElement.setAttribute('data-theme', theme);
        doc.documentElement.setAttribute('data-density', density);
      }
      if (mountEl && mountEl.setAttribute) {
        mountEl.setAttribute('data-theme', theme);
        mountEl.setAttribute('data-density', density);
      }
    }

    function emitIntent(detail) {
      if (typeof cfg.onIntent === 'function') {
        cfg.onIntent(detail);
        return Promise.resolve({ ok: true });
      }
      return postNui('nui:intent', detail);
    }

    function emitClose(reason) {
      state.open = false;
      state.armedConfirm = false;
      state.armedItemId = null;
      renderCurrent();
      if (typeof cfg.onClose === 'function') {
        cfg.onClose({ reason: reason || 'closed' });
        return Promise.resolve({ ok: true });
      }
      return postNui('nui:close', { reason: reason || 'closed' });
    }

    function emitBack() {
      if (typeof cfg.onBack === 'function') {
        cfg.onBack({ menuId: state.spec ? state.spec.id : '' });
        return Promise.resolve({ ok: true });
      }
      return postNui('nui:back', { menuId: state.spec ? state.spec.id : '' });
    }

    function registerSurface(name, renderFn) {
      if (typeof name !== 'string' || !name) {
        throw new Error('registerSurface requires a non-empty surface name');
      }
      if (typeof renderFn !== 'function') {
        throw new Error('registerSurface requires a render function');
      }
      surfaces[name] = renderFn;
      globalSurfaces[name] = renderFn;
    }

    function getSurfaces() {
      var merged = Object.assign({}, globalSurfaces, surfaces);
      return Object.keys(merged);
    }

    function renderErrorState(title, message, retryIntent) {
      return '<div class="state-panel error" data-cm-state="error">' +
        '<span class="badge tone-danger">ERROR</span>' +
        '<div class="menu-title" style="font-size:18px;">' + escapeHtml(title || '加载失败') + '</div>' +
        '<div class="row-sub" style="max-width:360px;">' + escapeHtml(message || '无法加载菜单内容，请稍后重试。') + '</div>' +
        (retryIntent ? '<button type="button" class="btn-hud danger" data-retry-intent="' + escapeHtml(retryIntent) + '">重试 [Enter]</button>' : '') +
      '</div>';
    }

    function renderLoadingState(title, message) {
      return '<div class="state-panel" data-cm-state="loading">' +
        '<div class="spinner-ring" aria-hidden="true"></div>' +
        '<div class="menu-title" style="font-size:18px;">' + escapeHtml(title || '正在同步数据...') + '</div>' +
        '<div class="row-sub">' + escapeHtml(message || '请稍候') + '</div>' +
        '<div class="skeleton-stack"><div class="skeleton-bar"></div><div class="skeleton-bar" style="width:76%;"></div></div>' +
      '</div>';
    }

    function renderEmptyState(title, message) {
      return '<div class="state-panel" data-cm-state="empty">' +
        '<span class="icon-box" style="width:42px;height:42px;">' + iconSvg('box') + '</span>' +
        '<div class="menu-title" style="font-size:18px;">' + escapeHtml(title || '暂无内容') + '</div>' +
        '<div class="row-sub" style="max-width:340px;">' + escapeHtml(message || '当前列表为空。') + '</div>' +
      '</div>';
    }

    function isFocusableItem(item) {
      return Boolean(item && item.kind !== 'info');
    }

    function findFirstFocusableIndex(items) {
      if (!Array.isArray(items) || items.length === 0) return -1;
      for (var i = 0; i < items.length; i++) {
        if (isFocusableItem(items[i])) return i;
      }
      return -1;
    }

    function findNextFocusableIndex(items, currentIndex, delta) {
      if (!Array.isArray(items) || items.length === 0) return -1;
      var len = items.length;
      var start = (typeof currentIndex === 'number' && currentIndex >= 0 && currentIndex < len)
        ? currentIndex
        : (delta > 0 ? -1 : 0);
      for (var step = 1; step <= len; step++) {
        var candidate = (start + delta * step + len * 2) % len;
        if (isFocusableItem(items[candidate])) {
          return candidate;
        }
      }
      return -1;
    }

    function renderListRow(it, idx, focused) {
      var isInfo = it.kind === 'info';
      var isDanger = it.tone === 'danger' || it.danger === true;
      var cls = 'menu-row' +
        (isInfo ? ' info-row' : '') +
        (!isInfo && focused ? ' focused' : '') +
        (isDanger ? ' tone-danger' : '') +
        (!isInfo && it.disabled ? ' disabled' : '');

      var rightHtml = '';
      if (isInfo) {
        if (it.hint !== undefined && it.hint !== null && it.hint !== '') {
          rightHtml = '<span class="row-hint tabular">' + escapeHtml(it.hint) + '</span>';
        }
      } else if (it.kind === 'toggle') {
        var on = Boolean(it.checked !== undefined ? it.checked : it.value);
        rightHtml = '<span class="hud-switch' + (on ? ' on' : '') + '"><span class="hud-switch-knob"></span></span>';
      } else if (it.kind === 'progress') {
        var max = Number(it.progressMax) > 0 ? Number(it.progressMax) : 100;
        var val = clampNumber(it.progress !== undefined ? it.progress : it.value, 0, max);
        var pct = Math.round((val / max) * 100);
        rightHtml = '<span class="row-hint tabular">' + val + '/' + max + ' (' + pct + '%)</span>';
      } else if (it.kind === 'nav') {
        rightHtml = '<span class="row-hint">' + escapeHtml(it.hint || '›') + '</span>';
      } else if (it.kind === 'confirm') {
        var isArmed = state.armedItemId === it.id;
        rightHtml = '<span class="badge tone-danger">' + escapeHtml(isArmed ? '再次确认' : (it.hint || '高危')) + '</span>';
      } else if (it.hint) {
        rightHtml = '<span class="row-hint tabular">' + escapeHtml(it.hint) + '</span>';
      }

      var subHtml = '';
      if (!isInfo && it.disabled && it.disabledReason) {
        subHtml = '<div class="row-disabled-reason">' + escapeHtml(it.disabledReason) + '</div>';
      } else if (it.description || it.subtitle) {
        subHtml = '<div class="row-sub">' + escapeHtml(it.description || it.subtitle) + '</div>';
      }

      var progressBar = '';
      if (it.kind === 'progress') {
        var pMax = Number(it.progressMax) > 0 ? Number(it.progressMax) : 100;
        var pVal = clampNumber(it.progress !== undefined ? it.progress : it.value, 0, pMax);
        progressBar = '<div class="progress-track"><div class="progress-fill" style="transform:scaleX(' + (pVal / pMax).toFixed(4) + ');"></div></div>';
      }

      var rightWrap = (!isInfo || rightHtml) ? ('<div class="row-right">' + rightHtml + '</div>') : '';

      return '<div class="' + cls + '" data-item-index="' + idx + '" data-item-id="' + escapeHtml(it.id) + '" data-item-kind="' + escapeHtml(it.kind || 'action') + '">' +
        '<div class="row-left">' +
          '<span class="icon-box">' + iconSvg(it.icon) + '</span>' +
          '<div class="row-text">' +
            '<div class="row-title-line">' +
              '<span class="row-label">' + escapeHtml(it.label) + '</span>' +
              renderBadge(it.badge, it.badgeTone) +
            '</div>' +
            subHtml +
            progressBar +
          '</div>' +
        '</div>' +
        rightWrap +
      '</div>';
    }

    function getVirtualRowHeight() {
      return state.density === 'compact' ? 42 : 52;
    }

    function updateVirtualWindow(spec) {
      if (!doc) return;
      var viewport = mountEl ? mountEl.querySelector('#cm-vlist-viewport') : doc.getElementById('cm-vlist-viewport');
      var spacer = mountEl ? mountEl.querySelector('#cm-vlist-spacer') : doc.getElementById('cm-vlist-spacer');
      if (!viewport || !spacer) return;

      var items = spec.items || [];
      var rowH = getVirtualRowHeight();
      var total = items.length;
      var viewH = viewport.clientHeight || 360;
      spacer.style.height = (total * rowH) + 'px';

      var scrollTop = viewport.scrollTop;
      var overscan = 3;
      var startIdx = Math.max(0, Math.floor(scrollTop / rowH) - overscan);
      var endIdx = Math.min(total - 1, Math.ceil((scrollTop + viewH) / rowH) + overscan);

      var win = spacer.querySelector('#cm-vlist-window');
      if (!win) {
        win = doc.createElement('div');
        win.id = 'cm-vlist-window';
        win.className = 'vlist-window';
        spacer.appendChild(win);
      }
      win.style.transform = 'translate3d(0,' + (startIdx * rowH) + 'px,0)';

      var html = '';
      for (var i = startIdx; i <= endIdx; i++) {
        var it = items[i];
        var isInfo = it.kind === 'info';
        var focused = !isInfo && i === state.focusIndex;
        var vcls = 'vlist-row' +
          (isInfo ? ' info-row' : '') +
          (focused ? ' focused' : '') +
          (!isInfo && it.disabled ? ' disabled' : '');
        var vHint = isInfo ? (it.hint || '') : (it.disabled && it.disabledReason ? it.disabledReason : (it.hint || ''));
        html += '<div class="' + vcls + '" style="height:' + rowH + 'px;" data-item-index="' + i + '" data-item-id="' + escapeHtml(it.id) + '" data-item-kind="' + escapeHtml(it.kind || 'action') + '">' +
          '<div class="row-left">' +
            '<span class="icon-box" style="width:24px;height:24px;">' + iconSvg(it.icon) + '</span>' +
            '<span class="row-label">' + escapeHtml(it.label) + '</span>' +
            renderBadge(it.badge, it.badgeTone) +
          '</div>' +
          '<span class="row-hint tabular">' + escapeHtml(vHint) + '</span>' +
        '</div>';
      }
      win.innerHTML = html;

      var cntEl = mountEl ? mountEl.querySelector('#cm-vlist-dom-count') : doc.getElementById('cm-vlist-dom-count');
      if (cntEl) cntEl.textContent = String(endIdx - startIdx + 1) + ' / ' + String(total);
    }

    function ensureVirtualVisible(index) {
      if (!mountEl) return;
      var viewport = mountEl.querySelector('#cm-vlist-viewport');
      if (!viewport) return;
      var rowH = getVirtualRowHeight();
      var top = index * rowH;
      var bot = top + rowH;
      if (top < viewport.scrollTop) {
        viewport.scrollTop = top;
      } else if (bot > viewport.scrollTop + viewport.clientHeight) {
        viewport.scrollTop = bot - viewport.clientHeight;
      }
      state.virtualScrollTop = viewport.scrollTop;
    }

    registerSurface('list', function (spec) {
      var items = spec.items || [];
      if (!items.length) {
        return renderEmptyState('暂无选项', spec.emptyMessage || '当前菜单没有可展示的项目。');
      }
      if (items.length >= VIRTUAL_THRESHOLD) {
        return '<div class="vlist-telemetry">' +
          '<span>虚拟列表 · 共 <strong class="tabular">' + items.length + '</strong> 项</span>' +
          '<span>渲染窗口: <strong class="tabular" id="cm-vlist-dom-count">0 / ' + items.length + '</strong></span>' +
        '</div>' +
        '<div class="vlist-viewport" id="cm-vlist-viewport">' +
          '<div class="vlist-spacer" id="cm-vlist-spacer"></div>' +
        '</div>';
      }
      var html = '<div class="item-list">';
      var lastGroup = null;
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        if (it.group && it.group !== lastGroup) {
          lastGroup = it.group;
          html += '<div class="menu-group-header">' + escapeHtml(it.group) + '</div>';
        }
        html += renderListRow(it, i, i === state.focusIndex);
      }
      html += '</div>';
      return html;
    });

    function initFormValues(spec) {
      state.formValues = {};
      state.formErrors = {};
      var items = spec.items || [];
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        if (it.kind === 'input') {
          var initVal = it.value !== undefined ? it.value : (it.defaultValue !== undefined ? it.defaultValue : '');
          state.formValues[it.id] = initVal;
        } else if (it.kind === 'range') {
          var minV = typeof it.min === 'number' ? it.min : 0;
          var maxV = typeof it.max === 'number' ? it.max : 100;
          var startVal = it.value !== undefined ? it.value : (it.defaultValue !== undefined ? it.defaultValue : minV);
          state.formValues[it.id] = clampNumber(startVal, minV, maxV);
        } else if (it.kind === 'toggle') {
          state.formValues[it.id] = Boolean(it.checked !== undefined ? it.checked : it.value);
        }
      }
      if (spec.surface === 'range') {
        var firstRange = null;
        for (var j = 0; j < items.length; j++) {
          if (items[j].kind === 'range') {
            firstRange = items[j];
            break;
          }
        }
        if (firstRange) {
          state.rangeValue = clampNumber(
            firstRange.value !== undefined ? firstRange.value : firstRange.min,
            typeof firstRange.min === 'number' ? firstRange.min : 0,
            typeof firstRange.max === 'number' ? firstRange.max : 100
          );
        } else {
          state.rangeValue = 0;
        }
      }
    }

    function validateFormSpec(spec) {
      var errors = {};
      var valid = true;
      var items = spec.items || [];
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        if (it.kind !== 'input' && it.kind !== 'range') continue;
        var val = state.formValues[it.id];
        if (it.kind === 'input') {
          var str = String(val === undefined || val === null ? '' : val);
          if (it.required && !str.trim()) {
            errors[it.id] = '此字段为必填项';
            valid = false;
            continue;
          }
          if (it.inputType === 'number') {
            if (str !== '' && !isFinite(Number(str))) {
              errors[it.id] = '请输入有效数字';
              valid = false;
              continue;
            }
            var n = Number(str);
            if (typeof it.min === 'number' && n < it.min) {
              errors[it.id] = '不能小于 ' + it.min;
              valid = false;
              continue;
            }
            if (typeof it.max === 'number' && n > it.max) {
              errors[it.id] = '不能大于 ' + it.max;
              valid = false;
              continue;
            }
          } else {
            if (typeof it.minLength === 'number' && str.length < it.minLength) {
              errors[it.id] = '长度不能少于 ' + it.minLength + ' 个字符';
              valid = false;
              continue;
            }
            if (typeof it.maxLength === 'number' && str.length > it.maxLength) {
              errors[it.id] = '长度不能超过 ' + it.maxLength + ' 个字符';
              valid = false;
              continue;
            }
            if (typeof it.pattern === 'string' && it.pattern) {
              var re = new RegExp(it.pattern);
              if (!re.test(str)) {
                errors[it.id] = '格式不符合要求';
                valid = false;
                continue;
              }
            }
          }
        }
      }
      state.formErrors = errors;
      return valid;
    }

    registerSurface('form', function (spec) {
      var items = spec.items || [];
      var html = '<div class="form-stack">';
      for (var i = 0; i < items.length; i++) {
        var it = items[i];
        var focused = i === state.focusIndex;
        var err = state.formErrors[it.id];
        var cls = 'form-field' + (focused ? ' focused' : '') + (err ? ' invalid' : '');

        if (it.kind === 'input') {
          var val = state.formValues[it.id] !== undefined ? state.formValues[it.id] : '';
          if (it.inputType === 'number') {
            var step = Number(it.step) > 0 ? Number(it.step) : 1;
            html += '<div class="' + cls + '" data-item-index="' + i + '">' +
              '<div class="form-label-row"><span>' + escapeHtml(it.label) + '</span><span class="row-sub">' + escapeHtml(it.hint || '') + '</span></div>' +
              '<div class="num-stepper">' +
                '<button type="button" class="btn-hud" data-step-id="' + escapeHtml(it.id) + '" data-step-delta="' + (-step) + '">-</button>' +
                '<input type="number" class="hud-input tabular" data-form-id="' + escapeHtml(it.id) + '" value="' + escapeHtml(val) + '" placeholder="' + escapeHtml(it.placeholder || '') + '" />' +
                '<button type="button" class="btn-hud" data-step-id="' + escapeHtml(it.id) + '" data-step-delta="' + step + '">+</button>' +
              '</div>' +
              (err ? '<div class="field-error">' + escapeHtml(err) + '</div>' : '') +
            '</div>';
          } else {
            var typeAttr = it.inputType === 'password' ? 'password' : 'text';
            html += '<div class="' + cls + '" data-item-index="' + i + '">' +
              '<div class="form-label-row"><span>' + escapeHtml(it.label) + '</span><span class="row-sub">' + escapeHtml(it.hint || '') + '</span></div>' +
              '<input type="' + typeAttr + '" class="hud-input" data-form-id="' + escapeHtml(it.id) + '" value="' + escapeHtml(val) + '" placeholder="' + escapeHtml(it.placeholder || '') + '" />' +
              (err ? '<div class="field-error">' + escapeHtml(err) + '</div>' : '') +
            '</div>';
          }
        } else if (it.kind === 'range') {
          var minV = typeof it.min === 'number' ? it.min : 0;
          var maxV = typeof it.max === 'number' ? it.max : 100;
          var stepV = Number(it.step) > 0 ? Number(it.step) : 1;
          var rVal = clampNumber(state.formValues[it.id], minV, maxV);
          var unit = it.unit || '';
          html += '<div class="' + cls + '" data-item-index="' + i + '">' +
            '<div class="form-label-row"><span>' + escapeHtml(it.label) + '</span><span class="tabular" style="color:var(--accent);">' + rVal + escapeHtml(unit) + '</span></div>' +
            '<div class="range-wrap">' +
              '<span class="tabular row-sub">' + minV + escapeHtml(unit) + '</span>' +
              '<input type="range" class="hud-range" data-range-id="' + escapeHtml(it.id) + '" min="' + minV + '" max="' + maxV + '" step="' + stepV + '" value="' + rVal + '" />' +
              '<span class="tabular row-sub">' + maxV + escapeHtml(unit) + '</span>' +
            '</div>' +
          '</div>';
        } else {
          var copy = Object.assign({}, it);
          if (it.kind === 'toggle') copy.checked = Boolean(state.formValues[it.id]);
          html += renderListRow(copy, i, focused);
        }
      }
      html += '</div>' +
        '<div class="surface-actions">' +
          '<button type="button" class="btn-hud" data-form-cancel="1">' + escapeHtml(spec.cancelLabel || '取消 [Esc]') + '</button>' +
          '<button type="button" class="btn-hud primary" data-form-submit="1">' + escapeHtml(spec.submitLabel || '提交 [Enter]') + '</button>' +
        '</div>';
      return html;
    });

    registerSurface('confirm', function (spec) {
      var isDanger = spec.danger === true;
      var needsDouble = isDanger && spec.doubleConfirm !== false;
      var armed = state.armedConfirm === true;
      var summaryHtml = '';
      var items = spec.items || [];
      if (items.length > 0) {
        summaryHtml += '<div class="item-list">';
        for (var i = 0; i < items.length; i++) {
          summaryHtml += renderListRow(items[i], i, false);
        }
        summaryHtml += '</div>';
      }
      var confirmBtnLabel = armed ? '再次确认执行 [Enter]' : (spec.confirmLabel || (isDanger ? '确认危险操作' : '确认 [Enter]'));
      return '<div class="confirm-card' + (isDanger ? ' danger' : '') + '">' +
        '<div class="row-title-line">' +
          '<span class="badge ' + (isDanger ? 'tone-danger' : 'tone-accent') + '">' + (isDanger ? '高危确认' : '普通确认') + '</span>' +
        '</div>' +
        '<p class="confirm-msg">' + escapeHtml(spec.message || spec.subtitle || '请确认是否继续执行此操作？') + '</p>' +
        summaryHtml +
        (needsDouble && armed ? '<div class="confirm-arm-hint">已进入二次确认状态：再次按 Enter 或点击按钮将立即执行。</div>' : '') +
      '</div>' +
      '<div class="surface-actions">' +
        '<button type="button" class="btn-hud" data-confirm-cancel="1">' + escapeHtml(spec.cancelLabel || '取消 [Esc]') + '</button>' +
        '<button type="button" class="btn-hud ' + (isDanger ? ('danger' + (armed ? ' armed' : '')) : 'primary') + '" data-confirm-ok="1">' + escapeHtml(confirmBtnLabel) + '</button>' +
      '</div>';
    });

    registerSurface('range', function (spec) {
      var items = spec.items || [];
      var target = null;
      for (var i = 0; i < items.length; i++) {
        if (items[i].kind === 'range') {
          target = items[i];
          break;
        }
      }
      var minV = target && typeof target.min === 'number' ? target.min : 0;
      var maxV = target && typeof target.max === 'number' ? target.max : 100;
      var stepV = target && Number(target.step) > 0 ? Number(target.step) : 1;
      var unit = target && target.unit ? target.unit : '';
      var cur = clampNumber(state.rangeValue, minV, maxV);
      return '<div class="range-hero">' +
        '<div class="form-label-row">' +
          '<span>' + escapeHtml(target ? target.label : spec.title) + '</span>' +
          '<span class="range-hero-readout tabular" id="cm-range-readout">' + cur + escapeHtml(unit) + '</span>' +
        '</div>' +
        '<div class="range-wrap">' +
          '<button type="button" class="btn-hud" data-range-step="' + (-stepV) + '">-</button>' +
          '<input type="range" class="hud-range" id="cm-standalone-range" min="' + minV + '" max="' + maxV + '" step="' + stepV + '" value="' + cur + '" />' +
          '<button type="button" class="btn-hud" data-range-step="' + stepV + '">+</button>' +
        '</div>' +
        '<div class="form-label-row" style="margin-bottom:0;">' +
          '<span class="row-sub tabular">' + minV + escapeHtml(unit) + '</span>' +
          '<span class="row-sub tabular">' + maxV + escapeHtml(unit) + '</span>' +
        '</div>' +
      '</div>' +
      '<div class="surface-actions">' +
        '<button type="button" class="btn-hud" data-range-cancel="1">' + escapeHtml(spec.cancelLabel || '取消 [Esc]') + '</button>' +
        '<button type="button" class="btn-hud primary" data-range-submit="1">' + escapeHtml(spec.submitLabel || '应用 [Enter]') + '</button>' +
      '</div>';
    });

    function buildBreadcrumbsHtml(spec) {
      var crumbs = Array.isArray(spec.breadcrumbs) && spec.breadcrumbs.length ? spec.breadcrumbs : [spec.title];
      var out = '<nav class="menu-breadcrumb" aria-label="Breadcrumb">';
      for (var i = 0; i < crumbs.length; i++) {
        if (i > 0) out += '<span class="crumb-sep">/</span>';
        if (i === crumbs.length - 1) {
          out += '<span class="crumb-current">' + escapeHtml(crumbs[i]) + '</span>';
        } else {
          out += '<span>' + escapeHtml(crumbs[i]) + '</span>';
        }
      }
      out += '</nav>';
      return out;
    }

    function renderToasts() {
      if (!toastEl) return;
      var html = '';
      for (var i = 0; i < toasts.length; i++) {
        var t = toasts[i];
        var tone = t.tone || 'info';
        var dur = Number(t.durationMs) > 0 ? Number(t.durationMs) : 3500;
        html += '<div class="toast-card tone-' + escapeHtml(tone) + '" data-toast-id="' + escapeHtml(t.id) + '">' +
          '<div class="toast-head">' +
            '<span>' + escapeHtml(t.title || '提示') + '</span>' +
            '<button type="button" class="toast-close" data-dismiss-toast="' + escapeHtml(t.id) + '" aria-label="关闭">&times;</button>' +
          '</div>' +
          (t.message ? '<div class="toast-msg">' + escapeHtml(t.message) + '</div>' : '') +
          '<div class="toast-timer"><div class="toast-timer-bar" style="animation-duration:' + dur + 'ms;"></div></div>' +
        '</div>';
      }
      toastEl.innerHTML = html;
    }

    function pushToast(titleOrOpts, message, tone, durationMs) {
      var opts = typeof titleOrOpts === 'object' && titleOrOpts !== null
        ? titleOrOpts
        : { title: titleOrOpts, message: message, tone: tone, durationMs: durationMs };
      var id = 'toast_' + (++toastSeq);
      var dur = Number(opts.durationMs) > 0 ? Number(opts.durationMs) : 3500;
      var entry = {
        id: id,
        title: String(opts.title || '通知'),
        message: String(opts.message || ''),
        tone: opts.tone === 'warning' || opts.tone === 'danger' || opts.tone === 'success' ? opts.tone : 'info',
        durationMs: dur
      };
      toasts.unshift(entry);
      if (toasts.length > 4) toasts = toasts.slice(0, 4);
      renderToasts();
      if (typeof setTimeout === 'function') {
        setTimeout(function () {
          dismissToast(id);
        }, dur);
      }
      return id;
    }

    function dismissToast(id) {
      var before = toasts.length;
      toasts = toasts.filter(function (t) { return t.id !== id; });
      if (toasts.length !== before) {
        renderToasts();
        if (typeof cfg.onToastDismiss === 'function') {
          cfg.onToastDismiss({ id: id });
        } else {
          postNui('nui:toastDismiss', { id: id });
        }
      }
    }

    function triggerNudge() {
      if (!mountEl) return;
      var shell = mountEl.querySelector('.menu-shell');
      if (!shell) return;
      shell.classList.remove('nudge');
      void shell.offsetWidth;
      shell.classList.add('nudge');
    }

    function activateItem(idx) {
      var spec = state.spec;
      if (!spec || !Array.isArray(spec.items)) return;
      var item = spec.items[idx];
      if (!item || item.kind === 'info') return;

      if (item.disabled) {
        triggerNudge();
        pushToast({ title: '操作不可用', message: item.disabledReason || '当前条件未满足', tone: 'warning', durationMs: 2800 });
        return;
      }

      if (item.kind === 'toggle') {
        if (spec.surface === 'form') {
          state.formValues[item.id] = !state.formValues[item.id];
        } else {
          item.checked = !(item.checked !== undefined ? item.checked : item.value);
        }
        renderCurrent();
        if (item.intent) {
          emitIntent({ menuId: spec.id, itemId: item.id, intent: item.intent, args: item.args || {}, values: { checked: Boolean(spec.surface === 'form' ? state.formValues[item.id] : item.checked) } });
        }
        return;
      }

      if (item.kind === 'confirm' && item.doubleConfirm !== false) {
        if (state.armedItemId !== item.id) {
          state.armedItemId = item.id;
          renderCurrent();
          pushToast({ title: '请再次确认', message: item.confirmMessage || ('再次按 Enter 执行：' + item.label), tone: 'danger', durationMs: 3000 });
          return;
        }
        state.armedItemId = null;
        renderCurrent();
      }

      if (item.kind === 'progress') {
        return;
      }

      if (item.intent) {
        emitIntent({ menuId: spec.id, itemId: item.id, intent: item.intent, args: item.args || {} });
      }
    }

    function submitForm() {
      var spec = state.spec;
      if (!spec || spec.surface !== 'form') return;
      if (!validateFormSpec(spec)) {
        triggerNudge();
        renderCurrent();
        pushToast({ title: '校验未通过', message: '请修正标红字段后再提交', tone: 'danger', durationMs: 2600 });
        return;
      }
      renderCurrent();
      if (spec.intent) {
        emitIntent({
          menuId: spec.id,
          itemId: '__form__',
          intent: spec.intent,
          values: Object.assign({}, state.formValues)
        });
      }
    }

    function submitConfirm() {
      var spec = state.spec;
      if (!spec || spec.surface !== 'confirm') return;
      if (spec.danger && spec.doubleConfirm !== false && !state.armedConfirm) {
        state.armedConfirm = true;
        renderCurrent();
        return;
      }
      state.armedConfirm = false;
      if (spec.intent) {
        emitIntent({ menuId: spec.id, itemId: '__confirm__', intent: spec.intent, args: {} });
      }
      if (spec.closeOnSubmit !== false) {
        emitClose('confirm_submitted');
      }
    }

    function submitRange() {
      var spec = state.spec;
      if (!spec || spec.surface !== 'range') return;
      var items = spec.items || [];
      var target = null;
      for (var i = 0; i < items.length; i++) {
        if (items[i].kind === 'range') {
          target = items[i];
          break;
        }
      }
      var intent = spec.intent || (target && target.intent) || '';
      var itemId = target ? target.id : '__range__';
      if (intent) {
        emitIntent({ menuId: spec.id, itemId: itemId, intent: intent, values: { value: state.rangeValue } });
      }
    }

    function render(targetEl, spec, opts) {
      if (targetEl && !mountEl) mountEl = targetEl;
      if (!spec || typeof spec !== 'object') {
        var invalidRes = { ok: false, error: 'invalid_spec' };
        if (targetEl) targetEl.innerHTML = renderErrorState('规格无效', 'MenuSpec 必须是对象。');
        return invalidRes;
      }

      var surfaceFn = surfaces[spec.surface] || globalSurfaces[spec.surface];
      if (typeof surfaceFn !== 'function') {
        var missingErr = 'unregistered_surface:' + String(spec.surface);
        if (targetEl) {
          targetEl.classList.remove('is-hidden');
          targetEl.innerHTML = '<div class="menu-shell"><div class="menu-body">' +
            renderErrorState('未注册界面类型', '不支持的 surface: ' + String(spec.surface)) +
          '</div></div>';
        }
        return { ok: false, error: missingErr };
      }

      state.open = true;
      var isNewSpec = !state.spec || state.spec.id !== spec.id || (opts && opts.resetState);
      state.spec = spec;
      if (opts && typeof opts.stackDepth === 'number') state.stackDepth = opts.stackDepth;
      if (isNewSpec) {
        state.focusIndex = findFirstFocusableIndex(spec.items);
        state.armedItemId = null;
        state.armedConfirm = false;
        state.virtualScrollTop = 0;
        state.viewState = (opts && opts.viewState) || 'ready';
        initFormValues(spec);
      }
      applyThemeAndDensity(spec);

      var bodyHtml = '';
      if (state.viewState === 'loading') {
        bodyHtml = renderLoadingState(state.stateMeta && state.stateMeta.title, state.stateMeta && state.stateMeta.message);
      } else if (state.viewState === 'error') {
        bodyHtml = renderErrorState(state.stateMeta && state.stateMeta.title, state.stateMeta && state.stateMeta.message, state.stateMeta && state.stateMeta.retryIntent);
      } else if (state.viewState === 'empty') {
        bodyHtml = renderEmptyState(state.stateMeta && state.stateMeta.title, state.stateMeta && state.stateMeta.message);
      } else {
        bodyHtml = surfaceFn(spec, state);
      }

      var totalCount = Array.isArray(spec.items) ? spec.items.length : 0;
      var counterText = spec.surface === 'list' && totalCount > 0
        ? String(state.focusIndex >= 0 ? Math.min(state.focusIndex + 1, totalCount) : 0) + ' / ' + String(totalCount)
        : (state.stackDepth > 1 ? ('L' + state.stackDepth) : 'HUD');

      var shellHtml = '<div class="menu-shell' + (spec.danger ? ' danger-shell' : '') + '">' +
        '<header class="menu-header">' +
          buildBreadcrumbsHtml(spec) +
          '<div class="menu-title-row">' +
            '<div>' +
              '<h2 class="menu-title">' + escapeHtml(spec.title) + '</h2>' +
              (spec.subtitle ? '<div class="menu-subtitle">' + escapeHtml(spec.subtitle) + '</div>' : '') +
            '</div>' +
            '<div class="menu-header-right"><span class="counter-pill tabular">' + escapeHtml(counterText) + '</span></div>' +
          '</div>' +
        '</header>' +
        '<div class="menu-body">' + bodyHtml + '</div>' +
        '<footer class="menu-footer">' +
          '<div class="keyhints">' +
            '<span class="keyhint"><kbd class="kbd">↑↓</kbd> 移动</span>' +
            '<span class="keyhint"><kbd class="kbd">Enter</kbd> 确认</span>' +
            '<span class="keyhint"><kbd class="kbd">Backspace</kbd> 返回</span>' +
            '<span class="keyhint"><kbd class="kbd">Esc</kbd> 关闭</span>' +
          '</div>' +
          '<span class="tabular">CUSTOM-MENU</span>' +
        '</footer>' +
      '</div>';

      if (targetEl) {
        targetEl.classList.remove('is-hidden');
        targetEl.innerHTML = shellHtml;
        if (state.viewState === 'ready' && spec.surface === 'list' && totalCount >= VIRTUAL_THRESHOLD) {
          var vp = targetEl.querySelector('#cm-vlist-viewport');
          if (vp) {
            vp.scrollTop = state.virtualScrollTop;
            vp.onscroll = function () {
              state.virtualScrollTop = vp.scrollTop;
              updateVirtualWindow(spec);
            };
          }
          updateVirtualWindow(spec);
        }
      }

      return { ok: true, html: shellHtml };
    }

    // ── 选中态就地更新：方向键只改 class，不重建 DOM ─────────────────────
    // 为什么：每次移动都整表重渲染会闪一下（肉眼可见），而且表单里的 <input> 会被换成
    // 新节点 → 光标丢失、输入直接断掉（2026-11-26 真机反馈）。列表行本来就带
    // data-item-index，改一个 class 就够了。
    function applyFocusClass() {
      if (!mountEl) return;
      var rows = mountEl.querySelectorAll('[data-item-index]');
      for (var i = 0; i < rows.length; i++) {
        var idx = Number(rows[i].getAttribute('data-item-index'));
        var kind = rows[i].getAttribute('data-item-kind');
        var on = kind !== 'info' && idx === state.focusIndex;
        if (on) { rows[i].classList.add('focused'); } else { rows[i].classList.remove('focused'); }
        if (kind !== 'info') {
          rows[i].setAttribute('aria-selected', on ? 'true' : 'false');
        }
      }
      var cur = state.focusIndex >= 0 ? mountEl.querySelector('[data-item-index="' + state.focusIndex + '"]') : null;
      if (cur && typeof cur.scrollIntoView === 'function') {
        cur.scrollIntoView({ block: 'nearest' });
      }
    }

    // ── 重渲染时保住输入焦点 ────────────────────────────────────────────
    // 有些重渲染躲不掉（toggle / 二次确认 / 校验失败）。这类重渲染必须把焦点和光标
    // 位置还回去，否则玩家正在输的车牌号会在按 Enter 之后丢一半。
    function focusKeyOf(el) {
      if (!el) return null;
      if (el.getAttribute && el.getAttribute('data-form-id')) return 'form:' + el.getAttribute('data-form-id');
      if (el.getAttribute && el.getAttribute('data-range-id')) return 'range:' + el.getAttribute('data-range-id');
      if (el.id) return 'id:' + el.id;
      return null;
    }

    function captureFocus() {
      if (!doc || !doc.activeElement || !mountEl || !mountEl.contains(doc.activeElement)) return null;
      var el = doc.activeElement;
      return {
        key: focusKeyOf(el),
        start: typeof el.selectionStart === 'number' ? el.selectionStart : null,
        end: typeof el.selectionEnd === 'number' ? el.selectionEnd : null
      };
    }

    function restoreFocus(snap) {
      if (!snap || !snap.key || !mountEl) return;
      var sel = null;
      if (snap.key.indexOf('form:') === 0) {
        sel = '[data-form-id="' + snap.key.slice(5) + '"]';
      } else if (snap.key.indexOf('range:') === 0) {
        sel = '[data-range-id="' + snap.key.slice(6) + '"]';
      } else if (snap.key.indexOf('id:') === 0) {
        sel = '#' + snap.key.slice(3);
      }
      if (!sel) return;
      var el = mountEl.querySelector(sel);
      if (!el || typeof el.focus !== 'function') return;
      el.focus({ preventScroll: true });
      if (snap.start !== null && typeof el.setSelectionRange === 'function') {
        try { el.setSelectionRange(snap.start, snap.end === null ? snap.start : snap.end); } catch (err) { /* range 不支持 */ }
      }
    }

    function renderCurrent() {
      if (!mountEl) return { ok: false, error: 'no_mount' };
      if (!state.open || !state.spec) {
        mountEl.classList.add('is-hidden');
        mountEl.innerHTML = '';
        return { ok: true, closed: true };
      }
      var snap = captureFocus();
      var out = render(mountEl, state.spec);
      restoreFocus(snap);
      return out;
    }

    function setState(viewState, meta) {
      state.viewState = viewState || 'ready';
      state.stateMeta = meta || null;
      return renderCurrent();
    }

    function handleKeyDown(e) {
      if (!state.open || !state.spec) return;
      var key = e.key;
      var activeTag = doc && doc.activeElement ? String(doc.activeElement.tagName || '').toLowerCase() : '';
      var isTextInput = activeTag === 'input' && doc.activeElement.type !== 'range';

      if (key === 'Tab') {
        e.preventDefault();
        return;
      }
      if (key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        emitClose('nui_esc');
        return;
      }
      if (key === 'Backspace' && !isTextInput) {
        e.preventDefault();
        e.stopPropagation();
        if (state.armedConfirm) {
          state.armedConfirm = false;
          renderCurrent();
          return;
        }
        emitBack();
        return;
      }

      var spec = state.spec;
      var items = spec.items || [];

      if (key === 'ArrowDown' && items.length > 0 && spec.surface !== 'confirm' && spec.surface !== 'range') {
        e.preventDefault();
        state.focusIndex = findNextFocusableIndex(items, state.focusIndex, 1);
        state.armedItemId = null;
        if (spec.surface === 'list' && items.length >= VIRTUAL_THRESHOLD) {
          if (state.focusIndex >= 0) ensureVirtualVisible(state.focusIndex);
          updateVirtualWindow(spec);
          applyFocusClass();
        } else {
          // 就地改 class：整表重渲染会闪一下，并且会换掉表单里的 <input>（光标丢失）
          applyFocusClass();
        }
        return;
      }

      if (key === 'ArrowUp' && items.length > 0 && spec.surface !== 'confirm' && spec.surface !== 'range') {
        e.preventDefault();
        state.focusIndex = findNextFocusableIndex(items, state.focusIndex, -1);
        state.armedItemId = null;
        if (spec.surface === 'list' && items.length >= VIRTUAL_THRESHOLD) {
          if (state.focusIndex >= 0) ensureVirtualVisible(state.focusIndex);
          updateVirtualWindow(spec);
          applyFocusClass();
        } else {
          applyFocusClass();
        }
        return;
      }

      if ((key === 'ArrowLeft' || key === 'ArrowRight') && !isTextInput) {
        var deltaSign = key === 'ArrowRight' ? 1 : -1;
        if (spec.surface === 'range') {
          e.preventDefault();
          var rItem = items.find(function (x) { return x.kind === 'range'; }) || {};
          var step = Number(rItem.step) > 0 ? Number(rItem.step) : 1;
          state.rangeValue = clampNumber(state.rangeValue + deltaSign * step, typeof rItem.min === 'number' ? rItem.min : 0, typeof rItem.max === 'number' ? rItem.max : 100);
          renderCurrent();
          return;
        }
        if (spec.surface === 'form' && items[state.focusIndex]) {
          var fi = items[state.focusIndex];
          if (fi.kind === 'range') {
            e.preventDefault();
            var fStep = Number(fi.step) > 0 ? Number(fi.step) : 1;
            state.formValues[fi.id] = clampNumber(Number(state.formValues[fi.id] || 0) + deltaSign * fStep, typeof fi.min === 'number' ? fi.min : 0, typeof fi.max === 'number' ? fi.max : 100);
            renderCurrent();
            return;
          }
          if (fi.inputType === 'number') {
            e.preventDefault();
            var nStep = Number(fi.step) > 0 ? Number(fi.step) : 1;
            state.formValues[fi.id] = clampNumber(Number(state.formValues[fi.id] || 0) + deltaSign * nStep, fi.min, fi.max);
            renderCurrent();
            return;
          }
          if (fi.kind === 'toggle') {
            e.preventDefault();
            state.formValues[fi.id] = !state.formValues[fi.id];
            renderCurrent();
            return;
          }
        }
      }

      if (key === 'Enter') {
        e.preventDefault();
        if (spec.surface === 'confirm') {
          submitConfirm();
        } else if (spec.surface === 'range') {
          submitRange();
        } else if (spec.surface === 'form') {
          if (items[state.focusIndex] && items[state.focusIndex].kind === 'toggle' && !isTextInput) {
            activateItem(state.focusIndex);
          } else {
            submitForm();
          }
        } else {
          activateItem(state.focusIndex);
        }
      }
    }

    function bindDomEvents() {
      if (!mountEl || !doc) return;

      mountEl.addEventListener('click', function (e) {
        var target = e.target;
        if (!target || !target.closest) return;

        var stepBtn = target.closest('[data-step-id]');
        if (stepBtn && state.spec) {
          var sId = stepBtn.getAttribute('data-step-id');
          var sDelta = Number(stepBtn.getAttribute('data-step-delta')) || 0;
          var sItem = (state.spec.items || []).find(function (x) { return x.id === sId; }) || {};
          state.formValues[sId] = clampNumber(Number(state.formValues[sId] || 0) + sDelta, sItem.min, sItem.max);
          renderCurrent();
          return;
        }

        var rStepBtn = target.closest('[data-range-step]');
        if (rStepBtn && state.spec && state.spec.surface === 'range') {
          var rItem = (state.spec.items || []).find(function (x) { return x.kind === 'range'; }) || {};
          var rDelta = Number(rStepBtn.getAttribute('data-range-step')) || 0;
          state.rangeValue = clampNumber(state.rangeValue + rDelta, typeof rItem.min === 'number' ? rItem.min : 0, typeof rItem.max === 'number' ? rItem.max : 100);
          renderCurrent();
          return;
        }

        if (target.closest('[data-form-submit]')) { submitForm(); return; }
        if (target.closest('[data-form-cancel]')) { emitClose('form_cancel'); return; }
        if (target.closest('[data-confirm-ok]')) { submitConfirm(); return; }
        if (target.closest('[data-confirm-cancel]')) {
          if (state.spec && state.spec.cancelIntent) {
            emitIntent({ menuId: state.spec.id, itemId: '__confirm_cancel__', intent: state.spec.cancelIntent, args: {} });
          }
          emitClose('confirm_cancel');
          return;
        }
        if (target.closest('[data-range-submit]')) { submitRange(); return; }
        if (target.closest('[data-range-cancel]')) { emitClose('range_cancel'); return; }

        var retryBtn = target.closest('[data-retry-intent]');
        if (retryBtn && state.spec) {
          emitIntent({ menuId: state.spec.id, itemId: '__retry__', intent: retryBtn.getAttribute('data-retry-intent'), args: {} });
          return;
        }

        var row = target.closest('[data-item-index]');
        if (row && state.spec) {
          var idx = Number(row.getAttribute('data-item-index'));
          if (isFinite(idx)) {
            var clickedItem = (state.spec.items || [])[idx];
            if (!clickedItem || clickedItem.kind === 'info') {
              return;
            }
            state.focusIndex = idx;
            if (clickedItem.kind !== 'input' && clickedItem.kind !== 'range') {
              activateItem(idx);
            } else {
              renderCurrent();
            }
          }
        }
      });

      mountEl.addEventListener('input', function (e) {
        var el = e.target;
        if (!el || !state.spec) return;
        var formId = el.getAttribute('data-form-id');
        if (formId) {
          state.formValues[formId] = el.value;
          delete state.formErrors[formId];
          return;
        }
        var rangeId = el.getAttribute('data-range-id');
        if (rangeId) {
          state.formValues[rangeId] = Number(el.value);
          var labelRow = el.closest('.form-field') && el.closest('.form-field').querySelector('.form-label-row .tabular');
          var rItem = (state.spec.items || []).find(function (x) { return x.id === rangeId; }) || {};
          if (labelRow) labelRow.textContent = String(el.value) + (rItem.unit || '');
          return;
        }
        if (el.id === 'cm-standalone-range') {
          state.rangeValue = Number(el.value);
          var stItem = (state.spec.items || []).find(function (x) { return x.kind === 'range'; }) || {};
          var readout = mountEl.querySelector('#cm-range-readout');
          if (readout) readout.textContent = String(el.value) + (stItem.unit || '');
        }
      });

      if (toastEl) {
        toastEl.addEventListener('click', function (e) {
          var btn = e.target && e.target.closest ? e.target.closest('[data-dismiss-toast]') : null;
          if (btn) {
            dismissToast(btn.getAttribute('data-dismiss-toast'));
          }
        });
      }

      if (typeof root.addEventListener === 'function') {
        root.addEventListener('keydown', handleKeyDown, true);
      }
    }

    if (mountEl) {
      bindDomEvents();
    }

    return {
      registerSurface: registerSurface,
      getSurfaces: getSurfaces,
      render: render,
      setState: setState,
      pushToast: pushToast,
      dismissToast: dismissToast,
      close: function (reason) { return emitClose(reason); },
      setTheme: function (t) { if (VALID_THEMES[t]) { state.theme = t; applyThemeAndDensity(state.spec); } },
      setDensity: function (d) { if (VALID_DENSITIES[d]) { state.density = d; applyThemeAndDensity(state.spec); } },
      getState: function () { return state; },
      handleKeyDown: handleKeyDown
    };
  }

  var defaultInstance = createMenuInstance({});

  function attachHostApp(options) {
    var inst = createMenuInstance(options || {});
    if (typeof root.addEventListener === 'function') {
      root.addEventListener('message', function (event) {
        var msg = event && event.data;
        if (!msg || typeof msg !== 'object') return;

        if (msg.action === 'menu:open') {
          inst.render(options.mountEl, msg.spec, { resetState: true, stackDepth: msg.stackDepth || 1 });
          postNui('nui:ack', { ackToken: msg.ackToken || null });
        } else if (msg.action === 'menu:update') {
          inst.render(options.mountEl, msg.spec, { resetState: true, stackDepth: msg.stackDepth || 1 });
        } else if (msg.action === 'menu:close') {
          var s = inst.getState();
          s.open = false;
          s.spec = null;
          if (options.mountEl) {
            options.mountEl.classList.add('is-hidden');
            options.mountEl.innerHTML = '';
          }
        } else if (msg.action === 'menu:state') {
          inst.setState(msg.viewState, msg.meta || null);
        } else if (msg.action === 'toast:push') {
          inst.pushToast({
            title: msg.title,
            message: msg.message,
            tone: msg.tone,
            durationMs: msg.durationMs
          });
        }
      });
    }
    return inst;
  }

  return {
    createInstance: createMenuInstance,
    attachHostApp: attachHostApp,
    postNui: postNui,
    registerSurface: defaultInstance.registerSurface,
    getSurfaces: defaultInstance.getSurfaces,
    render: defaultInstance.render,
    setState: defaultInstance.setState,
    pushToast: defaultInstance.pushToast,
    dismissToast: defaultInstance.dismissToast,
    close: defaultInstance.close,
    setTheme: defaultInstance.setTheme,
    setDensity: defaultInstance.setDensity,
    getState: defaultInstance.getState
  };
});
