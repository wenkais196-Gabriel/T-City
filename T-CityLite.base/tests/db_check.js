const mysql = require('mysql2/promise');

(async () => {
  const conn = await mysql.createConnection({ 
    uri: 'mysql://root:1543368168@localhost/QBCore_CDB34E?charset=utf8mb4' 
  });

  // 1. Create table
  await conn.execute(`
    CREATE TABLE IF NOT EXISTS plate_flags (
      plate       VARCHAR(16)  NOT NULL PRIMARY KEY,
      isflagged   TINYINT(1)   NOT NULL DEFAULT 1,
      reason      VARCHAR(255)  DEFAULT NULL,
      flagged_by  VARCHAR(64)   DEFAULT NULL,
      flagged_at  INT(11)       NOT NULL DEFAULT 0,
      INDEX idx_isflagged (isflagged)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  `);
  console.log('[OK] plate_flags table created');

  // 2. Verify columns
  const [cols] = await conn.query('DESCRIBE plate_flags');
  console.log('[OK] Columns:', cols.map(c => c.Field).join(', '));

  // 3. Test INSERT
  await conn.execute(
    'INSERT INTO plate_flags (plate, isflagged, reason, flagged_by, flagged_at) VALUES (?, 1, ?, ?, ?) ON DUPLICATE KEY UPDATE isflagged=1',
    ['TEST001', 'test flag', 'SYSTEM', Math.floor(Date.now() / 1000)]
  );
  console.log('[OK] Test flag TEST001 inserted');

  // 4. Test SELECT
  const [rows] = await conn.query('SELECT * FROM plate_flags WHERE isflagged = 1');
  console.log('[OK] Flagged plates:', rows.map(r => r.plate).join(', ') || '(none)');

  // 5. Test UPDATE (unflag)
  await conn.execute('UPDATE plate_flags SET isflagged = 0 WHERE plate = ?', ['TEST001']);
  const [after] = await conn.query('SELECT * FROM plate_flags WHERE plate = ?', ['TEST001']);
  console.log('[OK] TEST001 unflagged, isflagged =', after[0]?.isflagged ?? 'N/A');

  // 6. Cleanup
  await conn.execute('DELETE FROM plate_flags WHERE plate = ?', ['TEST001']);

  // 7. Check player_vehicles table (for vehicle lookup)
  const [vehCols] = await conn.query('DESCRIBE player_vehicles');
  console.log('[OK] player_vehicles columns:', vehCols.map(c => c.Field).join(', '));

  await conn.end();
  console.log('\nDatabase verification complete');
})().catch(e => console.error('[FAIL]', e.message));
