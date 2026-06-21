// dashboard.js — 车载中控屏 (v0.9) — 按需构建/销毁 DOM, 关屏释放内存
// 四原则: 模块化·高性能·安全·可拓展

// ── 仪表盘 HTML 模板 (关屏时销毁, 开屏时重建) ──
const DASH_TPL = `
<div id="dashboard">
  <div class="dash-header">
    <span class="vehicle-icon" id="vehIcon">🚗</span>
    <div class="header-info">
      <div class="vehicle-plate" id="vehPlate">---</div>
      <div class="vehicle-model" id="vehModel">N/A</div>
    </div>
    <div class="header-actions">
      <button class="night-btn" id="nightBtn" onclick="toggleNightMode()" title="夜间模式">🌙</button>
      <button class="close-btn" onclick="closeDashboard()">✕</button>
    </div>
  </div>
  <div class="tab-bar">
    <button class="tab-btn active" data-tab="diag">📊 诊断</button>
    <button class="tab-btn" data-tab="ctrl">🛠️ 控制</button>
    <button class="tab-btn" data-tab="drive">🚀 驾驶</button>
    <button class="tab-btn" data-tab="logi">📦 货运</button>
    <button class="tab-btn" data-tab="prof" id="profTabBtn" style="display:none">🚨 职业</button>
  </div>
  <div class="tab-content active" id="tab-diag">
    <div class="gauge-row">
      <div class="gauge-card"><div class="gauge-value" id="gSpeed">0</div><div class="gauge-label">mph</div></div>
      <div class="gauge-card"><div class="gauge-value" id="gRPM">0</div><div class="gauge-label">RPM x100</div></div>
      <div class="gauge-card"><div class="gauge-value" id="gFuel">0%</div><div class="gauge-label">燃油</div></div>
    </div>
    <div class="status-row"><span class="label">发动机健康</span><span class="value" id="engHealth">100%</span></div>
    <div class="progress-bar"><div class="progress-fill" id="engBar" style="transform:scaleX(1)"></div></div>
    <div class="status-row"><span class="label">车身损伤</span><span class="value" id="bodyHealth">100%</span></div>
    <div class="progress-bar"><div class="progress-fill" id="bodyBar" style="transform:scaleX(1)"></div></div>
    <div class="status-row"><span class="label">机油寿命</span><span class="value" id="oilLife">100%</span></div>
    <div class="progress-bar"><div class="progress-fill" id="oilBar" style="transform:scaleX(1)"></div></div>
    <div class="status-row"><span class="label">冷却水温</span><span class="value" id="coolant">85°C</span></div>
    <div class="status-row"><span class="label">电池电压</span><span class="value" id="battery">12.6V</span></div>
    <div class="turbo-row" id="turboRow">
      <div class="status-row"><span class="label">🛡️ 涡轮增压</span><span class="value" id="turboPsi">0.0 psi</span></div>
      <div class="progress-bar"><div class="progress-fill" id="turboBar" style="transform:scaleX(0)"></div></div>
    </div>
    <div class="status-row"><span class="label">🧊 变速箱温</span><span class="value" id="transTemp">72°C</span></div>
    <div style="margin-top:8px;padding-top:6px;border-top:1px solid var(--glass-border)">
      <span style="font-size:11px;color:var(--text-dim)">🛞 轮胎</span>
      <span id="tireStatus" style="font-size:11px;margin-left:8px"></span>
    </div>
    <div style="margin-top:4px">
      <span style="font-size:11px;color:var(--text-dim)">🚪 车门</span>
      <span id="doorStatus" style="font-size:11px;margin-left:8px"></span>
    </div>
    <div style="margin-top:2px">
      <span style="font-size:11px;color:var(--text-dim)">💺 座位</span>
      <span id="seatStatus" style="font-size:11px;margin-left:8px"></span>
    </div>
  </div>
  <div class="tab-content" id="tab-ctrl">
    <div class="ctrl-grid">
      <button class="ctrl-btn" onclick="sendCtrl('engine')"><span class="btn-icon">⚡</span>引擎开关</button>
      <button class="ctrl-btn" onclick="sendCtrl('lock')"><span class="btn-icon">🔒</span>全车锁</button>
      <button class="ctrl-btn" onclick="sendCtrl('windows_up')"><span class="btn-icon">🪟▲</span>车窗升</button>
      <button class="ctrl-btn" onclick="sendCtrl('windows_down')"><span class="btn-icon">🪟▼</span>车窗降</button>
      <button class="ctrl-btn" id="btn_cargo" onclick="sendCtrl('cargo_door')" style="display:none"><span class="btn-icon">📦</span>货舱门</button>
      <button class="ctrl-btn danger" onclick="sendCtrl('alarm')"><span class="btn-icon">🔊</span>紧急警报</button>
      <button class="ctrl-btn" id="hazardBtn" onclick="toggleHazard()"><span class="btn-icon">🚨</span>双闪 开启</button>
      <button class="ctrl-btn" onclick="sendCtrl('hood')"><span class="btn-icon">🔧</span>引擎盖</button>
      <button class="ctrl-btn" onclick="sendCtrl('trunk')"><span class="btn-icon">📦</span>后备箱</button>
      <button class="ctrl-btn" onclick="sendCtrl('door_d')"><span class="btn-icon">🚗</span>驾驶门</button>
      <button class="ctrl-btn" onclick="sendCtrl('door_p')"><span class="btn-icon">🚗</span>副驾门</button>
      <button class="ctrl-btn" onclick="sendCtrl('door_rl')" id="btn_door_rl"><span class="btn-icon">🚗</span>左后门</button>
      <button class="ctrl-btn" onclick="sendCtrl('door_rr')" id="btn_door_rr"><span class="btn-icon">🚗</span>右后门</button>
      <button class="ctrl-btn" onclick="sendCtrl('roof')" id="btn_roof" style="display:none"><span class="btn-icon">🏎️</span>敞篷开关</button>
    </div>
  </div>
  <div class="tab-content" id="tab-drive">
    <div class="drive-section">
      <div class="drive-section-title">驾驶模式</div>
      <div class="mode-grid">
        <button class="mode-btn" data-mode="comfort" onclick="switchDriveMode('comfort')">🏖️ 舒适</button>
        <button class="mode-btn" data-mode="sport" onclick="switchDriveMode('sport')">🚗 运动</button>
        <button class="mode-btn" data-mode="eco" onclick="switchDriveMode('eco')">🌿 经济</button>
      </div>
    </div>
    <div class="drive-section">
      <div class="drive-section-title">特殊模式（按车型）</div>
      <div class="mode-grid mode-grid-2" id="specialModes">
        <button class="mode-btn" data-mode="freight" onclick="switchDriveMode('freight')">📦 货运</button>
        <button class="mode-btn" data-mode="offroad" onclick="switchDriveMode('offroad')">🏔️ 越野</button>
      </div>
    </div>
    <div class="cruise-card" id="cruiseCard">
      <div class="cruise-speed" id="cruiseSpeed">--</div>
      <div class="cruise-label">mph · 巡航控制</div>
      <div style="display:flex;gap:6px;align-items:center">
        <input type="number" id="cruiseInput" placeholder="设定目标 mph" min="18" max="180"
          style="flex:1;padding:8px;border-radius:8px;border:1px solid var(--glass-border);
            background:rgba(255,255,255,0.05);color:var(--text-primary);font-size:13px;text-align:center">
        <button class="ctrl-btn" onclick="setCruiseTarget()" style="margin:0;padding:8px 12px;white-space:nowrap">💾</button>
      </div>
      <div style="font-size:10px;color:var(--text-dim);margin-top:6px">Y键=当前速度巡航 · U键=预设速度巡航(需先💾) · 刹车退出</div>
    </div>
  </div>
  <div class="tab-content" id="tab-logi">
    <div id="logiEmpty" class="logistics-empty">
      <div class="icon">📦</div><div>暂无活跃货运任务</div>
      <div style="margin-top:8px;font-size:11px">接取物流运单后此处将显示电子戳</div>
    </div>
    <div id="logiActive" class="logistics-active" style="display:none">
      <div class="stamp-card">
        <div style="font-size:14px;font-weight:700;margin-bottom:8px;color:var(--accent)">📋 电子戳信息</div>
        <div class="stamp-row"><span class="label">任务</span><span class="value" id="stampQuest">---</span></div>
        <div class="stamp-row"><span class="label">车牌</span><span class="value" id="stampPlate">---</span></div>
        <div class="stamp-row"><span class="label">货物</span><span class="value" id="stampCargo">---</span></div>
        <div class="stamp-row"><span class="label">状态</span><span class="value" id="stampStatus">---</span></div>
      </div>
      <button class="deliver-btn" id="deliverBtn" disabled onclick="sendLogisticsDeliver()">🔖 电子印章交单</button>
      <button class="ctrl-btn" style="margin-top:8px" onclick="sendLogisticsLoad()"><span class="btn-icon">📥</span>快捷装货</button>
    </div>
  </div>
  <div class="tab-content" id="tab-prof">
    <div id="profPolice" style="display:none">
      <div class="prof-header">🚔 警车控制台</div>
      <div style="margin-bottom:12px"><div style="font-size:12px;color:var(--text-dim);margin-bottom:6px">📡 测速雷达</div>
        <div id="radarTargets"><div style="color:var(--text-dim);font-size:12px">雷达扫描中...</div></div></div>
      <div style="margin-bottom:12px"><div style="font-size:12px;color:var(--text-dim);margin-bottom:6px">🔊 警笛控制</div>
        <div class="siren-grid">
          <button class="siren-btn" onclick="sendSiren('wail')">Wail 巡航</button>
          <button class="siren-btn" onclick="sendSiren('yelp')">Yelp 追捕</button>
          <button class="siren-btn" onclick="sendSiren('priority')">Priority 抢道</button>
          <button class="siren-btn" onclick="sendSiren('silent')">🔇 无声闪烁</button>
        </div></div>
      <button class="megaphone-toggle off" id="megaphoneBtn" onclick="toggleMegaphone()">📢 PA 扩音喊话（关闭）</button>
      <button class="ctrl-btn" style="margin-top:8px" onclick="sendCtrl('wanted_db')"><span class="btn-icon">📋</span>通缉数据库查阅</button>
    </div>
    <div id="profAviation" style="display:none">
      <div class="prof-header">✈️ 航空导航</div>
      <div class="gauge-row"><div class="gauge-card"><div class="gauge-value" id="altimeter">0</div><div class="gauge-label">高度 (m)</div></div>
        <div class="gauge-card"><div class="gauge-value" id="airspeed">0</div><div class="gauge-label">空速 (km/h)</div></div></div>
      <div class="status-row"><span class="label">应答机代号</span><span class="value" id="transponder">1200</span></div>
      <button class="ctrl-btn" onclick="sendCtrl('transponder_cycle')" style="margin-top:8px"><span class="btn-icon">📡</span>应答机循环</button>
      <div class="status-row" style="margin-top:8px"><span class="label">气压高度</span><span class="value" id="baroAlt">0 hPa</span></div>
      <div class="status-row"><span class="label">偏航指示</span><span class="value" id="yaw">0°</span></div>
    </div>
    <div id="profMarine" style="display:none">
      <div class="prof-header">🚤 航海控制台</div>
      <button class="anchor-btn raised" id="anchorBtn" onclick="toggleAnchor()">⚓ 抛锚</button>
      <div class="gauge-row"><div class="gauge-card"><div class="gauge-value" id="depthMeter">0</div><div class="gauge-label">水深 (m)</div></div>
        <div class="gauge-card"><div class="gauge-value" id="sonarFish">0</div><div class="gauge-label">鱼群</div></div></div>
      <div class="status-row"><span class="label">锚定状态</span><span class="value" id="anchorStatus">起锚</span></div>
    </div>
    <div id="profAmbulance" style="display:none">
      <div class="prof-header">🚑 救护车控制台</div>
      <div style="margin-bottom:12px"><div style="font-size:12px;color:var(--text-dim);margin-bottom:6px">🔊 警笛控制</div>
        <div class="siren-grid">
          <button class="siren-btn" onclick="sendSiren('wail')">Wail 巡航</button>
          <button class="siren-btn" onclick="sendSiren('yelp')">Yelp 紧急</button>
          <button class="siren-btn" onclick="sendSiren('priority')">Priority 优先</button>
          <button class="siren-btn" onclick="sendSiren('silent')">🔇 无声闪烁</button>
        </div></div>
      <button class="megaphone-toggle off" id="ambulanceMegaphoneBtn" onclick="toggleMegaphone()">📢 PA 扩音喊话（关闭）</button>
      <div class="status-row" style="margin-top:8px"><span class="label">🚨 应急灯</span><span class="value">就绪</span></div>
    </div>
    <div id="profFire" style="display:none">
      <div class="prof-header">🚒 消防车控制台</div>
      <div style="margin-bottom:12px"><div style="font-size:12px;color:var(--text-dim);margin-bottom:6px">🔊 警笛控制</div>
        <div class="siren-grid">
          <button class="siren-btn" onclick="sendSiren('wail')">Wail 火警</button>
          <button class="siren-btn" onclick="sendSiren('yelp')">Yelp 出警</button>
          <button class="siren-btn" onclick="sendSiren('priority')">Priority 优先</button>
          <button class="siren-btn" onclick="sendSiren('silent')">🔇 无声闪烁</button>
        </div></div>
      <button class="ctrl-btn" onclick="sendCtrl('water_cannon')"><span class="btn-icon">💧</span>水炮开关</button>
      <div class="status-row" style="margin-top:8px"><span class="label">🧯 水罐容量</span><span class="value">100%</span></div>
    </div>
    <div id="app-tabs"></div>
  </div>
</div>`;

