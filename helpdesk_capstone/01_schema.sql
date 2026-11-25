-- =====================================================================
-- IT HELPDESK & INCIDENT MANAGEMENT DATABASE  (MySQL 8.0.31+)
-- File 01 : DDL  (22 tables, PK/FK/UNIQUE/CHECK)
-- Run order: 01 -> 02 -> 03 -> 04 -> 05 ...
-- =====================================================================
DROP DATABASE IF EXISTS helpdesk_db;
CREATE DATABASE helpdesk_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE helpdesk_db;

-- ---------- reference / master tables ----------
CREATE TABLE department (
  dept_id    INT AUTO_INCREMENT PRIMARY KEY,
  dept_name  VARCHAR(60) NOT NULL UNIQUE,
  location   VARCHAR(60)
);

CREATE TABLE user_role (
  role_id    TINYINT PRIMARY KEY,
  role_name  VARCHAR(30) NOT NULL UNIQUE
);

CREATE TABLE support_team (
  team_id     INT AUTO_INCREMENT PRIMARY KEY,
  team_name   VARCHAR(60) NOT NULL UNIQUE,
  description VARCHAR(150)
);

CREATE TABLE incident_status (
  status_id   TINYINT PRIMARY KEY,
  status_name VARCHAR(20) NOT NULL UNIQUE,
  is_final    BOOLEAN NOT NULL DEFAULT 0
);

CREATE TABLE priority (
  priority_id   TINYINT PRIMARY KEY,
  priority_name VARCHAR(15) NOT NULL UNIQUE,
  rank_level    TINYINT NOT NULL UNIQUE CHECK (rank_level BETWEEN 1 AND 10)
);

CREATE TABLE sla (
  sla_id             INT AUTO_INCREMENT PRIMARY KEY,
  sla_name           VARCHAR(40) NOT NULL UNIQUE,
  priority_id        TINYINT NOT NULL UNIQUE,
  response_minutes   INT NOT NULL CHECK (response_minutes > 0),
  resolution_minutes INT NOT NULL,
  CONSTRAINT chk_sla_times CHECK (resolution_minutes > response_minutes),
  CONSTRAINT fk_sla_priority FOREIGN KEY (priority_id) REFERENCES priority(priority_id)
);

-- ---------- people ----------
CREATE TABLE app_user (
  user_id    INT AUTO_INCREMENT PRIMARY KEY,
  full_name  VARCHAR(80) NOT NULL,
  email      VARCHAR(100) NOT NULL UNIQUE,
  phone      VARCHAR(15),
  dept_id    INT NOT NULL,
  role_id    TINYINT NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT 1,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_email CHECK (email LIKE '%@%.%'),
  CONSTRAINT fk_user_dept FOREIGN KEY (dept_id) REFERENCES department(dept_id),
  CONSTRAINT fk_user_role FOREIGN KEY (role_id) REFERENCES user_role(role_id)
);

CREATE TABLE technician (
  tech_id     INT AUTO_INCREMENT PRIMARY KEY,
  user_id     INT NOT NULL UNIQUE,
  team_id     INT NOT NULL,
  skill_level ENUM('L1','L2','L3') NOT NULL DEFAULT 'L1',
  is_active   BOOLEAN NOT NULL DEFAULT 1,
  CONSTRAINT fk_tech_user FOREIGN KEY (user_id) REFERENCES app_user(user_id),
  CONSTRAINT fk_tech_team FOREIGN KEY (team_id) REFERENCES support_team(team_id)
);

-- ---------- classification / configuration ----------
CREATE TABLE incident_category (
  category_id        INT AUTO_INCREMENT PRIMARY KEY,
  category_name      VARCHAR(50) NOT NULL UNIQUE,
  parent_category_id INT NULL,                       -- self-reference (hierarchy)
  default_team_id    INT NOT NULL,
  CONSTRAINT fk_cat_parent FOREIGN KEY (parent_category_id) REFERENCES incident_category(category_id),
  CONSTRAINT fk_cat_team   FOREIGN KEY (default_team_id)    REFERENCES support_team(team_id)
);

