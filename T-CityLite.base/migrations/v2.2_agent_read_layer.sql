-- ============================================================================
-- Migration: v2.2_agent_read_layer.sql
-- Issues:    #22 [Agent P1] agent_events outbox + cursor
--            #23 [Agent P1] read-only views, agent_ro and PII
-- Target:    MariaDB 11.8 (TCityLite)
-- Run:       set -a; . ./.env; set +a
--            MYSQL_PWD="$TCITY_DB_PASS" mysql -h "$TCITY_DB_HOST" \
--              -u "$TCITY_DB_USER" "$TCITY_DB_NAME" \
--              < T-CityLite.base/migrations/v2.2_agent_read_layer.sql
--
-- Idempotency:
--   * agent_events uses CREATE TABLE IF NOT EXISTS
--   * every view uses CREATE OR REPLACE VIEW
--
-- Security:
--   * No credentials are stored in this file.
--   * agent_ro is created separately by tools/setup_agent_ro.sh and receives
--     SELECT on the four agent_* views only (never on base tables).
--   * Views run with SQL SECURITY DEFINER so agent_ro does not need privileges
--     on players / quest_event_log / bank_statements / world_*.
--
-- Schema notes (verified against the local TCityLite database):
--   * MariaDB has no native JSON type here: money/charinfo/job/gang/state_value
--     are TEXT/LONGTEXT. JSON values are read with
--     JSON_UNQUOTE(JSON_EXTRACT(col, '$.field')).
--   * players.money = {"cash":N,"bank":N,"crypto":N}; there is no per-player
--     crypto column. players.crypto is derived from money.$.crypto.
--   * player_vehicles has no creation/acquired timestamp, so vehicle creation
--     events cannot be placed on the timeline. It is intentionally omitted.
-- ============================================================================

SET NAMES utf8mb4;