// ── State ──
let dashVisible = false, currentTheme = '', activeSiren = null, megaphoneOn = false;
let anchorDropped = false, nightMode = false, currentDriveMode = 'comfort';
let cruiseActive = false, hazardActive = false;
let _cache = {}, _modeLock = false;

function _chg(key, val){
  if(_cache[key] === val) return false;
  _cache[key] = val; return true;
}

// ── 按需构建 DOM (开屏时注入, 关屏时销毁) ──
function _buildDOM(){
  if(document.getElementById('dashboard')) return;
  document.body.insertAdjacentHTML('beforeend', DASH_TPL);
  // Tab 切换 (重建后需重新绑定)
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
      document.querySelectorAll('.tab-content').forEach(c=>c.classList.remove('active'));
      btn.classList.add('active');
      document.getElementById('tab-'+btn.dataset.tab).classList.add('active');
    });
  });
  // 还原持久化状态
  if(nightMode) document.body.classList.add('theme-night');
  if(perfMode) document.body.classList.add('no-blur');
}
function _destroyDOM(){
  const dash = document.getElementById('dashboard');
  if(dash) dash.parentNode.removeChild(dash);
  _cache = {};
}

// ── 按需构建/销毁 DOM (关屏释放数百个 DOM 节点) ──
function _buildDOM(){
  if(document.getElementById('dashboard')) return;
  document.body.insertAdjacentHTML('beforeend', DASH_TPL);
  // 主题初始状态
  if(nightMode) document.body.classList.add('theme-night');
  // 夜间按钮
  var nb = document.getElementById('nightBtn');
  if(nb && nightMode) nb.textContent = '☀️';
  // Tab 切换 (DOM 新建后重新绑定)
  document.querySelectorAll('.tab-btn').forEach(function(btn){
    btn.addEventListener('click', function(){
      document.querySelectorAll('.tab-btn').forEach(function(b){b.classList.remove('active');});
      document.querySelectorAll('.tab-content').forEach(function(c){c.classList.remove('active');});
      btn.classList.add('active');
      var tab = document.getElementById('tab-'+btn.dataset.tab);
      if(tab) tab.classList.add('active');
    });
  });
}
function _destroyDOM(){
  var dash = document.getElementById('dashboard');
  if(dash) dash.parentNode.removeChild(dash);
  _cache = {};
  // 清除 body 上的临时 class (保留 localStorage 偏好)
  document.body.classList.remove('theme-night');
}

