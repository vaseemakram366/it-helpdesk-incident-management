-- =====================================================================
-- File 08 : TEST CASES  (positive / negative / integrity / transaction / concurrency)
-- Run each statement separately; "Expected" column goes into the report table.
-- =====================================================================
USE helpdesk_db;

-- ---------------- POSITIVE ------------------------------------------
-- TC-P1  Create incident via procedure                       Expected: ticket INC-2026-xxxxx returned, status New, SLA row + history row created
CALL sp_create_incident(15, 'Monitor flickers', 'Screen flickers every minute', 6, 3, @t);  SELECT @t;
-- TC-P2  Assign unassigned incident                           Expected: status Assigned, assigned_at set, history +1
-- CALL sp_assign_incident(<new id>, 1, 1);
-- TC-P3  Priority change recalculates SLA                     Expected: sla_tracking.resolution_due changes
-- UPDATE incident SET priority_id = 1 WHERE incident_id = <new id>;  SELECT * FROM sla_tracking WHERE incident_id = <new id>;
-- TC-P4  Function returns status                              Expected: ON TRACK / AT RISK / BREACHED / MET
SELECT fn_sla_status(1), fn_sla_status(5), fn_sla_status(10);

-- ---------------- NEGATIVE / INTEGRITY ------------------------------
-- TC-N1  Invalid FK (priority 9)                              Expected: ERROR 1452 foreign key fails
INSERT INTO incident (ticket_no,title,reporter_id,category_id,priority_id,team_id) VALUES ('X-1','t',14,6,9,1);
-- TC-N2  Duplicate ticket number                              Expected: ERROR 1062 duplicate entry
INSERT INTO incident (ticket_no,title,reporter_id,category_id,priority_id,team_id) VALUES ('INC-2026-00001','t',14,6,1,1);
-- TC-N3  CHECK: rating out of range                           Expected: ERROR 3819 check constraint chk_rating violated
INSERT INTO feedback (incident_id, rating) VALUES (1, 6);
-- TC-N4  CHECK: resolved before created                       Expected: ERROR 3819 chk_inc_resolved
UPDATE incident SET resolved_at = '2000-01-01 00:00:00' WHERE incident_id = 1;
-- TC-N5  Bad e-mail format                                    Expected: ERROR 3819 chk_email
INSERT INTO app_user (full_name,email,dept_id,role_id) VALUES ('Bad Mail','bademail',1,1);
-- TC-N6  Duplicate e-mail                                     Expected: ERROR 1062
INSERT INTO app_user (full_name,email,dept_id,role_id) VALUES ('Dup','aarav.singh1@corp.example',1,1);
-- TC-N7  Delete a referenced parent row                       Expected: ERROR 1451 cannot delete parent row
DELETE FROM department WHERE dept_id = 1;
-- TC-N8  SLA with resolution <= response                      Expected: ERROR 3819 chk_sla_times
INSERT INTO sla (sla_name, priority_id, response_minutes, resolution_minutes) VALUES ('bad', 1, 60, 30);

-- ---------------- BUSINESS-RULE (TRIGGER) ---------------------------
-- TC-B1  Close an incident that is not Resolved               Expected: ERROR 1644 'Incident can be closed only after it is Resolved'
UPDATE incident SET status_id = 6 WHERE status_id IN (2,3) LIMIT 1;
-- TC-B2  Modify a Closed incident                             Expected: ERROR 1644 'Closed incident cannot be modified'
UPDATE incident SET title = 'hack' WHERE status_id = 6 LIMIT 1;
-- TC-B3  Feedback before resolution                           Expected: ERROR 1644 'Feedback allowed only after the incident is resolved'
INSERT INTO feedback (incident_id, rating) VALUES ((SELECT MAX(incident_id) FROM incident WHERE status_id = 1), 5);
-- TC-B4  Resolve by a non-assigned technician                 Expected: ERROR 1644 'Only the assigned technician can resolve...'
-- CALL sp_resolve_incident(<assigned id>, <other tech>, 'x', 'Fixed', 1);
-- TC-B5  Duplicate escalation level                           Expected: ERROR 1062 uq_esc_level
-- INSERT INTO escalation(incident_id,escalated_from_team,escalated_to_team,reason,escalation_level) VALUES (<id with L1>,1,5,'dup',1);

-- ---------------- TRANSACTION ---------------------------------------
-- TC-T1  Failure inside transaction rolls back all changes    See 06 Scenario 2  (history count unchanged)
-- TC-T2  SAVEPOINT undo keeps assignment                      See 06 Scenario 3 / 5
-- TC-T3  Procedure failure leaves no partial rows             CALL sp_assign_incident(9001, 99, 1); SELECT COUNT(*) FROM incident_history WHERE incident_id = 9001;

-- ---------------- CONCURRENCY ---------------------------------------
-- TC-C1  Two agents assign same ticket (FOR UPDATE)           See 06 Part B2: exactly one assignment, second gets ERROR 1644
-- TC-C2  Lost update prevented by conditional UPDATE          See 06 Part B3: affected rows 1 vs 0
-- TC-C3  Deadlock detected & victim rolled back               See 06 Part B6: ERROR 1213
-- TC-C4  Consistency check after concurrency
SELECT incident_id, COUNT(*) AS assignment_rows FROM incident_history
WHERE new_tech_id IS NOT NULL AND old_tech_id IS NULL AND incident_id = 9010 GROUP BY incident_id;   -- must be <= 1

-- ---------------- SECURITY ------------------------------------------
-- TC-S1  End user reading base table                          07 test: ERROR 1142
-- TC-S2  SQL injection string against prepared statement      07 section 6.3: 0 rows
-- TC-S3  Agent tries DROP / DELETE                            07 test: ERROR 1142
