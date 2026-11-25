-- =====================================================================
-- File 06 : TRANSACTIONS (COMMIT / ROLLBACK / SAVEPOINT) + TWO-SESSION CONCURRENCY
-- Prerequisite: files 01-04 executed.
-- For Part B open TWO query tabs in MySQL Workbench (Session A and Session B)
-- (Workbench: File > New Query Tab). Each tab = separate connection.
-- status ids: 1 New, 2 Assigned, 3 In Progress, 4 Escalated, 5 Resolved, 6 Closed
-- =====================================================================
-- NOTE (Workbench): when a statement is *supposed* to fail (Scenarios 2, 6 and the ERROR lines) the editor stops
-- the script. Run those statements one by one (select the line -> Ctrl+Enter) and screenshot the error message.
USE helpdesk_db;

-- ---------- DEMO DATA (fixed ids so the demo is repeatable) ----------
DELETE FROM escalation       WHERE incident_id BETWEEN 9001 AND 9010;
DELETE FROM sla_tracking     WHERE incident_id BETWEEN 9001 AND 9010;
DELETE FROM incident_history WHERE incident_id BETWEEN 9001 AND 9010;
DELETE FROM resolution       WHERE incident_id BETWEEN 9001 AND 9010;
DELETE FROM incident         WHERE incident_id BETWEEN 9001 AND 9010;

INSERT INTO incident (incident_id, ticket_no, title, description, reporter_id, category_id,
                      priority_id, status_id, team_id, created_at) VALUES
 (9001,'INC-DEMO-9001','Core switch down - Floor 2','Critical outage',  20, 9, 1, 1, 2, NOW()),
 (9002,'INC-DEMO-9002','Payroll app crash (late)',  'Created 2h ago',  21,12, 1, 1, 3, NOW() - INTERVAL 2 HOUR),
 (9003,'INC-DEMO-9003','VPN down (many escalations)','Already escalated',22, 8, 1, 1, 2, NOW() - INTERVAL 3 HOUR),
 (9004,'INC-DEMO-9004','Deadlock demo ticket A',    'deadlock',        23, 6, 3, 1, 1, NOW()),
 (9005,'INC-DEMO-9005','Deadlock demo ticket B',    'deadlock',        24, 6, 3, 1, 1, NOW());
INSERT INTO escalation (incident_id, escalated_from_team, escalated_to_team, reason, escalation_level) VALUES
 (9003,2,5,'demo L1',1),(9003,5,5,'demo L2',2),(9003,5,5,'demo L3',3);

-- =====================================================================
-- PART A : TRANSACTION SCENARIOS  (single session)
-- =====================================================================

-- ---- Scenario 1: assign -> update status -> history -> COMMIT --------
SET @app_user_id = 1;
START TRANSACTION;
  UPDATE incident SET assigned_tech_id = 1 WHERE incident_id = 9001;   -- trigger sets status=2, history, SLA response
  SELECT incident_id, status_id, assigned_tech_id, assigned_at, row_version FROM incident WHERE incident_id = 9001;
  SELECT * FROM incident_history WHERE incident_id = 9001;
COMMIT;
SELECT * FROM sla_tracking WHERE incident_id = 9001;       -- responded_at filled, response_breached = 0

-- ---- Scenario 2: failure -> ROLLBACK of everything -------------------
START TRANSACTION;
  UPDATE incident SET assigned_tech_id = 2 WHERE incident_id = 9004;       -- ok
  UPDATE incident SET status_id = 6 WHERE incident_id = 9004;              -- FAILS: trigger blocks close before resolve
ROLLBACK;
SELECT incident_id, status_id, assigned_tech_id FROM incident WHERE incident_id = 9004;  -- unchanged: NULL tech, status 1
SELECT COUNT(*) AS history_rows FROM incident_history WHERE incident_id = 9004;          -- 1 (only creation)

-- ---- Scenario 3: SAVEPOINT - undo failed escalation, keep assignment --
START TRANSACTION;
  UPDATE incident SET assigned_tech_id = 3 WHERE incident_id = 9004;
  SAVEPOINT before_escalation;
    UPDATE incident SET status_id = 4 WHERE incident_id = 9004;
    INSERT INTO escalation (incident_id, escalated_from_team, escalated_to_team, reason, escalation_level)
    VALUES (9004, 1, 5, 'Manual escalation', 1);
    SELECT 'inside savepoint' AS step, status_id FROM incident WHERE incident_id = 9004;     -- 4
  ROLLBACK TO SAVEPOINT before_escalation;                                  -- escalation undone
  SELECT 'after rollback to savepoint' AS step, status_id, assigned_tech_id FROM incident WHERE incident_id = 9004;  -- 2, tech 3