// ── NUI Events ──
window.addEventListener('message', e => {
  var d = e.data;
  switch(d.type){
    case 'open':
      _buildDOM();
      dashVisible = true;
      document.getElementById('dashboard').classList.add('active');
      document.body.className = (nightMode ? 'theme-night ' : '') + (d.theme || '');
      currentTheme = d.theme || '';
      updateVehicleInfo(d.plate, d.model, d.class);
      updateDiagnostics(d);
      updateProfession(d.job, d.jobData); updateLogistics(d.logistics);
      updateApps(d.apps); updateDriveMode(d.driveMode, d.turboInstalled);
      updateCruise(d.cruiseActive, d.cruiseSpeed); updateHazard(d.hazardActive);
      break;
    case 'close':
      dashVisible = false;
      var dashEl = document.getElementById('dashboard');
      if(dashEl) dashEl.classList.remove('active');
      // 300ms 等淡出动画, 然后销毁 DOM 释放内存
      setTimeout(_destroyDOM, 300);
      break;
    case 'tick':
      if(_chg('spd',d.speed)) document.getElementById('gSpeed').textContent = Math.round(d.speed||0);
      if(_chg('rpm',d.rpm)) document.getElementById('gRPM').textContent = Math.round((d.rpm||0)/100);
      break;
    case 'diag':
      updateDiagnostics(d); updateVehicleStatus(d);
      updateDriveMode(d.driveMode, d.turboInstalled);
      updateCruise(d.cruiseActive, d.cruiseSpeed);
      updateHazard(d.hazardActive);
      break;
    case 'radar': updateRadar(d.targets); break;
    case 'logistics': updateLogistics(d); break;
    case 'anchor': anchorDropped = d.dropped; updateAnchorUI(); break;
    case 'cruise': updateCruise(d.active, d.speed); break;
    case 'driveMode': updateDriveMode(d.mode, d.turboInstalled); break;
    case 'hazard': hazardActive = d.active; updateHazardUI(); break;
    case 'registerApp': updateApps([d.app]); break;
  }
});

