<script setup lang="ts">
// tabs/PoliceConsole.vue — 🚔 警车控制台 v2.1
//
// 三段式布局:
//   上段 — 📡 实时雷达扫描 (附近车辆列表) ← 从 Lua Push 接收
//   中段 — 🚨 ANPR / 被盗车 命中提示
//   下段 — 🔧 警用工具按钮矩阵
//
// 数据流: Lua PoliceModule → SendNUIMessage('policeRadar') → App.vue → store → 本组件

import { ref, computed, onMounted } from 'vue'
import { useDashboardStore } from '../../stores/dashboard'
import { sendNui } from '../../composables/useNui'
import { useThrottle } from '../../composables/useThrottle'

const store = useDashboardStore()
const { canAct } = useThrottle(1000)

// ── 从 store 读取雷达数据 (由 Lua Push 驱动) ──
const radarTargets = computed(() => store.policeData || [])
const anprHits = computed(() => radarTargets.value.filter(t => t.isFlagged))
const stolenHits = computed(() => radarTargets.value.filter(t => t.isStolen))
const scanLog = computed(() => store.scanLog || [])
const showLog = ref(false)

// ── v2.2: 公民/车辆查询 ──
const searchType = ref<'citizen' | 'vehicle'>('citizen')
const searchQuery = ref('')
const searchResult = ref<any>(null)

async function doSearch() {
  if (!searchQuery.value.trim()) return
  const result = await sendNui('policeLookup', { type: searchType.value, query: searchQuery.value.trim() })
  searchResult.value = result
}

// 挂载时触发一次初始扫描
onMounted(() => {
  sendNui('policeRadar', {})
})

// ── 动作分发 ──
function doAction(action: string) {
  if (!canAct()) return
  sendNui('dashboardAction', { action })
}
function siren(mode: string) {
  if (!canAct()) return
  sendNui('dashboardAction', { action: 'siren', params: { mode } })
}
function flagPlate(plate: string) {
  if (!canAct()) return
  sendNui('policeAction', { action: 'flagPlate', plate })
}
function impoundNear() {
  if (!canAct()) return
  sendNui('policeAction', { action: 'impoundNear' })
}
function deployTracker() {
  if (!canAct()) return
  sendNui('policeAction', { action: 'deployTracker' })
}
function toggleSpeedRadar() {
  if (!canAct()) return
  sendNui('policeAction', { action: 'toggleSpeedRadar' })
}

// ── 速度颜色 ──
function speedClass(speed: number): string {
  if (speed > 80) return 'speed-high'
  if (speed > 50) return 'speed-mid'
  return 'speed-low'
}
</script>

