-- =====================================================================
-- File 04 : TRIGGERS, STORED PROCEDURES, FUNCTIONS  (SLA-aware workflow)
-- In MySQL Workbench run the whole file; DELIMITER is handled by the editor.
-- status ids: 1 New, 2 Assigned, 3 In Progress, 4 Escalated, 5 Resolved, 6 Closed
-- =====================================================================
USE helpdesk_db;

DROP TRIGGER IF EXISTS trg_incident_ai;
DROP TRIGGER IF EXISTS trg_incident_bu;
DROP TRIGGER IF EXISTS trg_incident_au;
DROP TRIGGER IF EXISTS trg_feedback_bi;
DROP PROCEDURE IF EXISTS sp_create_incident;
DROP PROCEDURE IF EXISTS sp_do_escalation;
DROP PROCEDURE IF EXISTS sp_escalate_incident;
DROP PROCEDURE IF EXISTS sp_assign_incident;
DROP PROCEDURE IF EXISTS sp_resolve_incident;
DROP PROCEDURE IF EXISTS sp_check_sla_and_escalate;
DROP FUNCTION  IF EXISTS fn_sla_status;
DROP FUNCTION  IF EXISTS fn_avg_resolution_hours;

DELIMITER $$

-- =====================  FUNCTIONS  ===================================
CREATE FUNCTION fn_sla_status(p_incident INT) RETURNS VARCHAR(12)
READS SQL DATA
BEGIN
  DECLARE v_due DATETIME; DECLARE v_res DATETIME; DECLARE v_created DATETIME;
  SELECT st.resolution_due, i.resolved_at, i.created_at
    INTO v_due, v_res, v_created
  FROM incident i JOIN sla_tracking st ON st.incident_id = i.incident_id
  WHERE i.incident_id = p_incident;

  IF v_due IS NULL THEN RETURN 'UNKNOWN'; END IF;
  IF v_res IS NOT NULL THEN RETURN IF(v_res <= v_due, 'MET', 'BREACHED'); END IF;
  IF NOW() > v_due THEN RETURN 'BREACHED'; END IF;
  IF NOW() >= DATE_ADD(v_created, INTERVAL ROUND(0.8 * TIMESTAMPDIFF(MINUTE, v_created, v_due)) MINUTE)
     THEN RETURN 'AT RISK'; END IF;
  RETURN 'ON TRACK';
END$$

CREATE FUNCTION fn_avg_resolution_hours(p_tech INT) RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
  DECLARE v_avg DECIMAL(10,2);
  SELECT ROUND(AVG(TIMESTAMPDIFF(MINUTE, created_at, resolved_at)) / 60, 2) INTO v_avg
  FROM incident WHERE assigned_tech_id = p_tech AND resolved_at IS NOT NULL;
  RETURN IFNULL(v_avg, 0);
END$$

-- =====================  TRIGGERS  ====================================
-- T1: after a ticket is created -> start history, compute SLA deadlines, audit
CREATE TRIGGER trg_incident_ai AFTER INSERT ON incident
FOR EACH ROW
BEGIN
  INSERT INTO incident_history (incident_id, old_status_id, new_status_id, changed_by, change_note, changed_at)
  VALUES (NEW.incident_id, NULL, NEW.status_id, NEW.reporter_id, 'Ticket created', NEW.created_at);

  INSERT INTO sla_tracking (incident_id, sla_id, response_due, resolution_due)
  SELECT NEW.incident_id, s.sla_id,
         NEW.created_at + INTERVAL s.response_minutes   MINUTE,
         NEW.created_at + INTERVAL s.resolution_minutes MINUTE
  FROM sla s WHERE s.priority_id = NEW.priority_id;

  INSERT INTO audit_log (table_name, record_id, action, new_value, db_user)
  VALUES ('incident', NEW.incident_id, 'INSERT',
          CONCAT('priority=', NEW.priority_id, ';status=', NEW.status_id), CURRENT_USER());
END$$