// ── Vehicle Info ──
function updateVehicleInfo(plate, model, cls){
  document.getElementById('vehPlate').textContent = plate || '---';
  document.getElementById('vehModel').textContent = (model||'N/A') + ' · Class ' + (cls||'?');
  var icons = {8:'🏍️',13:'🚲',14:'🚤',15:'✈️',16:'🚁',18:'🚔',19:'🚛',20:'🚌'};
  document.getElementById('vehIcon').textContent = icons[cls] || '🚗';
  var vclass = parseInt(cls) || 0;
  window._vehicleClass = vclass;
  var freightBtn = document.querySelector('.mode-btn[data-mode="freight"]');
  var offroadBtn = document.querySelector('.mode-btn[data-mode="offroad"]');
  if(freightBtn) freightBtn.style.display = [18,19,20].includes(vclass) ? '' : 'none';
  if(offroadBtn) offroadBtn.style.display = [2,3,9].includes(vclass) ? '' : 'none';
  // 货舱门: 仅厢式货车(12)和商用(20)显示
  var cargoBtn = document.getElementById('btn_cargo');
  if(cargoBtn) cargoBtn.style.display = [12,20].includes(vclass) ? '' : 'none';
}

// ── Diagnostics ──
function updateDiagnostics(d){
  if(!d) return;
  if(_chg('fuel',d.fuel)) document.getElementById('gFuel').textContent = Math.round(d.fuel||0)+'%';
  if(_chg('eng',d.engine)) setBar('engBar','engHealth',d.engine||1000,1000);
  if(_chg('body',d.body)) setBar('bodyBar','bodyHealth',d.body||1000,1000);
  if(_chg('oil',d.oil)){ document.getElementById('oilLife').textContent = Math.round(d.oil||100)+'%'; setBar('oilBar','oilLife',d.oil||100,100); }
  if(_chg('coolant',d.coolant)) document.getElementById('coolant').textContent = (d.coolant||85).toFixed(1)+'°C';
  if(_chg('battery',d.battery)) document.getElementById('battery').textContent = (d.battery||12.6).toFixed(1)+'V';
  if(_chg('transTemp',d.transTemp)) document.getElementById('transTemp').textContent = (d.transTemp||72).toFixed(1)+'°C';
  var tr = document.getElementById('turboRow');
  if(d.turboInstalled){ tr.classList.add('show');
    if(_chg('turboPsi',d.turboPsi)) document.getElementById('turboPsi').textContent = (d.turboPsi||0).toFixed(1)+' psi';
    var tw = Math.min(100,Math.max(0,(d.turboPsi||0)/2*100));
    if(_chg('turboW',tw)) document.getElementById('turboBar').style.transform = 'scaleX('+(tw/100)+')';
  } else tr.classList.remove('show');
}
function setBar(barId,textId,val,max){
  var pct = Math.max(0,Math.min(100,val/max*100));
  if(!_chg(barId,pct)) return;
  document.getElementById(barId).style.transform = 'scaleX('+(pct/100)+')';
  document.getElementById(textId).textContent = Math.round(pct)+'%';
  var bar = document.getElementById(barId);
  bar.classList.toggle('warning',pct<50); bar.classList.toggle('danger',pct<25);
}

