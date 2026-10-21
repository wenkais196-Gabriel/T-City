-- ============================================================================
-- Migration: v2.2.1_agent_event_triggers.sql
-- Issues:    #22 [Agent P1] agent_events outbox + cursor
-- Depends:   v2.2_agent_read_layer.sql (agent_events + views)
-- Target:    MariaDB 11.8 (TCityLite)
--
-- Why triggers:
--   The event sources already write quest_event_log / player_choices /
--   bank_statements / player_vehicles. Triggering on those inserts gives the
--   agent a complete cursor feed without touching every Lua service, and keeps
--   working for any future writer.
--
-- Contract:
--   * agent_events is append-only; triggers INSERT only.
--   * event_type is dot-namespaced and stable.
--   * payload never contains license/IP.
--   * citizenid is truncated to 11 chars to match agent_events.
-- ============================================================================

SET NAMES utf8mb4;

-- ----------------------------------------------------------------------------
-- quest events -> quest.started / quest.step / quest.completed / quest.failed
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_agent_quest_event`;
DELIMITER $$
CREATE TRIGGER `trg_agent_quest_event`
AFTER INSERT ON `quest_event_log`
FOR EACH ROW
BEGIN
    DECLARE v_event_type VARCHAR(64);

    SET v_event_type = CASE LOWER(COALESCE(NEW.`event_type`, ''))
        WHEN 'start'      THEN 'quest.started'
        WHEN 'started'    THEN 'quest.started'
        WHEN 'step'       THEN 'quest.step'
        WHEN 'complete'   THEN 'quest.completed'
        WHEN 'completed'  THEN 'quest.completed'
        WHEN 'fail'       THEN 'quest.failed'
        WHEN 'failed'     THEN 'quest.failed'
        WHEN 'abandon'    THEN 'quest.abandoned'
        ELSE CONCAT('quest.', LOWER(COALESCE(NEW.`event_type`, 'unknown')))
    END;

    -- Keep JSON_EXTRACT inline: a LONGTEXT local variable loses the JSON type
    -- and makes payload.metadata a double-encoded string on MariaDB.
    INSERT INTO `agent_events` (`event_type`, `citizenid`, `payload`, `schema_version`)
    VALUES (
        v_event_type,
        LEFT(NEW.`citizenid`, 11),
        JSON_OBJECT(
            'quest_id',   NEW.`quest_id`,
            'step_id',    NEW.`step_id`,
            'event_type', NEW.`event_type`,
            'metadata',   CASE
                WHEN NEW.`metadata` IS NULL THEN NULL
                WHEN JSON_VALID(NEW.`metadata`) THEN JSON_EXTRACT(NEW.`metadata`, '$')
                ELSE JSON_OBJECT('raw', NEW.`metadata`)
            END
        ),
        1
    );
END$$
DELIMITER ;

-- ----------------------------------------------------------------------------
-- story choices -> story.choice
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_agent_story_choice`;
DELIMITER $$
CREATE TRIGGER `trg_agent_story_choice`
AFTER INSERT ON `player_choices`
FOR EACH ROW
BEGIN
    INSERT INTO `agent_events` (`event_type`, `citizenid`, `payload`, `schema_version`)
    VALUES (
        'story.choice',
        LEFT(NEW.`citizenid`, 11),
        JSON_OBJECT(
            'decision_id',  NEW.`decision_id`,
            'chosen_option', NEW.`chosen_option`,
            'arc_id',       NEW.`arc_id`,
            'chapter',      NEW.`chapter`
        ),
        1
    );
END$$
DELIMITER ;

-- ----------------------------------------------------------------------------
-- bank statements -> economy.deposit / economy.withdraw / economy.transaction
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_agent_bank_statement`;
DELIMITER $$
CREATE TRIGGER `trg_agent_bank_statement`
AFTER INSERT ON `bank_statements`
FOR EACH ROW
BEGIN
    INSERT INTO `agent_events` (`event_type`, `citizenid`, `payload`, `schema_version`)
    VALUES (
        CASE LOWER(COALESCE(NEW.`statement_type`, ''))
            WHEN 'deposit'  THEN 'economy.deposit'
            WHEN 'withdraw' THEN 'economy.withdraw'
            ELSE 'economy.transaction'
        END,
        LEFT(NEW.`citizenid`, 11),
        JSON_OBJECT(
            'account_name',  NEW.`account_name`,
            'amount',        NEW.`amount`,
            'reason',        NEW.`reason`,
            'statement_type', NEW.`statement_type`
        ),
        1
    );
END$$
DELIMITER ;

-- ----------------------------------------------------------------------------
-- vehicle acquisition -> vehicle.acquired
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS `trg_agent_vehicle_acquired`;
DELIMITER $$
CREATE TRIGGER `trg_agent_vehicle_acquired`
AFTER INSERT ON `player_vehicles`
FOR EACH ROW
BEGIN
    INSERT INTO `agent_events` (`event_type`, `citizenid`, `payload`, `schema_version`)
    VALUES (
        'vehicle.acquired',
        LEFT(NEW.`citizenid`, 11),
        JSON_OBJECT(
            'plate',   NEW.`plate`,
            'vehicle', NEW.`vehicle`,
            'garage',  NEW.`garage`
        ),
        1
    );
END$$
DELIMITER ;