-- T2: business-rule guard + automatic timestamps + optimistic-lock version
CREATE TRIGGER trg_incident_bu BEFORE UPDATE ON incident
FOR EACH ROW
BEGIN
  IF OLD.status_id = 6 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Closed incident cannot be modified';
  END IF;
  IF NEW.status_id = 6 AND OLD.status_id <> 5 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Incident can be closed only after it is Resolved';
  END IF;
  IF NEW.status_id = 5 AND OLD.status_id = 1 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Incident must be assigned before it can be resolved';
  END IF;

  IF OLD.assigned_tech_id IS NULL AND NEW.assigned_tech_id IS NOT NULL THEN
    SET NEW.assigned_at = NOW();
    IF NEW.status_id = 1 THEN SET NEW.status_id = 2; END IF;
  END IF;
  IF NEW.status_id = 5 AND OLD.status_id <> 5 THEN SET NEW.resolved_at = NOW(); END IF;
  IF NEW.status_id = 6 AND OLD.status_id <> 6 THEN SET NEW.closed_at   = NOW(); END IF;
  SET NEW.row_version = OLD.row_version + 1;
END$$

-- T3: after update -> history, audit log, SLA re-calculation / SLA flags
CREATE TRIGGER trg_incident_au AFTER UPDATE ON incident
FOR EACH ROW
BEGIN
  IF NOT (NEW.status_id <=> OLD.status_id) OR NOT (NEW.assigned_tech_id <=> OLD.assigned_tech_id) THEN
    INSERT INTO incident_history (incident_id, old_status_id, new_status_id, old_tech_id, new_tech_id,
                                  changed_by, change_note, changed_at)
    VALUES (NEW.incident_id, OLD.status_id, NEW.status_id, OLD.assigned_tech_id, NEW.assigned_tech_id,
            @app_user_id,
            CASE WHEN NEW.status_id = 4 THEN 'Escalated'
                 WHEN NOT (NEW.assigned_tech_id <=> OLD.assigned_tech_id) THEN 'Assignment changed'
                 ELSE 'Status changed' END, NOW());
  END IF;

  IF NOT (NEW.priority_id <=> OLD.priority_id) THEN        -- priority change -> new SLA deadlines
    UPDATE sla_tracking st JOIN sla s ON s.priority_id = NEW.priority_id
       SET st.sla_id = s.sla_id,
           st.response_due   = NEW.created_at + INTERVAL s.response_minutes   MINUTE,
           st.resolution_due = NEW.created_at + INTERVAL s.resolution_minutes MINUTE
     WHERE st.incident_id = NEW.incident_id;
  END IF;

  IF OLD.assigned_tech_id IS NULL AND NEW.assigned_tech_id IS NOT NULL THEN   -- first response
    UPDATE sla_tracking SET responded_at = NEW.assigned_at,
           response_breached = (NEW.assigned_at > response_due)
     WHERE incident_id = NEW.incident_id;
  END IF;
  IF NEW.resolved_at IS NOT NULL AND OLD.resolved_at IS NULL THEN              -- resolution
    UPDATE sla_tracking SET resolution_breached = (NEW.resolved_at > resolution_due)
     WHERE incident_id = NEW.incident_id;
  END IF;

  IF NOT (NEW.status_id <=> OLD.status_id) OR NOT (NEW.assigned_tech_id <=> OLD.assigned_tech_id)
     OR NOT (NEW.priority_id <=> OLD.priority_id) THEN
    INSERT INTO audit_log (table_name, record_id, action, old_value, new_value, db_user)
    VALUES ('incident', NEW.incident_id, 'UPDATE',
            CONCAT('status=', OLD.status_id, ';tech=', IFNULL(OLD.assigned_tech_id,'NULL'), ';priority=', OLD.priority_id),
            CONCAT('status=', NEW.status_id, ';tech=', IFNULL(NEW.assigned_tech_id,'NULL'), ';priority=', NEW.priority_id),
            CURRENT_USER());
  END IF;
END$$

-- T4: feedback allowed only for Resolved/Closed incidents
CREATE TRIGGER trg_feedback_bi BEFORE INSERT ON feedback
FOR EACH ROW
BEGIN
  DECLARE v_status TINYINT;
  SELECT status_id INTO v_status FROM incident WHERE incident_id = NEW.incident_id;
  IF v_status IS NULL OR v_status NOT IN (5, 6) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Feedback allowed only after the incident is resolved';
  END IF;