// ── 车辆状态 (轮胎/车门/座位, 内联显示在诊断页) ──
function updateVehicleStatus(d){
  if(!d) return;
  var G='#22DD88',Y='#FFAA00',R='#FF3344',D='#8899AA';
  var tires=d.tireStates||[], th='';
  if(tires.length > 0){
    var labels = tires.length===2 ? ['F','B'] : tires.length===6 ? ['FR','FL','BR','BL','ER','EL'] : ['FR','FL','BR','BL'];
    for(var i=0;i<tires.length;i++) th+='<span style="color:'+(tires[i]==='ok'?G:tires[i]==='burst'?R:D)+';margin:0 2px;font-size:11px">'+(labels[i]||'?')+'</span>';
    if(_chg('tireSt',th)) document.getElementById('tireStatus').innerHTML = th;
  }
  var doors=d.doorStates||[], dh='';
  if(doors.length > 0){
    for(var j=0;j<doors.length;j++) dh+='<span style="color:'+(doors[j]==='closed'?G:doors[j]==='open'?Y:D)+';margin:0 1px">🚪</span>';
    if(d.hoodOpen!==undefined) dh+=' <span style="color:'+(d.hoodOpen?Y:G)+'">🔧</span>';
    if(d.trunkOpen!==undefined) dh+=' <span style="color:'+(d.trunkOpen?Y:G)+'">📦</span>';
    if(_chg('doorSt',dh)) document.getElementById('doorStatus').innerHTML = dh;
  }
  var seats=d.seats||[], sh='';
  if(seats.length > 0){
    for(var k=0;k<seats.length;k++){ var s=seats[k]; sh+= s==='driver'?'🧑':s==='occupied'?'👤':'⬜'; }
    if(_chg('seatSt',sh)) document.getElementById('seatStatus').innerHTML = sh;
  }
  // 按车门数隐藏后门按钮 + 敞篷按钮显隐
  var nd=d.numDoors||4;
  var rl=document.getElementById('btn_door_rl'), rr=document.getElementById('btn_door_rr');
  if(rl) rl.style.display = nd>2 ? '' : 'none';
  if(rr) rr.style.display = nd>2 ? '' : 'none';
  var rf=document.getElementById('btn_roof');
  if(rf) rf.style.display = d.isConvertible ? '' : 'none';
  if(rf && d.isConvertible) rf.innerHTML = '<span class="btn-icon">🏎️</span>'+(d.roofDown?'关敞篷':'开敞篷');
}

