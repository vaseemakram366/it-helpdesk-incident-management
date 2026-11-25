-- =====================================================================
-- File 07 : RBAC (least privilege) + SQL-INJECTION PREVENTION   (MySQL 8 roles)
-- Run as root/admin. Then open NEW Workbench connections as each user to test.
-- =====================================================================
USE helpdesk_db;

-- ---------- 1. ROLES -------------------------------------------------
CREATE ROLE IF NOT EXISTS 'role_end_user', 'role_agent', 'role_manager', 'role_admin';

-- ---------- 2. Objects that let END USERS work without table access ---
-- an end user sees ONLY their own tickets (account name = e-mail local part)
CREATE OR REPLACE VIEW v_my_incidents AS
SELECT i.ticket_no, i.title, s.status_name, p.priority_name, i.created_at, i.resolved_at
FROM incident i
JOIN app_user u        ON u.user_id = i.reporter_id
JOIN incident_status s ON s.status_id = i.status_id
JOIN priority p        ON p.priority_id = i.priority_id
WHERE SUBSTRING_INDEX(u.email, '@', 1) = SUBSTRING_INDEX(SESSION_USER(), '@', 1);

DROP PROCEDURE IF EXISTS sp_raise_ticket;
DROP PROCEDURE IF EXISTS sp_search_incidents;
DELIMITER $$
-- reporter is derived from the logged-in account -> user cannot raise tickets on behalf of someone else
CREATE PROCEDURE sp_raise_ticket(IN p_title VARCHAR(150), IN p_desc TEXT, IN p_category INT,
                                 IN p_priority TINYINT, OUT p_ticket VARCHAR(30))
BEGIN
  DECLARE v_user INT;
  SELECT user_id INTO v_user FROM app_user
   WHERE SUBSTRING_INDEX(email, '@', 1) = SUBSTRING_INDEX(SESSION_USER(), '@', 1) AND is_active = 1;
  IF v_user IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Your login is not mapped to an active user';
  END IF;
  CALL sp_create_incident(v_user, p_title, p_desc, p_category, p_priority, p_ticket);
END$$

-- injection-safe search: keyword is a PARAMETER, ORDER BY column is WHITELISTED
CREATE PROCEDURE sp_search_incidents(IN p_keyword VARCHAR(100), IN p_sort VARCHAR(20))
BEGIN
  SELECT ticket_no, title, status_id, priority_id, created_at
  FROM incident
  WHERE title LIKE CONCAT('%', p_keyword, '%')
  ORDER BY CASE WHEN p_sort = 'priority' THEN priority_id END,
           CASE WHEN p_sort = 'status'   THEN status_id   END,
           created_at DESC;
END$$
DELIMITER ;

-- ---------- 3. PRIVILEGES --------------------------------------------
-- END USER: own tickets (view) + raise ticket (procedure). No table access at all.
GRANT SELECT  ON helpdesk_db.v_my_incidents      TO 'role_end_user';
GRANT EXECUTE ON PROCEDURE helpdesk_db.sp_raise_ticket TO 'role_end_user';

-- HELPDESK AGENT: read operational data, change data ONLY through procedures (so rules/triggers always run)
GRANT SELECT  ON helpdesk_db.v_open_incidents          TO 'role_agent';
GRANT SELECT  ON helpdesk_db.v_technician_workload     TO 'role_agent';
GRANT SELECT  ON helpdesk_db.v_sla_breaches            TO 'role_agent';
GRANT SELECT  ON helpdesk_db.v_unresolved_high_priority TO 'role_agent';
GRANT SELECT  ON helpdesk_db.incident                  TO 'role_agent';
GRANT SELECT  ON helpdesk_db.incident_history          TO 'role_agent';
GRANT SELECT  ON helpdesk_db.asset                     TO 'role_agent';
GRANT SELECT  ON helpdesk_db.service                   TO 'role_agent';
GRANT EXECUTE ON PROCEDURE helpdesk_db.sp_create_incident  TO 'role_agent';
GRANT EXECUTE ON PROCEDURE helpdesk_db.sp_assign_incident  TO 'role_agent';
GRANT EXECUTE ON PROCEDURE helpdesk_db.sp_resolve_incident TO 'role_agent';
GRANT EXECUTE ON PROCEDURE helpdesk_db.sp_escalate_incident TO 'role_agent';
GRANT EXECUTE ON PROCEDURE helpdesk_db.sp_search_incidents TO 'role_agent';

-- IT MANAGER: read everything (reports, audit log), run procedures, but no DDL / no direct DML
GRANT SELECT, EXECUTE ON helpdesk_db.* TO 'role_manager';

-- ADMINISTRATOR: full control of this schema only
GRANT ALL PRIVILEGES ON helpdesk_db.* TO 'role_admin';

