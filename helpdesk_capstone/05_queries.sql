-- =====================================================================
-- File 05 : COMPLEX SQL QUERY SET  (take one screenshot per query)
-- Reference "now" is fixed so results are reproducible with the sample data.
-- status ids: 1 New, 2 Assigned, 3 In Progress, 4 Escalated, 5 Resolved, 6 Closed
-- =====================================================================
USE helpdesk_db;
SET @now = '2026-11-15 10:00:00';

-- Q1. All open incidents assigned to a particular technician (INNER JOIN)
SELECT i.ticket_no, i.title, p.priority_name, s.status_name, i.created_at
FROM incident i
JOIN priority p        ON p.priority_id = i.priority_id
JOIN incident_status s ON s.status_id   = i.status_id
WHERE i.assigned_tech_id = 3 AND i.status_id IN (1,2,3,4)
ORDER BY p.rank_level, i.created_at;

-- Q2. Incidents that exceeded their SLA deadline (open & overdue OR resolved late)
SELECT i.ticket_no, p.priority_name, st.resolution_due, i.resolved_at,
       CASE WHEN i.resolved_at IS NULL THEN 'OPEN - OVERDUE' ELSE 'RESOLVED LATE' END AS breach_type
FROM incident i
JOIN sla_tracking st ON st.incident_id = i.incident_id
JOIN priority p      ON p.priority_id  = i.priority_id
WHERE (i.resolved_at IS NULL AND @now > st.resolution_due) OR i.resolved_at > st.resolution_due
ORDER BY p.rank_level, st.resolution_due;

-- Q3. Technicians whose average resolution time is BELOW their team average (correlated subquery in HAVING)
SELECT t.tech_id, u.full_name, t.team_id,
       ROUND(AVG(TIMESTAMPDIFF(MINUTE, i.created_at, i.resolved_at)), 1) AS avg_minutes
FROM technician t
JOIN app_user u ON u.user_id = t.user_id
JOIN incident i ON i.assigned_tech_id = t.tech_id AND i.resolved_at IS NOT NULL
GROUP BY t.tech_id, u.full_name, t.team_id
HAVING AVG(TIMESTAMPDIFF(MINUTE, i.created_at, i.resolved_at)) <
       (SELECT AVG(TIMESTAMPDIFF(MINUTE, i2.created_at, i2.resolved_at))
        FROM incident i2 JOIN technician t2 ON t2.tech_id = i2.assigned_tech_id
        WHERE i2.resolved_at IS NOT NULL AND t2.team_id = t.team_id);
-- (change < to > for technicians slower than the team average)

-- Q4. Rank technicians by resolved incidents: RANK vs DENSE_RANK
SELECT u.full_name, COUNT(*) AS resolved_count,
       RANK()       OVER (ORDER BY COUNT(*) DESC) AS rnk,
       DENSE_RANK() OVER (ORDER BY COUNT(*) DESC) AS dense_rnk
FROM incident i
JOIN technician t ON t.tech_id = i.assigned_tech_id
JOIN app_user u   ON u.user_id = t.user_id
WHERE i.status_id IN (5,6)
GROUP BY t.tech_id, u.full_name;

-- Q5. Top-2 incident categories per department (CTE + ROW_NUMBER, PARTITION BY)
WITH cat_dept AS (
  SELECT d.dept_name, c.category_name, COUNT(*) AS cnt
  FROM incident i
  JOIN app_user u          ON u.user_id = i.reporter_id
  JOIN department d        ON d.dept_id = u.dept_id
  JOIN incident_category c ON c.category_id = i.category_id
  GROUP BY d.dept_name, c.category_name),
ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY dept_name ORDER BY cnt DESC) AS rn FROM cat_dept)
SELECT dept_name, category_name, cnt FROM ranked WHERE rn <= 2 ORDER BY dept_name, cnt DESC;

-- Q6. Users who raised more than N (=2) incidents (GROUP BY / HAVING)
SELECT u.user_id, u.full_name, d.dept_name, COUNT(*) AS tickets
FROM incident i
JOIN app_user u   ON u.user_id = i.reporter_id
JOIN department d ON d.dept_id = u.dept_id
WHERE i.created_at BETWEEN '2026-08-01' AND '2026-11-15'
GROUP BY u.user_id, u.full_name, d.dept_name
HAVING COUNT(*) > 2
ORDER BY tickets DESC;

-- Q7. Recurring incidents on the same asset (>= 2) -> candidates for a Problem record
SELECT a.asset_tag, a.asset_type, a.model, COUNT(*) AS incidents,
       MIN(i.created_at) AS first_seen, MAX(i.created_at) AS last_seen
FROM incident_asset ia
JOIN asset a    ON a.asset_id = ia.asset_id
JOIN incident i ON i.incident_id = ia.incident_id
GROUP BY a.asset_id, a.asset_tag, a.asset_type, a.model
HAVING COUNT(*) >= 2
ORDER BY incidents DESC;

-- Q8. Weekly incident trend with week-over-week change (CTE + LAG)
WITH weekly AS (
  SELECT YEARWEEK(created_at, 1) AS yw, MIN(DATE(created_at)) AS week_start,
         COUNT(*) AS total, SUM(priority_id <= 2) AS high_critical
  FROM incident GROUP BY YEARWEEK(created_at, 1))
SELECT week_start, total, high_critical,
       LAG(total) OVER (ORDER BY yw)         AS prev_week,
       total - LAG(total) OVER (ORDER BY yw) AS change_vs_prev
FROM weekly ORDER BY yw;

