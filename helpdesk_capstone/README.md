# IT Helpdesk & Incident Management DB — How to run + Screenshot checklist

## Setup
1. Install **MySQL 8.0.31+** (INTERSECT/EXCEPT need 8.0.31) and MySQL Workbench. Optional: MongoDB + Compass, Python 3 (`pip install flask pymysql pymongo`).
2. In Workbench open each file (File → Open SQL Script) and run **in this order**:

| Order | File | What it does |
|---|---|---|
| 1 | `01_schema.sql` | Creates `helpdesk_db`, 22 tables |
| 2 | `02_data.sql` | Loads 724 rows (re-generate with `python3 generate_data.py > 02_data.sql`) |
| 3 | `03_views_indexes.sql` | 4 views, 20k-row index demo, EXPLAIN before/after, 6 indexes |
| 4 | `04_triggers_procs_functions.sql` | 4 triggers, 6 procedures, 2 functions |
| 5 | `05_queries.sql` | 18+ complex queries |
| 6 | `06_transactions_concurrency.sql` | Transactions + two-session demo |
| 7 | `07_rbac_security.sql` | Roles, users, injection demo |
| 8 | `08_test_cases.sql` | Positive/negative/integrity tests |
| 9 | `09_mongodb_extension.js` | MongoDB CRUD + aggregation |
| 10 | `10_app.py`, `11_sqli_demo.py` | Flask app + SQL injection demo |

Tips: if `DELIMITER` causes trouble, run the file with *Execute script (⚡)*. Statements that are **meant to fail** must be run one by one (Ctrl+Enter). If you hit error 1418 on functions: `SET GLOBAL log_bin_trust_function_creators = 1;`.

## Screenshot checklist (name files as shown, paste in report in this order)
| # | Screenshot | From |
|---|---|---|
| 1 | EER diagram (Database → Reverse Engineer) | after 01 |
| 2 | `SHOW TABLES` (22 tables) + row-count query | 01/02 |
| 3–20 | One per query Q1…Q18 (query + result grid) | 05 |
| 21 | 4 views output | 03 |
| 22 | EXPLAIN **before** indexes (type=ALL) | 03 (A) |
| 23 | EXPLAIN **after** indexes (type=ref/range) + `SHOW INDEX` | 03 (C) |
| 24 | Trigger creation + `SHOW TRIGGERS` | 04 |
| 25 | `sp_create_incident` → history + SLA rows + audit_log | 04 smoke test |
| 26 | `fn_sla_status` output | 04 |
| 27 | Transaction Scenario 1 COMMIT | 06 A1 |
| 28 | Scenario 2 error + ROLLBACK + unchanged row | 06 A2 |
| 29 | Scenario 3 SAVEPOINT (before / after rollback to savepoint) | 06 A3 |
| 30 | Scenario 4 auto-escalation | 06 A4 |
| 31 | Scenario 5 failed escalation but assignment kept | 06 A5 |
| 32 | Cursor SLA monitor result | 06 A7 |
| 33 | **Session A + Session B side by side**: B blocked on FOR UPDATE | 06 B2 |
| 34 | Session B after A commits → "already assigned" error | 06 B2 |
| 35 | Lost update (without lock) vs conditional update (1 vs 0 rows) | 06 B1/B3 |
| 36 | Deadlock ERROR 1213 + `SHOW ENGINE INNODB STATUS` | 06 B6 |
| 37 | `SHOW GRANTS` for 4 roles | 07 |
| 38 | End user: `SELECT * FROM incident` → ERROR 1142, `v_my_incidents` OK | 07 tests |
| 39 | Agent: DELETE/DROP denied | 07 tests |
| 40 | SQL injection succeeds (vulnerable) vs 0 rows (prepared) | 07 §6 or `11_sqli_demo.py` |
| 41 | Test-case outputs (constraint errors) | 08 |
| 42 | MongoDB: insert / find / update / delete | 09 |
| 43 | MongoDB: aggregation pipelines + `$lookup` | 09 |
| 44 | Flask app: open tickets, create ticket, assign, SLA page, Mongo activity | 10 |
| 45 | (Optional) MongoDB Atlas / cloud MySQL connection | — |

## Report outline (final report + PPT)
1 Problem & objectives · 2 Requirements & business rules · 3 ER/EER · 4 Schema & data dictionary · 5 FDs & normalization · 6 SQL queries (+screens) · 7 Views/indexes/EXPLAIN · 8 Triggers/procedures/functions · 9 Transactions & concurrency · 10 RBAC & injection · 11 MongoDB/NoSQL + SQL-vs-NoSQL justification · 12 Application · 13 Test cases · 14 Conclusion. (Content for 2–5 is already in `00_design_document.md`.)