CREATE TABLE asset (
  asset_id         INT AUTO_INCREMENT PRIMARY KEY,
  asset_tag        VARCHAR(20) NOT NULL UNIQUE,
  asset_type       ENUM('Laptop','Desktop','Printer','Server','Router','Switch') NOT NULL,
  model            VARCHAR(60),
  assigned_user_id INT NULL,
  purchase_date    DATE,
  asset_status     ENUM('Active','Under Repair','Retired') NOT NULL DEFAULT 'Active',
  CONSTRAINT fk_asset_user FOREIGN KEY (assigned_user_id) REFERENCES app_user(user_id)
);

CREATE TABLE service (
  service_id    INT AUTO_INCREMENT PRIMARY KEY,
  service_name  VARCHAR(60) NOT NULL UNIQUE,
  owner_team_id INT NOT NULL,
  criticality   ENUM('Low','Medium','High') NOT NULL DEFAULT 'Medium',
  CONSTRAINT fk_service_team FOREIGN KEY (owner_team_id) REFERENCES support_team(team_id)
);

-- ---------- core incident tables ----------
CREATE TABLE incident (
  incident_id      INT AUTO_INCREMENT PRIMARY KEY,
  ticket_no        VARCHAR(30) NOT NULL UNIQUE,
  title            VARCHAR(150) NOT NULL,
  description      TEXT,
  reporter_id      INT NOT NULL,
  category_id      INT NOT NULL,
  priority_id      TINYINT NOT NULL,
  status_id        TINYINT NOT NULL DEFAULT 1,
  team_id          INT NOT NULL,
  assigned_tech_id INT NULL,
  created_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  assigned_at      DATETIME NULL,
  resolved_at      DATETIME NULL,
  closed_at        DATETIME NULL,
  row_version      INT NOT NULL DEFAULT 0,          -- optimistic locking
  CONSTRAINT chk_inc_resolved CHECK (resolved_at IS NULL OR resolved_at >= created_at),
  CONSTRAINT chk_inc_closed   CHECK (closed_at   IS NULL OR resolved_at IS NOT NULL),
  CONSTRAINT fk_inc_reporter FOREIGN KEY (reporter_id)      REFERENCES app_user(user_id),
  CONSTRAINT fk_inc_category FOREIGN KEY (category_id)      REFERENCES incident_category(category_id),
  CONSTRAINT fk_inc_priority FOREIGN KEY (priority_id)      REFERENCES priority(priority_id),
  CONSTRAINT fk_inc_status   FOREIGN KEY (status_id)        REFERENCES incident_status(status_id),
  CONSTRAINT fk_inc_team     FOREIGN KEY (team_id)          REFERENCES support_team(team_id),
  CONSTRAINT fk_inc_tech     FOREIGN KEY (assigned_tech_id) REFERENCES technician(tech_id)
);

CREATE TABLE incident_history (
  history_id    BIGINT AUTO_INCREMENT PRIMARY KEY,
  incident_id   INT NOT NULL,
  old_status_id TINYINT NULL,
  new_status_id TINYINT NOT NULL,
  old_tech_id   INT NULL,
  new_tech_id   INT NULL,
  changed_by    INT NULL,
  change_note   VARCHAR(200),
  changed_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_hist_inc  FOREIGN KEY (incident_id)   REFERENCES incident(incident_id),
  CONSTRAINT fk_hist_old  FOREIGN KEY (old_status_id) REFERENCES incident_status(status_id),
  CONSTRAINT fk_hist_new  FOREIGN KEY (new_status_id) REFERENCES incident_status(status_id),
  CONSTRAINT fk_hist_by   FOREIGN KEY (changed_by)    REFERENCES app_user(user_id)
);

CREATE TABLE sla_tracking (
  tracking_id         INT AUTO_INCREMENT PRIMARY KEY,
  incident_id         INT NOT NULL UNIQUE,            -- 1:1 with incident
  sla_id              INT NOT NULL,
  response_due        DATETIME NOT NULL,
  resolution_due      DATETIME NOT NULL,
  responded_at        DATETIME NULL,
  response_breached   BOOLEAN NOT NULL DEFAULT 0,
  resolution_breached BOOLEAN NOT NULL DEFAULT 0,
  CONSTRAINT chk_sla_due CHECK (resolution_due > response_due),
  CONSTRAINT fk_slat_inc FOREIGN KEY (incident_id) REFERENCES incident(incident_id),
  CONSTRAINT fk_slat_sla FOREIGN KEY (sla_id)      REFERENCES sla(sla_id)
);