<template>
  <div class="police-console">
    <!-- ═══ 上段: 雷达扫描 ═══ -->
    <div class="section">
      <div class="section-title">
        <span>📡 车载雷达</span>
        <span class="scan-badge active">● 扫描中</span>
      </div>

      <div class="radar-table-wrap" v-if="radarTargets.length > 0">
        <table class="radar-table">
          <thead>
            <tr>
              <th>车牌</th>
              <th>车型</th>
              <th>速度</th>
              <th>距离</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(t, i) in radarTargets.slice(0, 8)" :key="i"
              :class="{ flagged: t.isFlagged, stolen: t.isStolen }">
              <td class="plate-cell">
                <span v-if="t.isFlagged" title="标记车辆">🚨</span>
                <span v-else-if="t.isStolen" title="被盗车辆">⚠️</span>
                {{ t.plate }}
              </td>
              <td class="model-cell">{{ t.model }}</td>
              <td :class="speedClass(t.speedGun ?? t.speed)">
                {{ t.speedGun != null ? '🎯 ' + t.speedGun : t.speed }} mph
              </td>
              <td>{{ t.distance }}m</td>
              <td><button class="tiny-btn" @click="flagPlate(t.plate)" title="标记此车牌">🏷️</button></td>
            </tr>
          </tbody>
        </table>
      </div>
      <div v-else class="radar-empty">
        扫描中...附近无车辆
      </div>
    </div>

    <!-- ═══ 中段: ANPR / 被盗车命中 ═══ -->
    <div class="section" v-if="anprHits.length > 0 || stolenHits.length > 0">
      <div class="section-title">🚨 警情提示</div>
      <div v-for="(t, i) in anprHits" :key="'anpr'+i" class="alert-row anpr">
        🚨 标记车辆 — {{ t.plate }} ({{ t.model }}) · {{ t.distance }}m
      </div>
      <div v-for="(t, i) in stolenHits" :key="'stolen'+i" class="alert-row stolen">
        ⚠️ 被盗车辆 — {{ t.plate }} ({{ t.model }}) · {{ t.distance }}m
      </div>
    </div>

    <!-- ═══ 下段: 警用工具 ═══ -->
    <div class="section">
      <div class="section-title">🔧 警用工具</div>

      <!-- 警笛 -->
      <div class="tool-group">
        <div class="tool-label">🔊 警笛控制</div>
        <div class="siren-grid">
          <button class="siren-btn" @click="siren('wail')">Wail</button>
          <button class="siren-btn" @click="siren('yelp')">Yelp</button>
          <button class="siren-btn" @click="siren('priority')">Priority</button>
          <button class="siren-btn silent" @click="siren('silent')">🔇 无声</button>
        </div>
      </div>

      <!-- 主工具 -->
      <div class="tool-group">
        <div class="tool-label">🛠️ 执法工具</div>
        <div class="tool-grid">
          <button class="tool-btn" @click="doAction('megaphone')">📢 扩音喊话</button>
          <button class="tool-btn" @click="doAction('wanted_db')">📋 通缉数据库</button>
          <button class="tool-btn" @click="doAction('camera')">📹 监控摄像头</button>
          <button class="tool-btn" @click="toggleSpeedRadar()">📏 测速雷达</button>
          <button class="tool-btn" @click="deployTracker()">📡 部署追踪器</button>
          <button class="tool-btn" @click="impoundNear()">🚓 扣押附近车辆</button>
        </div>
      </div>
    </div>

    <!-- ═══ v2.2: 扫描日志 ═══ -->
    <div class="section">
      <div class="section-title" style="cursor:pointer" @click="showLog = !showLog">
        <span>📜 扫描记录 ({{ scanLog.length }})</span>
        <span style="font-size:10px">{{ showLog ? '▲' : '▼' }}</span>
      </div>
      <div v-if="showLog && scanLog.length > 0" class="log-list">
        <div v-for="(e, i) in scanLog.slice().reverse()" :key="i"
          class="log-row" :class="{ flagged: e.isFlagged, stolen: e.isStolen }">
          <span class="log-time">{{ e.time }}</span>
          <span class="log-plate">{{ e.plate }}</span>
          <span class="log-model">{{ e.model }}</span>
          <span class="log-speed">{{ e.speed }}mph</span>
          <span v-if="e.isFlagged" title="标记">🚨</span>
          <span v-else-if="e.isStolen" title="被盗">⚠️</span>
        </div>
      </div>
      <div v-else-if="showLog" class="radar-empty">暂无扫描记录</div>
    </div>

    <!-- ═══ v2.2: 公民/车辆查询 ═══ -->
    <div class="section">
      <div class="section-title">🔍 数据库查询</div>
      <div class="search-row">
        <select v-model="searchType" class="search-select">
          <option value="citizen">👤 公民</option>
          <option value="vehicle">🚗 车牌</option>
        </select>
        <input v-model="searchQuery" class="search-input"
          :placeholder="searchType === 'citizen' ? '公民ID 或 姓名' : '车牌号'"
          @keyup.enter="doSearch" />
        <button class="search-btn" @click="doSearch">搜索</button>
      </div>
      <!-- 搜索结果 -->
      <div v-if="searchResult" class="search-result">
        <div v-if="!searchResult.found" class="search-empty">{{ searchResult.message }}</div>
        <div v-else-if="searchType === 'citizen'" class="result-card">
          <div class="result-row"><b>{{ searchResult.name }}</b></div>
          <div class="result-row">🆔 {{ searchResult.citizenid }}</div>
          <div class="result-row">💼 {{ searchResult.job }}</div>
          <div class="result-row">💰 ${{ searchResult.cash }} / 🏦 ${{ searchResult.bank }}</div>
          <div class="result-row">📞 {{ searchResult.phone }} · 🎂 {{ searchResult.dob }}</div>
        </div>
        <div v-else class="result-card">
          <div class="result-row"><b>{{ searchResult.plate }}</b> — {{ searchResult.model }}</div>
          <div class="result-row">👤 车主: {{ searchResult.owner }} ({{ searchResult.citizenid }})</div>
          <div class="result-row">🏠 车库: {{ searchResult.garage }} · 📌 {{ searchResult.state }}</div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.police-console {
  display: flex; flex-direction: column; gap: 12px;
}

.section {
  background: rgba(255,255,255,0.03);
  border-radius: 10px;
  padding: 10px 12px;
  border: 1px solid var(--tcity-border);
}
.section-title {
  font-size: 12px; font-weight: 700; color: var(--tcity-accent);
  margin-bottom: 8px; display: flex; justify-content: space-between; align-items: center;
}
.scan-badge { font-size: 10px; color: var(--tcity-text-dim); }
.scan-badge.active { color: var(--tcity-success); }