COMMIT;
SELECT COUNT(*) AS escalations FROM escalation WHERE incident_id = 9004;   -- 0

-- ---- Scenario 4: stored procedure transaction (success) --------------
CALL sp_assign_incident(9002, 5, 1);     -- created 2h ago, Critical -> response SLA already breached -> auto-escalated
SELECT * FROM escalation WHERE incident_id = 9002;
SELECT * FROM incident_history WHERE incident_id = 9002 ORDER BY history_id;

-- ---- Scenario 5: SAVEPOINT inside procedure: escalation FAILS (level>3) but assignment is kept ----
CALL sp_assign_incident(9003, 3, 1);
SELECT incident_id, status_id, assigned_tech_id FROM incident WHERE incident_id = 9003;  -- assigned, NOT escalated again
SELECT COUNT(*) AS escalations FROM escalation WHERE incident_id = 9003;                 -- still 3

-- ---- Scenario 6: procedure failure -> full ROLLBACK ------------------
CALL sp_assign_incident(9002, 7, 1);     -- ERROR 1644: Incident already assigned to another technician
CALL sp_assign_incident(9001, 99, 1);    -- ERROR 1644: Technician not found or inactive
CALL sp_resolve_incident(9001, 1, 'Replaced faulty switch', 'Replaced Hardware', 1);   -- success
CALL sp_resolve_incident(9001, 1, 'again', 'Fixed', 1);                               -- ERROR: already resolved
SELECT ticket_no, status_id, resolved_at, fn_sla_status(incident_id) FROM incident WHERE incident_id = 9001;

-- ---- Scenario 7: SLA monitor (cursor) --------------------------------
UPDATE incident SET created_at = NOW() - INTERVAL 200 MINUTE WHERE incident_id = 9005;   -- High-risk ageing ticket
UPDATE incident SET priority_id = 1 WHERE incident_id = 9005;     -- trigger recalculates SLA deadlines
SELECT * FROM sla_tracking WHERE incident_id = 9005;
CALL sp_check_sla_and_escalate();                                  -- 9005 has used >=80% of 240 min
SELECT incident_id, status_id, team_id FROM incident WHERE incident_id = 9005;   -- status 4, team 5

-- =====================================================================
-- PART B : TWO-SESSION CONCURRENCY  (two Workbench tabs)
-- Goal: two agents try to assign the SAME unassigned critical incident.
-- Reset first (run once in any tab):
-- =====================================================================
DELETE FROM escalation       WHERE incident_id = 9010;
DELETE FROM sla_tracking     WHERE incident_id = 9010;
DELETE FROM incident_history WHERE incident_id = 9010;
DELETE FROM incident         WHERE incident_id = 9010;
INSERT INTO incident (incident_id, ticket_no, title, description, reporter_id, category_id,
                      priority_id, status_id, team_id, created_at)
VALUES (9010,'INC-DEMO-9010','Email server unreachable','Critical',25,12,1,1,3,NOW());

SELECT @@transaction_isolation;        -- default REPEATABLE-READ (InnoDB)

-- ---- B1. LOST UPDATE (BAD - no locking, shows the problem) -----------
-- Session A:  START TRANSACTION;
--             SELECT assigned_tech_id FROM incident WHERE incident_id = 9010;   -- NULL (looks free)
-- Session B:  START TRANSACTION;
--             SELECT assigned_tech_id FROM incident WHERE incident_id = 9010;   -- NULL (looks free)
-- Session A:  UPDATE incident SET assigned_tech_id = 5 WHERE incident_id = 9010;  COMMIT;
-- Session B:  UPDATE incident SET assigned_tech_id = 6 WHERE incident_id = 9010;  COMMIT;
-- RESULT: tech 6 silently overwrote tech 5 -> two agents both think they own the ticket. (Lost update)
-- Reset:      UPDATE incident SET assigned_tech_id = NULL, status_id = 1 WHERE incident_id = 9010;  -- (run as fix-up)

