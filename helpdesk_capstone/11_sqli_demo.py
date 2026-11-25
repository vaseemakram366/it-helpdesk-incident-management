"""
SQL-injection demo (application level).   pip install pymysql
Shows the SAME attack against (1) string-concatenated SQL and (2) a parameterised query.
Take a screenshot of the console output for the report.
"""
import pymysql

conn = pymysql.connect(host="localhost", user="root", password="YOUR_ROOT_PASSWORD", database="helpdesk_db")
cur = conn.cursor()

ATTACKS = ["VPN",                                           # normal input
           "zzz' OR '1'='1",                                # tautology
           "zzz' UNION SELECT email, full_name FROM app_user -- "]   # data theft


def vulnerable_search(term):
    sql = "SELECT ticket_no, title FROM incident WHERE title = '" + term + "'"     # BAD: concatenation
    cur.execute(sql)
    return sql, cur.fetchall()


def safe_search(term):
    sql = "SELECT ticket_no, title FROM incident WHERE title = %s"                  # GOOD: placeholder
    cur.execute(sql, (term,))
    return sql, cur.fetchall()


for a in ATTACKS:
    print("=" * 78, "\nINPUT:", a)
    sql, rows = vulnerable_search(a)
    print("[VULNERABLE]", sql, "\n  -> rows returned:", len(rows), rows[:2])
    sql, rows = safe_search(a)
    print("[SAFE]      ", sql, "\n  -> rows returned:", len(rows))

conn.close()