-- Q9. Window function: each technician's avg resolution vs team average
WITH tech_avg AS (
  SELECT t.tech_id, u.full_name, t.team_id,
         AVG(TIMESTAMPDIFF(MINUTE, i.created_at, i.resolved_at)) AS avg_min
  FROM technician t
  JOIN app_user u ON u.user_id = t.user_id
  JOIN incident i ON i.assigned_tech_id = t.tech_id AND i.resolved_at IS NOT NULL
  GROUP BY t.tech_id, u.full_name, t.team_id)
SELECT full_name, team_id, ROUND(avg_min,1) AS avg_min,
       ROUND(AVG(avg_min) OVER (PARTITION BY team_id),1) AS team_avg,
       ROUND(avg_min - AVG(avg_min) OVER (PARTITION BY team_id),1) AS diff_from_team,
       CASE WHEN avg_min < AVG(avg_min) OVER (PARTITION BY team_id) THEN 'Faster' ELSE 'Slower' END AS vs_team
FROM tech_avg ORDER BY team_id, avg_min;

-- Q10a. SET OPERATION - UNION: every user who either reported OR resolved a ticket
SELECT reporter_id AS user_id, 'reporter' AS involvement FROM incident
UNION
SELECT t.user_id, 'technician' FROM technician t JOIN incident i ON i.assigned_tech_id = t.tech_id;

-- Q10b. SET OPERATION - EXCEPT: services hit by Network-type incidents but NOT by Application incidents
--       (INTERSECT / EXCEPT need MySQL 8.0.31+)
SELECT s.service_name FROM incident_service isv
  JOIN service s ON s.service_id = isv.service_id
  JOIN incident i ON i.incident_id = isv.incident_id WHERE i.category_id IN (8,9)
EXCEPT
SELECT s.service_name FROM incident_service isv
  JOIN service s ON s.service_id = isv.service_id
  JOIN incident i ON i.incident_id = isv.incident_id WHERE i.category_id = 12;

-- Q10c. SET OPERATION - INTERSECT: users who raised tickets in BOTH October and November 2026
SELECT reporter_id FROM incident WHERE created_at >= '2026-10-01' AND created_at < '2026-11-01'
INTERSECT
SELECT reporter_id FROM incident WHERE created_at >= '2026-11-01';
-- (older MySQL alternative: ... WHERE reporter_id IN (SELECT ...) )

-- Q11. Correlated subquery: incidents slower than the average of their own category
SELECT i.ticket_no, c.category_name,
       TIMESTAMPDIFF(MINUTE, i.created_at, i.resolved_at) AS minutes_taken
FROM incident i
JOIN incident_category c ON c.category_id = i.category_id
WHERE i.resolved_at IS NOT NULL
  AND TIMESTAMPDIFF(MINUTE, i.created_at, i.resolved_at) >
      (SELECT AVG(TIMESTAMPDIFF(MINUTE, x.created_at, x.resolved_at))
       FROM incident x WHERE x.category_id = i.category_id AND x.resolved_at IS NOT NULL)
ORDER BY minutes_taken DESC;

-- Q12. LEFT JOIN anti-join: technicians with NO open tickets (OUTER JOIN)
SELECT u.full_name, t.team_id
FROM technician t
JOIN app_user u ON u.user_id = t.user_id
LEFT JOIN incident i ON i.assigned_tech_id = t.tech_id AND i.status_id IN (1,2,3,4)
WHERE i.incident_id IS NULL;

-- Q13. SELF JOIN: category -> parent category hierarchy
SELECT child.category_name AS sub_category, parent.category_name AS parent_category
FROM incident_category child
LEFT JOIN incident_category parent ON parent.category_id = child.parent_category_id
ORDER BY parent_category, sub_category;

-- Q14. CROSS JOIN: priority x team matrix of open tickets (zero-filled)
SELECT p.priority_name, st.team_name, COUNT(i.incident_id) AS open_tickets
FROM priority p
CROSS JOIN support_team st
LEFT JOIN incident i ON i.priority_id = p.priority_id AND i.team_id = st.team_id AND i.status_id IN (1,2,3,4)
GROUP BY p.priority_id, p.priority_name, st.team_id, st.team_name
ORDER BY p.priority_id, st.team_id;

-- Q15. SLA compliance % by priority
SELECT p.priority_name, COUNT(*) AS tickets,
       SUM(st.resolution_breached) AS breached,
       ROUND(100 * (1 - SUM(st.resolution_breached) / COUNT(*)), 1) AS compliance_pct
FROM sla_tracking st
JOIN incident i ON i.incident_id = st.incident_id
JOIN priority p ON p.priority_id = i.priority_id
GROUP BY p.priority_id, p.priority_name ORDER BY p.priority_id;

-- Q16. Problem management: problems with most linked incidents + avg satisfaction
SELECT pr.problem_title, pr.problem_status, COUNT(DISTINCT ip.incident_id) AS linked_incidents,
       ROUND(AVG(f.rating),2) AS avg_rating
FROM problem pr
JOIN incident_problem ip ON ip.problem_id = pr.problem_id
LEFT JOIN feedback f     ON f.incident_id = ip.incident_id
GROUP BY pr.problem_id, pr.problem_title, pr.problem_status
ORDER BY linked_incidents DESC;

-- Q17. Running total of incidents per month (window SUM)
SELECT DATE_FORMAT(created_at,'%Y-%m') AS month, COUNT(*) AS tickets,
       SUM(COUNT(*)) OVER (ORDER BY DATE_FORMAT(created_at,'%Y-%m')) AS running_total
FROM incident GROUP BY DATE_FORMAT(created_at,'%Y-%m');

-- Q18. Using the views and the function
SELECT * FROM v_technician_workload ORDER BY open_tickets DESC;
SELECT * FROM v_unresolved_high_priority;
SELECT ticket_no, fn_sla_status(incident_id) AS sla_status FROM incident
WHERE status_id IN (1,2,3,4) ORDER BY ticket_no;