/* 雷达表格 */
.radar-table-wrap { max-height: 180px; overflow-y: auto; }
.radar-table { width: 100%; border-collapse: collapse; font-size: 11px; }
.radar-table th {
  text-align: left; padding: 4px 6px; color: var(--tcity-text-dim);
  border-bottom: 1px solid rgba(255,255,255,0.06); font-weight: 600;
}
.radar-table td { padding: 4px 6px; border-bottom: 1px solid rgba(255,255,255,0.03); }
.plate-cell { font-weight: 600; color: var(--tcity-text-primary); }
.model-cell { color: var(--tcity-text-dim); max-width: 80px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
tr.flagged { background: rgba(255,34,68,0.10); }
tr.stolen { background: rgba(255,170,0,0.10); }
.speed-high { color: var(--tcity-danger); font-weight: 700; }
.speed-mid { color: var(--tcity-warning); }
.speed-low { color: var(--tcity-success); }
.radar-empty { font-size: 11px; color: var(--tcity-text-dim); text-align: center; padding: 16px 0; }

/* 警情提示 */
.alert-row {
  font-size: 11px; padding: 6px 8px; border-radius: 6px; margin-bottom: 4px;
  font-weight: 600;
}
.alert-row.anpr { background: rgba(255,34,68,0.15); color: #ff5566; }
.alert-row.stolen { background: rgba(255,170,0,0.15); color: #ffbb33; }

/* 警笛 */
.siren-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.siren-btn {
  padding: 8px; border-radius: 6px;
  border: 1px solid var(--tcity-border);
  background: rgba(255,255,255,0.04);
  color: var(--tcity-text-primary); font-size: 11px; cursor: pointer; transition: 0.2s;
}
.siren-btn:hover { background: var(--tcity-accent); border-color: var(--tcity-accent); color: white; }
.siren-btn.silent { color: var(--tcity-text-dim); }

/* 工具 */
.tool-group { margin-top: 8px; }
.tool-label { font-size: 11px; color: var(--tcity-text-dim); margin-bottom: 6px; }
.tool-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; }
.tool-btn {
  padding: 10px 8px; border-radius: 8px; border: 1px solid var(--tcity-border);
  background: rgba(255,255,255,0.04); color: var(--tcity-text-dim);
  font-size: 12px; cursor: pointer; transition: 0.2s; text-align: center;
}
.tool-btn:hover { background: var(--tcity-accent); color: white; border-color: var(--tcity-accent); }

.tiny-btn {
  width: 22px; height: 22px; border-radius: 4px; border: none;
  background: rgba(255,255,255,0.08); color: var(--tcity-text-dim);
  font-size: 10px; cursor: pointer; padding: 0; line-height: 22px; text-align: center;
}
.tiny-btn:hover { background: var(--tcity-accent); color: white; }

/* v2.2: 扫描日志 */
.log-list { max-height: 160px; overflow-y: auto; }
.log-row {
  display: flex; align-items: center; gap: 6px; padding: 5px 4px;
  font-size: 10px; border-bottom: 1px solid rgba(255,255,255,0.03);
}
.log-row.flagged { background: rgba(255,34,68,0.08); }
.log-row.stolen { background: rgba(255,170,0,0.08); }
.log-time { color: var(--tcity-text-dim); min-width: 48px; }
.log-plate { font-weight: 700; color: var(--tcity-text-primary); min-width: 60px; }
.log-model { color: var(--tcity-text-dim); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.log-speed { color: var(--tcity-accent); min-width: 36px; text-align: right; }

/* v2.2: 搜索面板 */
.search-row { display: flex; gap: 6px; margin-top: 6px; }
.search-select {
  padding: 6px; border-radius: 6px; border: 1px solid var(--tcity-border);
  background: rgba(255,255,255,0.06); color: var(--tcity-text-primary); font-size: 11px;
}
.search-input {
  flex: 1; padding: 6px 8px; border-radius: 6px; border: 1px solid var(--tcity-border);
  background: rgba(255,255,255,0.06); color: var(--tcity-text-primary); font-size: 11px;
}
.search-input::placeholder { color: var(--tcity-text-dim); }
.search-btn {
  padding: 6px 12px; border-radius: 6px; border: 1px solid var(--tcity-accent);
  background: rgba(34,102,255,0.15); color: var(--tcity-accent); font-size: 11px; cursor: pointer;
}
.search-btn:hover { background: var(--tcity-accent); color: white; }
.search-result { margin-top: 8px; }
.search-empty { font-size: 11px; color: var(--tcity-text-dim); text-align: center; padding: 8px; }
.result-card { font-size: 11px; }
.result-row { padding: 3px 0; color: var(--tcity-text-dim); border-bottom: 1px solid rgba(255,255,255,0.03); }
.result-row:first-child { color: var(--tcity-text-primary); }
</style>
