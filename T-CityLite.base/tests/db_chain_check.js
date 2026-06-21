const mysql = require('mysql2/promise');

(async () => {
  const conn = await mysql.createConnection({ 
    uri: 'mysql://root:1543368168@localhost/QBCore_CDB34E?charset=utf8mb4' 
  });

  // Test vehicle lookup query
  const [veh] = await conn.query(
    'SELECT pv.plate, pv.vehicle, pv.garage, pv.state, pv.citizenid FROM player_vehicles pv LIMIT 3'
  );
  console.log('[OK] Sample vehicles:', veh.length, 'found');
  if (veh.length > 0) {
    for (const v of veh) {
      console.log(`  plate=${v.plate} model=${v.vehicle} state=${v.state} citizenid=${v.citizenid}`);
    }
  }

  // Test citizen lookup target table
  const [playerCols] = await conn.query('DESCRIBE players');
  console.log('[OK] players columns:', playerCols.map(c => c.Field).join(', '));

  // Check charinfo JSON structure
  const [samplePlayer] = await conn.query('SELECT citizenid, charinfo FROM players LIMIT 1');
  if (samplePlayer.length > 0) {
    const raw = samplePlayer[0].charinfo;
    console.log('[OK] Sample charinfo type:', typeof raw, '| preview:', 
      typeof raw === 'string' ? raw.substring(0, 80) : JSON.stringify(raw).substring(0, 80));
    
    // Try JSON parse
    if (typeof raw === 'string') {
      try {
        const parsed = JSON.parse(raw);
        console.log('[OK] charinfo parsed:', Object.keys(parsed).join(', '));
      } catch(e) {
        console.log('[WARN] charinfo not valid JSON — police_api.lua json.decode will fail');
      }
    }
  }

  // Test the JOIN query from police_api.lua
  const [join] = await conn.query(
    'SELECT pv.plate, pv.vehicle, pv.garage, pv.state, pv.citizenid, COALESCE(p.charinfo, "") as owner_info ' +
    'FROM player_vehicles pv LEFT JOIN players p ON pv.citizenid = p.citizenid LIMIT 1'
  );
  console.log('[OK] JOIN query:', join.length > 0 ? 'works' : 'no results');
  if (join.length > 0) {
    console.log('  owner_info type:', typeof join[0].owner_info);
  }

  await conn.end();
  console.log('\nData chain verification complete');
})().catch(e => console.error('[FAIL]', e.message));
