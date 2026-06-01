import pymysql

db_config = {
    'host': 'localhost',
    'user': 'root',
    'password': '1543368168',
    'database': 'QBCore_CDB34E',
    'charset': 'utf8mb4'
}

query = "ALTER TABLE bank_statements ADD INDEX idx_citizenid_account_date (citizenid, account_name, date);"

conn = pymysql.connect(**db_config)
try:
    with conn.cursor() as cursor:
        print("Executing: " + query)
        cursor.execute(query)
        conn.commit()
        print("Index added successfully!")
except Exception as e:
    print("Error:", e)
finally:
    conn.close()