-- ---------- 4. DEMO ACCOUNTS -----------------------------------------
-- (Pooja Gupta, user_id 14, e-mail pooja.gupta14@corp.example -> account name pooja.gupta14)
DROP USER IF EXISTS 'pooja.gupta14'@'localhost', 'agent_aarav'@'localhost', 'mgr_riya'@'localhost', 'it_admin'@'localhost';
CREATE USER 'pooja.gupta14'@'localhost' IDENTIFIED BY 'User@1234';
CREATE USER 'agent_aarav'@'localhost'   IDENTIFIED BY 'Agent@1234';
CREATE USER 'mgr_riya'@'localhost'      IDENTIFIED BY 'Mgr@1234';
CREATE USER 'it_admin'@'localhost'      IDENTIFIED BY 'Admin@1234';
GRANT 'role_end_user' TO 'pooja.gupta14'@'localhost';
GRANT 'role_agent'    TO 'agent_aarav'@'localhost';
GRANT 'role_manager'  TO 'mgr_riya'@'localhost';
GRANT 'role_admin'    TO 'it_admin'@'localhost';
SET DEFAULT ROLE ALL TO 'pooja.gupta14'@'localhost', 'agent_aarav'@'localhost', 'mgr_riya'@'localhost', 'it_admin'@'localhost';

SHOW GRANTS FOR 'role_end_user';     -- screenshot
SHOW GRANTS FOR 'role_agent';
SHOW GRANTS FOR 'role_manager';
SHOW GRANTS FOR 'role_admin';

-- =====================================================================
-- 5. RBAC TEST CASES  (login with the given account; screenshot every result)
-- =====================================================================
-- ---- as pooja.gupta14 (END USER) ----
-- SELECT * FROM incident;                         -- ERROR 1142: SELECT command denied
-- SELECT * FROM app_user;                         -- ERROR 1142
-- SELECT * FROM v_my_incidents;                   -- OK: only her own tickets
-- CALL sp_raise_ticket('Laptop fan noisy','Loud noise from fan',6,3,@t); SELECT @t;   -- OK
-- CALL sp_assign_incident(1,1,14);                -- ERROR 1370: EXECUTE command denied
-- DELETE FROM incident;                           -- ERROR 1142: DELETE command denied
--
-- ---- as agent_aarav (AGENT) ----
-- SELECT * FROM v_open_incidents;                 -- OK
-- CALL sp_assign_incident(<open_unassigned_id>, 1, 1);   -- OK
-- UPDATE incident SET status_id = 6;              -- ERROR 1142: UPDATE denied (changes only via procedures)
-- DELETE FROM incident_history;                   -- ERROR 1142
-- SELECT * FROM audit_log;                        -- ERROR 1142 (audit log hidden from agents)
-- DROP TABLE incident;                            -- ERROR 1142
--
-- ---- as mgr_riya (MANAGER) ----
-- SELECT * FROM audit_log ORDER BY audit_id DESC LIMIT 10;   -- OK
-- SELECT * FROM v_sla_breaches;                              -- OK
-- INSERT INTO department(dept_name) VALUES ('X');            -- ERROR 1142: INSERT denied
--
-- ---- as it_admin (ADMIN) ----
-- full access inside helpdesk_db; but:  DROP DATABASE mysql;  -- ERROR 1044 (no access outside schema)

-- =====================================================================
-- 6. SQL-INJECTION PREVENTION DEMO  (run as root)
-- =====================================================================
-- ---- 6.1 VULNERABLE: string concatenation (what NOT to do) ----
SET @user_input = "zzz' OR '1'='1";
SET @sql = CONCAT("SELECT ticket_no, title FROM incident WHERE title = '", @user_input, "'");
SELECT @sql AS built_query;                          -- ... WHERE title = 'zzz' OR '1'='1'
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;     -- returns EVERY incident (attack succeeded)

-- ---- 6.2 VULNERABLE: UNION-based data theft ----
SET @user_input = "zzz' UNION SELECT email, full_name FROM app_user -- ";
SET @sql = CONCAT("SELECT ticket_no, title FROM incident WHERE title = '", @user_input, "'");
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;     -- leaks all user e-mails

-- ---- 6.3 SAFE: parameterised (prepared) statement ----
PREPARE stmt FROM 'SELECT ticket_no, title FROM incident WHERE title = ?';
SET @user_input = "zzz' OR '1'='1";
EXECUTE stmt USING @user_input;                      -- 0 rows: input is DATA, never SQL
SET @user_input = "zzz' UNION SELECT email, full_name FROM app_user -- ";
EXECUTE stmt USING @user_input;                      -- 0 rows
DEALLOCATE PREPARE stmt;

-- ---- 6.4 SAFE: stored procedure with parameter + whitelisted ORDER BY ----
CALL sp_search_incidents('VPN', 'priority');                    -- normal use
CALL sp_search_incidents("x' OR '1'='1", 'priority');           -- 0 rows
CALL sp_search_incidents('VPN', 'priority; DROP TABLE incident');   -- sort ignored (whitelist), table safe
SELECT COUNT(*) AS incident_table_still_exists FROM incident;

-- ---- 6.5 Defence-in-depth summary (put in report) ----
-- 1. Parameterised queries / prepared statements (app code: see 10_app.py and 11_sqli_demo.py)
-- 2. Least-privilege accounts: the app connects as role_agent, so even a successful injection cannot DROP/DELETE
-- 3. Stored procedures + whitelisting for dynamic identifiers (ORDER BY column names)
-- 4. Input validation + CHECK constraints; error messages never expose SQL to end users
-- 5. Audit log of all status/assignment/priority changes