-- ---------- M:N link tables ----------
CREATE TABLE incident_asset (
  incident_id INT NOT NULL,
  asset_id    INT NOT NULL,
  PRIMARY KEY (incident_id, asset_id),
  CONSTRAINT fk_ia_inc   FOREIGN KEY (incident_id) REFERENCES incident(incident_id) ON DELETE CASCADE,
  CONSTRAINT fk_ia_asset FOREIGN KEY (asset_id)    REFERENCES asset(asset_id)
);

CREATE TABLE incident_service (
  incident_id INT NOT NULL,
  service_id  INT NOT NULL,
  PRIMARY KEY (incident_id, service_id),
  CONSTRAINT fk_is_inc FOREIGN KEY (incident_id) REFERENCES incident(incident_id) ON DELETE CASCADE,
  CONSTRAINT fk_is_svc FOREIGN KEY (service_id)  REFERENCES service(service_id)
);

CREATE TABLE problem (
  problem_id     INT AUTO_INCREMENT PRIMARY KEY,
  problem_title  VARCHAR(150) NOT NULL,
  root_cause     VARCHAR(250),
  problem_status ENUM('Open','Under Investigation','Known Error','Resolved') NOT NULL DEFAULT 'Open',
  created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE incident_problem (
  incident_id INT NOT NULL,
  problem_id  INT NOT NULL,
  PRIMARY KEY (incident_id, problem_id),
  CONSTRAINT fk_ip_inc FOREIGN KEY (incident_id) REFERENCES incident(incident_id) ON DELETE CASCADE,
  CONSTRAINT fk_ip_prb FOREIGN KEY (problem_id)  REFERENCES problem(problem_id)
);

-- ---------- workflow outcome tables ----------
CREATE TABLE escalation (
  escalation_id       INT AUTO_INCREMENT PRIMARY KEY,
  incident_id         INT NOT NULL,
  escalated_from_team INT NOT NULL,
  escalated_to_team   INT NOT NULL,
  reason              VARCHAR(200) NOT NULL,
  escalation_level    TINYINT NOT NULL DEFAULT 1 CHECK (escalation_level BETWEEN 1 AND 3),
  escalated_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_esc_inc  FOREIGN KEY (incident_id)         REFERENCES incident(incident_id),
  CONSTRAINT fk_esc_from FOREIGN KEY (escalated_from_team) REFERENCES support_team(team_id),
  CONSTRAINT fk_esc_to   FOREIGN KEY (escalated_to_team)   REFERENCES support_team(team_id),
  CONSTRAINT uq_esc_level UNIQUE (incident_id, escalation_level)   -- no duplicate workflow records
);

CREATE TABLE resolution (
  resolution_id       INT AUTO_INCREMENT PRIMARY KEY,
  incident_id         INT NOT NULL UNIQUE,
  resolved_by_tech_id INT NOT NULL,
  resolution_text     TEXT NOT NULL,
  resolution_code     ENUM('Fixed','Workaround','Replaced Hardware','User Training','Config Change') NOT NULL,
  resolved_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_res_inc  FOREIGN KEY (incident_id)         REFERENCES incident(incident_id),
  CONSTRAINT fk_res_tech FOREIGN KEY (resolved_by_tech_id) REFERENCES technician(tech_id)
);

CREATE TABLE feedback (
  feedback_id  INT AUTO_INCREMENT PRIMARY KEY,
  incident_id  INT NOT NULL UNIQUE,
  rating       TINYINT NOT NULL,
  comments     VARCHAR(250),
  submitted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_rating CHECK (rating BETWEEN 1 AND 5),
  CONSTRAINT fk_fb_inc FOREIGN KEY (incident_id) REFERENCES incident(incident_id)
);

CREATE TABLE audit_log (
  audit_id   BIGINT AUTO_INCREMENT PRIMARY KEY,
  table_name VARCHAR(40) NOT NULL,
  record_id  INT NOT NULL,
  action     ENUM('INSERT','UPDATE','DELETE') NOT NULL,
  old_value  TEXT,
  new_value  TEXT,
  db_user    VARCHAR(80),
  event_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

SHOW TABLES;   -- expect 22 tables