END$$

-- =====================  PROCEDURES  ==================================
-- P1: create incident (ticket number generated, SLA created by trigger T1)
CREATE PROCEDURE sp_create_incident(IN p_reporter INT, IN p_title VARCHAR(150), IN p_desc TEXT,
                                    IN p_category INT, IN p_priority TINYINT, OUT p_ticket VARCHAR(30))
BEGIN
  DECLARE v_team INT; DECLARE v_id INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SELECT default_team_id INTO v_team FROM incident_category WHERE category_id = p_category;
  IF v_team IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid incident category';
  END IF;

  START TRANSACTION;
    INSERT INTO incident (ticket_no, title, description, reporter_id, category_id, priority_id, status_id, team_id)
    VALUES (CONCAT('TMP-', UUID_SHORT()), p_title, p_desc, p_reporter, p_category, p_priority, 1, v_team);
    SET v_id = LAST_INSERT_ID();
    SET p_ticket = CONCAT('INC-', YEAR(NOW()), '-', LPAD(v_id, 5, '0'));
    UPDATE incident SET ticket_no = p_ticket WHERE incident_id = v_id;
  COMMIT;
END$$

-- P2 (internal, NO transaction control): escalate to Tier-2 team
CREATE PROCEDURE sp_do_escalation(IN p_incident INT, IN p_reason VARCHAR(200))
BEGIN
  DECLARE v_team INT; DECLARE v_status INT; DECLARE v_level INT;
  SELECT team_id, status_id INTO v_team, v_status FROM incident WHERE incident_id = p_incident;
  IF v_status IS NULL OR v_status IN (5, 6) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only open incidents can be escalated';
  END IF;
  SELECT COUNT(*) + 1 INTO v_level FROM escalation WHERE incident_id = p_incident;
  IF v_level > 3 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maximum escalation level (3) already reached';
  END IF;
  INSERT INTO escalation (incident_id, escalated_from_team, escalated_to_team, reason, escalation_level)
  VALUES (p_incident, v_team, 5, p_reason, v_level);
  UPDATE incident SET status_id = 4, team_id = 5 WHERE incident_id = p_incident;
END$$

-- P3: standalone escalation (own transaction)
CREATE PROCEDURE sp_escalate_incident(IN p_incident INT, IN p_reason VARCHAR(200))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
    CALL sp_do_escalation(p_incident, p_reason);
  COMMIT;
END$$

-- P4: SLA-aware assignment  (MANDATORY CHALLENGE)
--   assign -> status update -> history (trigger) -> SAVEPOINT -> escalate if response SLA missed
CREATE PROCEDURE sp_assign_incident(IN p_incident INT, IN p_tech INT, IN p_by INT)
BEGIN
  DECLARE v_cur_tech INT; DECLARE v_status INT; DECLARE v_prio INT;
  DECLARE v_active TINYINT; DECLARE v_late INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  SET @app_user_id = p_by;
  START TRANSACTION;
    -- row lock: a second agent assigning the same ticket waits here
    SELECT assigned_tech_id, status_id, priority_id INTO v_cur_tech, v_status, v_prio
    FROM incident WHERE incident_id = p_incident FOR UPDATE;

    IF v_status IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Incident not found';
    END IF;
    IF v_status IN (5, 6) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Resolved/closed incident cannot be assigned';
    END IF;
    IF v_cur_tech IS NOT NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Incident already assigned to another technician';
    END IF;
    SELECT is_active INTO v_active FROM technician WHERE tech_id = p_tech;
    IF v_active IS NULL OR v_active = 0 THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Technician not found or inactive';
    END IF;

    UPDATE incident SET assigned_tech_id = p_tech, status_id = 2 WHERE incident_id = p_incident;
    -- trigger T3 wrote history + audit + responded_at in SLA tracking

    SAVEPOINT before_escalation;
    BEGIN
      DECLARE EXIT HANDLER FOR SQLEXCEPTION ROLLBACK TO SAVEPOINT before_escalation;
      SELECT COUNT(*) INTO v_late FROM sla_tracking
       WHERE incident_id = p_incident AND response_due < NOW();
      IF v_prio <= 2 AND v_late > 0 THEN
        CALL sp_do_escalation(p_incident, 'Auto: response SLA already breached at assignment');
      END IF;
    END;
  COMMIT;

  SELECT ticket_no, status_id, assigned_tech_id, row_version, fn_sla_status(incident_id) AS sla_status
  FROM incident WHERE incident_id = p_incident;