// ── Controls (旧 updateBottomBar 已合并到 updateVehicleStatus)
// (旧 updateBottomBar 已删除, 功能迁移到 updateVehicleStatus)

// ── Controls ──
function sendCtrl(action){ fetch('https://custom-vehicles/dashboardCtrl',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:action})}); }
function toggleHazard(){ fetch('https://custom-vehicles/hazardToggle',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({})}); }
function updateHazard(a){ hazardActive=a; updateHazardUI(); }
function updateHazardUI(){ var b=document.getElementById('hazardBtn'); if(hazardActive){ b.classList.add('warn-active'); b.innerHTML='<span class="btn-icon">🚨</span>双闪 关闭'; } else { b.classList.remove('warn-active'); b.innerHTML='<span class="btn-icon">🚨</span>双闪 开启'; } }

// ── Drive Modes ──
function switchDriveMode(mode){ if(_modeLock) return; _modeLock=true; updateDriveMode(mode,null); fetch('https://custom-vehicles/driveMode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:mode})}); setTimeout(function(){_modeLock=false;},800); }
function updateDriveMode(mode, turboInstalled){ if(!mode) return; currentDriveMode=mode; document.querySelectorAll('.mode-btn').forEach(b=>b.classList.remove('active')); var ab=document.querySelector('.mode-btn[data-mode="'+mode+'"]'); if(ab) ab.classList.add('active'); var sb=document.querySelector('.mode-btn[data-mode="sport"]'); if(sb) sb.disabled=false; }

// ── Cruise ──
function setCruiseTarget(){ var mph=parseFloat(document.getElementById('cruiseInput').value)||0; if(mph<18){ alert('巡航最低 18 mph'); return; } fetch('https://custom-vehicles/setCruiseTarget',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({targetMph:mph})}); }
function updateCruise(active, speed){ cruiseActive=active; var c=document.getElementById('cruiseCard'), s=document.getElementById('cruiseSpeed'); if(active){ c.classList.add('on'); s.textContent=Math.round(speed*2.23694); } else { c.classList.remove('on'); s.textContent='--'; } }

// ── Night / Perf Modes ──
function toggleNightMode(){ nightMode=!nightMode; document.body.classList.toggle('theme-night',nightMode); document.getElementById('nightBtn').classList.toggle('on',nightMode); document.getElementById('nightBtn').textContent=nightMode?'☀️':'🌙'; localStorage.setItem('dashboard_night',nightMode?'1':'0'); }
// ── Logistics ──
function updateLogistics(d){ var em=document.getElementById('logiEmpty'), ac=document.getElementById('logiActive'); var tb=document.querySelector('.tab-btn[data-tab=\"logi\"]'); if(!d||!d.active){ em.style.display='block';ac.style.display='none'; if(tb) tb.style.display='none'; return; } em.style.display='none';ac.style.display='block'; if(tb) tb.style.display=''; document.getElementById('stampQuest').textContent=d.questTitle||'---'; document.getElementById('stampPlate').textContent=d.plate||'---'; document.getElementById('stampCargo').textContent=d.cargo||'---'; document.getElementById('stampStatus').textContent=d.canDeliver?'✅ 可交单':'📍 运输中'; var btn=document.getElementById('deliverBtn'); btn.disabled=!d.canDeliver; btn.textContent=d.canDeliver?'🔖 电子印章交单':'📍 到达卸货点后可交单'; }
function sendLogisticsDeliver(){ fetch('https://custom-vehicles/logisticsDeliver',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'deliver'})}); }
function sendLogisticsLoad(){ fetch('https://custom-vehicles/logisticsLoad',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'load'})}); }

