-- =====================================================================
-- File 03 : VIEWS + INDEXES (with EXPLAIN performance justification)
-- =====================================================================
USE helpdesk_db;

-- ------------------------- VIEWS -------------------------------------
-- status ids: 1 New, 2 Assigned, 3 In Progress, 4 Escalated, 5 Resolved, 6 Closed

CREATE OR REPLACE VIEW v_open_incidents AS
SELECT i.incident_id, i.ticket_no, i.title, p.priority_name, s.status_name,
       t.team_name, u.full_name AS reporter, tu.full_name AS technician,
       i.created_at, st.resolution_due
FROM incident i
JOIN priority p        ON p.priority_id = i.priority_id
JOIN incident_status s ON s.status_id   = i.status_id
JOIN support_team t    ON t.team_id     = i.team_id
JOIN app_user u        ON u.user_id     = i.reporter_id
LEFT JOIN technician te ON te.tech_id   = i.assigned_tech_id
LEFT JOIN app_user tu   ON tu.user_id   = te.user_id
LEFT JOIN sla_tracking st ON st.incident_id = i.incident_id
WHERE i.status_id IN (1,2,3,4);

CREATE OR REPLACE VIEW v_sla_breaches AS
SELECT i.incident_id, i.ticket_no, p.priority_name, i.status_id,
       st.resolution_due, i.resolved_at,
       CASE WHEN i.resolved_at IS NULL
            THEN TIMESTAMPDIFF(MINUTE, st.resolution_due, NOW())
            ELSE TIMESTAMPDIFF(MINUTE, st.resolution_due, i.resolved_at) END AS minutes_over_sla
FROM incident i
JOIN sla_tracking st ON st.incident_id = i.incident_id
JOIN priority p      ON p.priority_id  = i.priority_id
WHERE (i.resolved_at IS NULL AND NOW() > st.resolution_due)
   OR (i.resolved_at > st.resolution_due);

CREATE OR REPLACE VIEW v_technician_workload AS
SELECT te.tech_id, u.full_name, t.team_name,
       COUNT(CASE WHEN i.status_id IN (1,2,3,4) THEN 1 END) AS open_tickets,
       COUNT(CASE WHEN i.status_id IN (5,6)     THEN 1 END) AS resolved_tickets
FROM technician te
JOIN app_user u     ON u.user_id = te.user_id
JOIN support_team t ON t.team_id = te.team_id
LEFT JOIN incident i ON i.assigned_tech_id = te.tech_id
GROUP BY te.tech_id, u.full_name, t.team_name;

CREATE OR REPLACE VIEW v_unresolved_high_priority AS
SELECT i.incident_id, i.ticket_no, i.title, p.priority_name, s.status_name,
       i.created_at, TIMESTAMPDIFF(HOUR, i.created_at, NOW()) AS age_hours
FROM incident i
JOIN priority p        ON p.priority_id = i.priority_id
JOIN incident_status s ON s.status_id   = i.status_id
WHERE i.priority_id IN (1,2) AND i.status_id IN (1,2,3,4);

SELECT * FROM v_open_incidents LIMIT 10;
SELECT * FROM v_sla_breaches LIMIT 10;
SELECT * FROM v_technician_workload;
SELECT * FROM v_unresolved_high_priority;

-- ------------------------- INDEX PERFORMANCE DEMO --------------------
-- 60 rows is too small to show a benefit, so load 20,000 temporary rows.
SET SESSION cte_max_recursion_depth = 25000;
INSERT INTO incident (ticket_no, title, description, reporter_id, category_id, priority_id,
                      status_id, team_id, assigned_tech_id, created_at)
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
SELECT CONCAT('BULK-', i), 'bulk row', 'performance test', 14 + (i % 27), 6 + (i % 7),
       1 + (i % 4), 1 + (i % 6), 1 + (i % 5), IF(1 + (i % 6) >= 2, 1 + (i % 10), NULL),
       NOW() - INTERVAL (i % 180) DAY
FROM n;
SELECT COUNT(*) AS total_rows FROM incident;

-- (A) BEFORE indexes  -> screenshot the plan (type = ALL, rows ~ 20000)
EXPLAIN SELECT incident_id, ticket_no FROM incident
WHERE status_id = 3 AND priority_id = 1;
EXPLAIN ANALYZE SELECT incident_id FROM incident
WHERE assigned_tech_id = 4 AND status_id IN (1,2,3,4);
EXPLAIN SELECT COUNT(*) FROM incident WHERE created_at >= '2026-11-01';

-- (B) CREATE INDEXES
CREATE INDEX idx_incident_status_priority ON incident (status_id, priority_id);      -- open-ticket dashboards
CREATE INDEX idx_incident_assignee_status ON incident (assigned_tech_id, status_id); -- technician workload
CREATE INDEX idx_incident_created         ON incident (created_at);                  -- trend / date-range reports
CREATE INDEX idx_sla_resolution_due       ON sla_tracking (resolution_due);          -- SLA breach scans
CREATE INDEX idx_history_incident_time    ON incident_history (incident_id, changed_at); -- audit trail lookups
CREATE INDEX idx_incident_reporter        ON incident (reporter_id);                 -- "my tickets"

ANALYZE TABLE incident;

-- (C) AFTER indexes -> screenshot (type = ref/range, rows drops sharply)
EXPLAIN SELECT incident_id, ticket_no FROM incident
WHERE status_id = 3 AND priority_id = 1;
EXPLAIN ANALYZE SELECT incident_id FROM incident
WHERE assigned_tech_id = 4 AND status_id IN (1,2,3,4);
EXPLAIN SELECT COUNT(*) FROM incident WHERE created_at >= '2026-11-01';
SHOW INDEX FROM incident;

-- (D) CLEAN UP the temporary rows (keeps the 60 real incidents)
DELETE FROM incident WHERE ticket_no LIKE 'BULK-%';
ALTER TABLE incident AUTO_INCREMENT = 61;
SELECT COUNT(*) AS rows_after_cleanup FROM incident;   -- 60
