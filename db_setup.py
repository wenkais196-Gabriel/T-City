import pymysql

db_config = {
    'host': 'localhost',
    'user': 'root',
    'password': '1543368168',
    'database': 'QBCore_CDB34E',
    'charset': 'utf8mb4'
}

queries = [
    # 1. Alter players table to add columns
    """
    ALTER TABLE players
      ADD COLUMN rank_tier    VARCHAR(20) NOT NULL DEFAULT 'entry',
      ADD COLUMN department   VARCHAR(50) DEFAULT NULL,
      ADD COLUMN district     VARCHAR(50) DEFAULT NULL,
      ADD COLUMN certs        JSON        NOT NULL DEFAULT '[]';
    """,
    # 2. Add indexes to players table
    "ALTER TABLE players ADD INDEX idx_rank_tier (rank_tier);",
    "ALTER TABLE players ADD INDEX idx_department (department);",
    # 3. Create career_certifications table
    """
    CREATE TABLE IF NOT EXISTS career_certifications (
      cert_id       VARCHAR(50) PRIMARY KEY,
      name          VARCHAR(100) NOT NULL,
      required_role VARCHAR(50) NOT NULL DEFAULT 'civilian',
      required_tier VARCHAR(20) NOT NULL DEFAULT 'entry'
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """,
    # 4. Create leader_roles table
    """
    CREATE TABLE IF NOT EXISTS leader_roles (
      role         VARCHAR(50) PRIMARY KEY,
      citizenid    VARCHAR(11) NOT NULL UNIQUE,
      name         VARCHAR(100) NOT NULL,
      assigned_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      kpi_points   INT NOT NULL DEFAULT 0,
      INDEX idx_leader_citizenid (citizenid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """,
    # 5. Create leader_kpi_tasks table
    """
    CREATE TABLE IF NOT EXISTS leader_kpi_tasks (
      id           INT AUTO_INCREMENT PRIMARY KEY,
      leader_role  VARCHAR(50) NOT NULL,
      task_type    VARCHAR(50) NOT NULL,
      target_tags  JSON NOT NULL,
      assigned_to  VARCHAR(11) DEFAULT NULL,
      status       VARCHAR(20) NOT NULL DEFAULT 'pending',
      created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      completed_at DATETIME DEFAULT NULL,
      INDEX idx_kpi_role_status (leader_role, status)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """,
    # 6. Create catalyst_cards table
    """
    CREATE TABLE IF NOT EXISTS catalyst_cards (
      id           INT AUTO_INCREMENT PRIMARY KEY,
      card_type    VARCHAR(50) NOT NULL,
      activated_by VARCHAR(11) NOT NULL,
      activated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      expires_at   DATETIME NOT NULL,
      is_hidden    TINYINT(1) NOT NULL DEFAULT 0,
      INDEX idx_cards_expiration (expires_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """,
    # 7. Insert initial certification data
    """
    INSERT INTO career_certifications (cert_id, name, required_role, required_tier) VALUES
      ('pilot_license',   '飞行执照',   'civilian', 'entry'),
      ('marine_license',  '船舶驾照',   'civilian', 'entry'),
      ('heavy_vehicle',   '重型车驾照', 'civilian', 'entry'),
      ('firearms_cert',   '执法枪械证', 'police',   'entry'),
      ('surgical_cert',   '外科资质',   'medic',    'mid')
    ON DUPLICATE KEY UPDATE name=VALUES(name);
    """
]

conn = pymysql.connect(**db_config)
try:
    with conn.cursor() as cursor:
        for q in queries:
            try:
                print(f"Executing query:\n{q.strip()}\n")
                cursor.execute(q)
                conn.commit()
                print("SUCCESS")
            except Exception as e:
                print(f"FAILED: {e}")
                conn.rollback()
finally:
    conn.close()