// ── Profession ──
function updateProfession(job, jobData){ var vc=window._vehicleClass||0; var isEmergency=vc===18; document.getElementById('profPolice').style.display=(job==='police'||isEmergency)?'block':'none'; document.getElementById('profAmbulance').style.display=(job==='ambulance'||isEmergency)?'block':'none'; document.getElementById('profFire').style.display=(job==='fire'||isEmergency)?'block':'none'; document.getElementById('profAviation').style.display=(job==='pilot'||jobData?.isAircraft)?'block':'none'; document.getElementById('profMarine').style.display=(jobData?.isBoat)?'block':'none'; document.getElementById('profTabBtn').style.display=(job==='police'||job==='ambulance'||job==='fire'||jobData?.isAircraft||jobData?.isBoat||isEmergency)?'inline':'none'; }
function updateRadar(targets){ var el=document.getElementById('radarTargets'); if(!targets||!targets.length){ el.innerHTML='<div style="color:var(--text-dim);font-size:12px">雷达扫描中...</div>';return; } el.innerHTML=targets.map(t=>'<div class="radar-target"><span>'+t.model+' · <span class="radar-plate">'+t.plate+'</span></span><span class="radar-speed'+(t.speed>100?' fast':'')+'">'+Math.round(t.speed)+' mph</span></div>').join(''); }
function sendSiren(mode){ activeSiren=activeSiren===mode?null:mode; document.querySelectorAll('.siren-btn').forEach(b=>b.classList.remove('active')); if(activeSiren){ var sb=document.querySelector('.siren-btn[onclick*="'+mode+'"]'); if(sb) sb.classList.add('active'); } fetch('https://custom-vehicles/sirenControl',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:activeSiren||'off'})}); }
function toggleMegaphone(){ megaphoneOn=!megaphoneOn; var b=document.getElementById('megaphoneBtn'); b.textContent='📢 PA 扩音喊话（'+(megaphoneOn?'开启中':'关闭')+'）'; b.classList.toggle('on',megaphoneOn);b.classList.toggle('off',!megaphoneOn); fetch('https://custom-vehicles/megaphoneToggle',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled:megaphoneOn})}); }
function toggleAnchor(){ anchorDropped=!anchorDropped; updateAnchorUI(); fetch('https://custom-vehicles/anchorToggle',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({dropped:anchorDropped})}); }
function updateAnchorUI(){ var b=document.getElementById('anchorBtn'); b.textContent=anchorDropped?'⚓ 起锚':'⚓ 抛锚'; b.classList.toggle('dropped',anchorDropped);b.classList.toggle('raised',!anchorDropped); document.getElementById('anchorStatus').textContent=anchorDropped?'已抛锚':'起锚'; }
function updateApps(apps){ var el=document.getElementById('app-tabs'); if(!apps||!apps.length){el.innerHTML='';return;} el.innerHTML=apps.map(a=>'<button class="app-tab-btn" onclick="openApp(\''+a.id+'\',\''+(a.nui_event||'')+'\')">'+(a.icon||'📱')+' '+(a.label||a.id)+'</button>').join(''); }
function openApp(id, nuiEvent){ fetch('https://custom-vehicles/openApp',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({appId:id,nuiEvent:nuiEvent})}); }

// ── Close (ESC/I/右键 → fetch → Lua → toggleDashboard) ──
function closeDashboard(){
  dashVisible = false;
  var dash = document.getElementById('dashboard');
  if(dash) dash.classList.remove('active');
  setTimeout(_destroyDOM, 300);
  fetch('https://custom-vehicles/closeDashboard',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({})});
}

// ── Keys ──
document.addEventListener('keydown',function(e){
  if(e.key==='Escape'||e.key==='i'||e.key==='I'){ closeDashboard(); e.preventDefault(); e.stopPropagation(); return; }
  // 仅放行 ESC/I/右键退出, 左键操作, 其余全拦截
  if(e.key==='Escape'||e.key==='i'||e.key==='I') return;
  e.preventDefault(); e.stopPropagation();
});
document.addEventListener('contextmenu',function(e){ closeDashboard(); e.preventDefault(); });

// ── Init ──
(function(){
  if(localStorage.getItem('dashboard_night')==='1'){ nightMode=true; }
})();