END$$

-- P5: resolve incident (resolution record + status update must be atomic)
CREATE PROCEDURE sp_resolve_incident(IN p_incident INT, IN p_tech INT, IN p_text TEXT,
                                     IN p_code VARCHAR(30), IN p_by INT)
BEGIN
  DECLARE v_tech INT; DECLARE v_status INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  SET @app_user_id = p_by;
  START TRANSACTION;
    SELECT assigned_tech_id, status_id INTO v_tech, v_status
    FROM incident WHERE incident_id = p_incident FOR UPDATE;
    IF v_tech IS NULL OR v_tech <> p_tech THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only the assigned technician can resolve this incident';
    END IF;
    IF v_status IN (5, 6) THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Incident already resolved';
    END IF;
    INSERT INTO resolution (incident_id, resolved_by_tech_id, resolution_text, resolution_code)
    VALUES (p_incident, p_tech, p_text, p_code);
    UPDATE incident SET status_id = 5 WHERE incident_id = p_incident;
  COMMIT;
  SELECT ticket_no, status_id, resolved_at, fn_sla_status(incident_id) AS sla_status
  FROM incident WHERE incident_id = p_incident;
END$$

-- P6: CURSOR - scan open High/Critical tickets that consumed >= 80% of SLA and escalate them
CREATE PROCEDURE sp_check_sla_and_escalate()
BEGIN
  DECLARE done INT DEFAULT 0; DECLARE v_inc INT; DECLARE v_cnt INT DEFAULT 0;
  DECLARE cur CURSOR FOR
    SELECT i.incident_id
    FROM incident i JOIN sla_tracking st ON st.incident_id = i.incident_id
    WHERE i.status_id IN (1, 2, 3) AND i.priority_id IN (1, 2)
      AND NOW() >= DATE_ADD(i.created_at,
            INTERVAL ROUND(0.8 * TIMESTAMPDIFF(MINUTE, i.created_at, st.resolution_due)) MINUTE);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  SET @app_user_id = NULL;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO v_inc;
    IF done = 1 THEN LEAVE read_loop; END IF;
    CALL sp_escalate_incident(v_inc, 'Auto: 80% of resolution SLA consumed or breached');
    SET v_cnt = v_cnt + 1;
  END LOOP;
  CLOSE cur;
  SELECT v_cnt AS incidents_escalated;
END$$

DELIMITER ;

-- OPTIONAL: run the SLA monitor automatically every 5 minutes
-- SET GLOBAL event_scheduler = ON;
-- CREATE EVENT ev_sla_monitor ON SCHEDULE EVERY 5 MINUTE DO CALL sp_check_sla_and_escalate();

-- ---------- quick smoke tests (screenshot these) ----------
SELECT incident_id, ticket_no, fn_sla_status(incident_id) AS sla_status FROM incident ORDER BY incident_id LIMIT 10;
SELECT tech_id, fn_avg_resolution_hours(tech_id) AS avg_resolution_hours FROM technician;
CALL sp_create_incident(20, 'Outlook keeps crashing', 'Crashes when opening attachments', 12, 2, @ticket);
SELECT @ticket AS new_ticket;
SELECT * FROM incident_history WHERE incident_id = (SELECT incident_id FROM incident WHERE ticket_no = @ticket);
SELECT * FROM sla_tracking     WHERE incident_id = (SELECT incident_id FROM incident WHERE ticket_no = @ticket);
SELECT * FROM audit_log ORDER BY audit_id DESC LIMIT 5;