-- ============================================================================
-- 1. agent_events — append-only event outbox / cursor feed (#22)
-- ============================================================================
-- Writers INSERT only. There is deliberately no UPDATE/DELETE API; rows are an
-- immutable audit/cursor stream. `id` is the monotonically increasing cursor
-- used by GET /agent/v1/events?since_id=...
-- ============================================================================
CREATE TABLE IF NOT EXISTS `agent_events` (
    `id`             BIGINT       NOT NULL AUTO_INCREMENT,
    `event_type`     VARCHAR(64)  NOT NULL COMMENT 'Dot-namespaced type, e.g. quest.completed, story.choice, economy.transfer, player.login',
    `citizenid`      VARCHAR(11)  NULL     COMMENT 'Player this event belongs to; NULL for world/system events',
    `payload`        LONGTEXT     NULL     COMMENT 'JSON object. Never store credentials, tokens or raw license/IP here.',
    `schema_version` SMALLINT     NOT NULL DEFAULT 1 COMMENT 'Payload contract version',
    `created_at`     DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`),
    KEY `idx_agent_events_type_id`    (`event_type`, `id`),
    KEY `idx_agent_events_citizen_id` (`citizenid`, `id`),
    KEY `idx_agent_events_created_at` (`created_at`),
    CONSTRAINT `chk_agent_events_payload_json`
        CHECK (`payload` IS NULL OR JSON_VALID(`payload`))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Append-only agent event outbox. INSERT only; id is the cursor.';

-- ============================================================================
-- 2. agent_player_snapshot — one flat row per player (#23)
-- ============================================================================
-- PII: license, identifier, position, inventory, metadata and phone are NOT
-- exposed. `name` / firstname / lastname are display names and are marked PII in
-- docs/agent/schema.json; consumers must not forward them to third parties.
-- ============================================================================
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=CURRENT_USER SQL SECURITY DEFINER
VIEW `agent_player_snapshot` AS
SELECT
    `p`.`citizenid` AS `citizenid`,
    `p`.`name` AS `name`,
    CAST(CASE WHEN JSON_VALID(`p`.`job`)
              THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`job`, '$.name'))
         END AS CHAR(64)) AS `job`,
    CAST(CASE WHEN JSON_VALID(`p`.`gang`)
              THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`gang`, '$.name'))
         END AS CHAR(64)) AS `gang`,
    COALESCE(CAST(CASE WHEN JSON_VALID(`p`.`money`)
                       THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`money`, '$.cash'))
                  END AS DECIMAL(18,2)), 0) AS `cash`,
    COALESCE(CAST(CASE WHEN JSON_VALID(`p`.`money`)
                       THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`money`, '$.bank'))
                  END AS DECIMAL(18,2)), 0) AS `bank`,
    COALESCE(CAST(CASE WHEN JSON_VALID(`p`.`money`)
                       THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`money`, '$.crypto'))
                  END AS DECIMAL(18,2)), 0) AS `crypto`,
    CAST(CASE WHEN JSON_VALID(`p`.`charinfo`)
              THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`charinfo`, '$.firstname'))
         END AS CHAR(64)) AS `firstname`,
    CAST(CASE WHEN JSON_VALID(`p`.`charinfo`)
              THEN JSON_UNQUOTE(JSON_EXTRACT(`p`.`charinfo`, '$.lastname'))
         END AS CHAR(64)) AS `lastname`,
    `p`.`last_updated` AS `last_updated`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM `players` AS `p`;

-- ============================================================================
-- 3. agent_player_timeline — normalized read-only activity stream (#23)
-- ============================================================================
-- UNION ALL over the tables that actually carry a timestamp:
--   quest_event_log.created_at  -> quest.<raw event_type>
--   player_choices.chosen_at    -> story.choice
--   bank_statements.date        -> economy.deposit / economy.withdraw
-- player_vehicles has no created_at, so it is not part of this view.
-- ============================================================================
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=CURRENT_USER SQL SECURITY DEFINER
VIEW `agent_player_timeline` AS
SELECT
    CAST(`q`.`citizenid` AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `citizenid`,
    CAST(CONCAT('quest.', `q`.`event_type`) AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `event_type`,
    CAST(`q`.`created_at` AS DATETIME(3)) AS `occurred_at`,
    CONVERT(JSON_OBJECT(
        'quest_id',   `q`.`quest_id`,
        'step_id',    `q`.`step_id`,
        'event_type', `q`.`event_type`,
        'metadata',   JSON_EXTRACT(
                          CASE
                              WHEN `q`.`metadata` IS NULL THEN NULL
                              WHEN JSON_VALID(`q`.`metadata`) THEN `q`.`metadata`
                              ELSE JSON_OBJECT('raw', `q`.`metadata`)
                          END, '$'
                      )
    ) USING utf8mb4) COLLATE utf8mb4_unicode_ci AS `payload`,
    CAST('quest_event_log' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `source_table`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM `quest_event_log` AS `q`

UNION ALL

SELECT
    CAST(`c`.`citizenid` AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `citizenid`,
    CAST('story.choice' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `event_type`,
    CAST(`c`.`chosen_at` AS DATETIME(3)) AS `occurred_at`,
    CONVERT(JSON_OBJECT(
        'decision_id',   `c`.`decision_id`,
        'chosen_option', `c`.`chosen_option`,
        'arc_id',        `c`.`arc_id`,
        'chapter',       `c`.`chapter`
    ) USING utf8mb4) COLLATE utf8mb4_unicode_ci AS `payload`,
    CAST('player_choices' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `source_table`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM `player_choices` AS `c`

UNION ALL

SELECT
    CAST(`b`.`citizenid` AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `citizenid`,
    CAST(CONCAT('economy.', COALESCE(`b`.`statement_type`, 'unknown')) AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `event_type`,
    CAST(`b`.`date` AS DATETIME(3)) AS `occurred_at`,
    CONVERT(JSON_OBJECT(
        'account_name',   `b`.`account_name`,
        'amount',         `b`.`amount`,
        'reason',         `b`.`reason`,
        'statement_type', `b`.`statement_type`
    ) USING utf8mb4) COLLATE utf8mb4_unicode_ci AS `payload`,
    CAST('bank_statements' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `source_table`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM `bank_statements` AS `b`;

-- ============================================================================
-- 4. agent_world_state — world_state rows + world_events summary (#23)
-- ============================================================================
-- Primary source: world_state (region_id, state_key, state_value, changed_at).
-- Secondary: one summary row per world_events.event_type.
-- Fallback: exactly one synthetic row while both source tables are empty, so
-- consumers get a well-formed, non-NULL response instead of an empty set.
-- `source_table` tells consumers which branch produced a row.
-- ============================================================================
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=CURRENT_USER SQL SECURITY DEFINER
VIEW `agent_world_state` AS
SELECT
    CAST(`ws`.`region_id` AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `region_id`,
    CAST(`ws`.`state_key` AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `state_key`,
    CONVERT(CASE WHEN JSON_VALID(`ws`.`state_value`)
                 THEN `ws`.`state_value`
                 ELSE JSON_OBJECT('raw', `ws`.`state_value`)
            END USING utf8mb4) COLLATE utf8mb4_unicode_ci AS `state_value`,
    CAST(`ws`.`changed_at` AS DATETIME(3)) AS `changed_at`,
    CAST('world_state' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `source_table`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM `world_state` AS `ws`

UNION ALL

SELECT
    CAST('world_events' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `region_id`,
    CAST(`we`.`event_type` AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `state_key`,
    CONVERT(JSON_OBJECT(
        'event_count',  COUNT(*),
        'latest_at',    MAX(`we`.`timestamp`),
        'max_severity', MAX(`we`.`severity`)
    ) USING utf8mb4) COLLATE utf8mb4_unicode_ci AS `state_value`,
    CAST(MAX(`we`.`timestamp`) AS DATETIME(3)) AS `changed_at`,
    CAST('world_events' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `source_table`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM `world_events` AS `we`
GROUP BY `we`.`event_type`

UNION ALL

SELECT
    CAST('system' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `region_id`,
    CAST('no_data' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `state_key`,
    CONVERT(JSON_OBJECT(
        'status', 'no_data',
        'message', 'world_state and world_events are both empty'
    ) USING utf8mb4) COLLATE utf8mb4_unicode_ci AS `state_value`,
    CAST(CURRENT_TIMESTAMP(3) AS DATETIME(3)) AS `changed_at`,
    CAST('fallback' AS CHAR(64)) COLLATE utf8mb4_unicode_ci AS `source_table`,
    CAST(1 AS UNSIGNED) AS `schema_version`
WHERE NOT EXISTS (SELECT 1 FROM `world_state`)
  AND NOT EXISTS (SELECT 1 FROM `world_events`);

-- ============================================================================
-- 5. agent_economy_metrics — per-job aggregates (#23)
-- ============================================================================
-- Amounts come from players.money JSON (cash/bank). Jobs with malformed or
-- missing job JSON are grouped as 'unemployed' rather than dropped.
-- ============================================================================
CREATE OR REPLACE ALGORITHM=UNDEFINED DEFINER=CURRENT_USER SQL SECURITY DEFINER
VIEW `agent_economy_metrics` AS
SELECT
    `p`.`job_name` AS `job`,
    COUNT(*) AS `player_count`,
    CAST(COALESCE(SUM(`p`.`cash`), 0) AS DECIMAL(18,2)) AS `total_cash`,
    CAST(COALESCE(SUM(`p`.`bank`), 0) AS DECIMAL(18,2)) AS `total_bank`,
    CAST(COALESCE(AVG(`p`.`bank`), 0) AS DECIMAL(18,2)) AS `avg_bank`,
    CAST(COALESCE(MAX(`p`.`bank`), 0) AS DECIMAL(18,2)) AS `max_bank`,
    CAST(1 AS UNSIGNED) AS `schema_version`
FROM (
    SELECT
        COALESCE(
            NULLIF(
                CAST(CASE WHEN JSON_VALID(`job`)
                          THEN JSON_UNQUOTE(JSON_EXTRACT(`job`, '$.name'))
                     END AS CHAR(64)),
                ''
            ),
            'unemployed'
        ) AS `job_name`,
        COALESCE(CAST(CASE WHEN JSON_VALID(`money`)
                           THEN JSON_UNQUOTE(JSON_EXTRACT(`money`, '$.cash'))
                      END AS DECIMAL(18,2)), 0) AS `cash`,
        COALESCE(CAST(CASE WHEN JSON_VALID(`money`)
                           THEN JSON_UNQUOTE(JSON_EXTRACT(`money`, '$.bank'))
                      END AS DECIMAL(18,2)), 0) AS `bank`
    FROM `players`
) AS `p`
GROUP BY `p`.`job_name`;

-- ============================================================================
-- Verification (run manually after applying):
--   SHOW TABLES LIKE 'agent_%';
--   SELECT COUNT(*) FROM agent_events;
--   SELECT * FROM agent_player_snapshot LIMIT 5;
--   SELECT * FROM agent_player_timeline LIMIT 5;
--   SELECT * FROM agent_world_state LIMIT 5;
--   SELECT * FROM agent_economy_metrics LIMIT 5;
--   SHOW GRANTS FOR 'agent_ro'@'localhost';
-- ============================================================================