-- ---- B2. FIX 1 - pessimistic locking: SELECT ... FOR UPDATE ---------
-- Session A:  START TRANSACTION;
--             SELECT assigned_tech_id FROM incident WHERE incident_id = 9010 FOR UPDATE;   -- lock acquired
-- Session B:  START TRANSACTION;
--             SELECT assigned_tech_id FROM incident WHERE incident_id = 9010 FOR UPDATE;   -- BLOCKS (waiting)
-- Session A:  UPDATE incident SET assigned_tech_id = 5 WHERE incident_id = 9010;
--             COMMIT;                                                                       -- lock released
-- Session B:  (unblocks) returns assigned_tech_id = 5  -> B sees it is taken, so it does ROLLBACK;
-- RESULT: only ONE assignment; B is told "already assigned". No duplicate history rows.
--
-- The stored procedure does exactly this internally:
-- Session A:  CALL sp_assign_incident(9010, 5, 1);
-- Session B:  CALL sp_assign_incident(9010, 6, 2);   -- waits, then ERROR 1644 'Incident already assigned...'
-- (to make B visibly wait, in Session A first run:  START TRANSACTION; SELECT ... FOR UPDATE;  then call the proc in B,
--  wait ~10 s, then COMMIT in A.)

-- ---- B3. FIX 2 - atomic conditional update (no explicit lock needed) -
-- Session A:  UPDATE incident SET assigned_tech_id = 5 WHERE incident_id = 9010 AND assigned_tech_id IS NULL;  -- 1 row affected
-- Session B:  UPDATE incident SET assigned_tech_id = 6 WHERE incident_id = 9010 AND assigned_tech_id IS NULL;  -- 0 rows affected -> detect & report conflict

-- ---- B4. FIX 3 - optimistic locking with row_version ----------------
-- Both sessions first read:  SELECT row_version FROM incident WHERE incident_id = 9010;   -- e.g. 0
-- Session A:  UPDATE incident SET priority_id = 2 WHERE incident_id = 9010 AND row_version = 0;   -- 1 row (version -> 1 via trigger)
-- Session B:  UPDATE incident SET priority_id = 3 WHERE incident_id = 9010 AND row_version = 0;   -- 0 rows -> stale data, retry

-- ---- B5. ISOLATION LEVELS: non-repeatable read -----------------------
-- Session A:  SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
--             START TRANSACTION;  SELECT status_id FROM incident WHERE incident_id = 9010;    -- 1
-- Session B:  UPDATE incident SET status_id = 3 WHERE incident_id = 9010; COMMIT;
-- Session A:  SELECT status_id FROM incident WHERE incident_id = 9010;                        -- 3  (non-repeatable read)
--             COMMIT;
-- Repeat with REPEATABLE READ (default): second SELECT in A still returns the old value (snapshot).
-- Choice for this project: REPEATABLE READ + SELECT ... FOR UPDATE inside the assignment procedure.

-- ---- B6. DEADLOCK DEMO ----------------------------------------------
-- Session A:  START TRANSACTION;  UPDATE incident SET priority_id = 2 WHERE incident_id = 9004;
-- Session B:  START TRANSACTION;  UPDATE incident SET priority_id = 2 WHERE incident_id = 9005;
-- Session A:  UPDATE incident SET priority_id = 3 WHERE incident_id = 9005;   -- waits for B
-- Session B:  UPDATE incident SET priority_id = 3 WHERE incident_id = 9004;   -- DEADLOCK
--             ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction
--             InnoDB rolls back B (the victim); A completes.
-- Prevention: always lock rows in the same order (e.g. ORDER BY incident_id), keep transactions short, retry on 1213.
SHOW ENGINE INNODB STATUS;   -- section "LATEST DETECTED DEADLOCK" (screenshot)

-- ---- Final consistency checks (run after the demos) -----------------
SELECT incident_id, assigned_tech_id, status_id FROM incident WHERE incident_id = 9010;
SELECT COUNT(*) AS assignment_history_rows FROM incident_history WHERE incident_id = 9010 AND new_tech_id IS NOT NULL;

-- ---- CLEAN UP demo rows ---------------------------------------------
-- DELETE FROM escalation WHERE incident_id BETWEEN 9001 AND 9010;
-- DELETE FROM sla_tracking WHERE incident_id BETWEEN 9001 AND 9010;
-- DELETE FROM incident_history WHERE incident_id BETWEEN 9001 AND 9010;
-- DELETE FROM resolution WHERE incident_id BETWEEN 9001 AND 9010;
-- DELETE FROM incident WHERE incident_id BETWEEN 9001 AND 9010;
