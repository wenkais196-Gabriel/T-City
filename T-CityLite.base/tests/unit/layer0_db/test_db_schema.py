"""
test_db_schema.py — DB schema validation tests for T-City Lite.

Validates migrations:
  - v2.0_trinity_schema: qualifications, tax, insurance, economy_snapshots, npc_prices
  - v0.8_ownership_engine: world_state, world_events, trust_graph, patron_records,
    governance_proposals, skill_ranks, cosmetic_items, player_cosmetics, organization_rules
  - v0.7_story_engine: player_choices, story_completions
  - v2.1_perf_indexes: phone_number virtual column, performance indexes

Uses db_conn and db_cursor fixtures from conftest.py (transactional rollback after each test).
"""
import pytest


# ═══════════════════════════════════════════════════════════════════════════
# Helper utilities
# ═══════════════════════════════════════════════════════════════════════════

def _table_exists(cursor, table_name: str) -> bool:
    cursor.execute(
        "SELECT COUNT(*) AS cnt FROM information_schema.TABLES "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s",
        (table_name,),
    )
    return cursor.fetchone()["cnt"] > 0


def _column_exists(cursor, table_name: str, col_name: str) -> bool:
    cursor.execute(
        "SELECT COUNT(*) AS cnt FROM information_schema.COLUMNS "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND COLUMN_NAME = %s",
        (table_name, col_name),
    )
    return cursor.fetchone()["cnt"] > 0


def _get_column_info(cursor, table_name: str, col_name: str) -> dict | None:
    cursor.execute(
        "SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, "
        "EXTRA, GENERATION_EXPRESSION "
        "FROM information_schema.COLUMNS "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND COLUMN_NAME = %s",
        (table_name, col_name),
    )
    return cursor.fetchone()


def _index_exists(cursor, table_name: str, index_name: str) -> bool:
    cursor.execute(
        "SELECT COUNT(*) AS cnt FROM information_schema.STATISTICS "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND INDEX_NAME = %s",
        (table_name, index_name),
    )
    return cursor.fetchone()["cnt"] > 0


def _is_unique_index(cursor, table_name: str, index_name: str) -> bool:
    cursor.execute(
        "SELECT NON_UNIQUE FROM information_schema.STATISTICS "
        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND INDEX_NAME = %s "
        "LIMIT 1",
        (table_name, index_name),
    )
    row = cursor.fetchone()
    return row is not None and row["NON_UNIQUE"] == 0


def _get_enum_values(cursor, table_name: str, col_name: str) -> list[str] | None:
    """Extract enum values from COLUMN_TYPE like enum('a','b','c')."""
    info = _get_column_info(cursor, table_name, col_name)
    if info is None:
        return None
    col_type = info["COLUMN_TYPE"]
    if not col_type.startswith("enum("):
        return None
    # Parse: enum('minor','notable','major','legendary')
    inner = col_type[5:-1]  # strip 'enum(' and trailing ')'
    values = [v.strip("'") for v in inner.split(",")]
    return values


# ═══════════════════════════════════════════════════════════════════════════
# v2.0 Trinity Schema — players qualifications column
# ═══════════════════════════════════════════════════════════════════════════

class TestTrinityPlayersQualifications:
    """Validate qualifications columns and indexes on players table (v2.0)."""

    def test_players_table_exists(self, db_cursor):
        assert _table_exists(db_cursor, "players"), "players table must exist"

    def test_qualifications_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "players", "qualifications"), (
            "qualifications column must exist on players"
        )

    def test_qualifications_is_json_type(self, db_cursor):
        info = _get_column_info(db_cursor, "players", "qualifications")
        assert info is not None
        assert info["DATA_TYPE"] == "json", (
            f"qualifications should be json type, got {info['DATA_TYPE']}"
        )

    def test_qualifications_idx_virtual_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "players", "qualifications_idx"), (
            "qualifications_idx virtual generated column must exist"
        )

    def test_qualifications_idx_is_generated(self, db_cursor):
        info = _get_column_info(db_cursor, "players", "qualifications_idx")
        assert info is not None
        assert info["EXTRA"] == "VIRTUAL GENERATED", (
            f"qualifications_idx should be VIRTUAL GENERATED, got EXTRA={info['EXTRA']}"
        )
        assert info["GENERATION_EXPRESSION"] is not None, (
            "qualifications_idx must have a GENERATION_EXPRESSION"
        )
        assert "json_extract" in (info["GENERATION_EXPRESSION"] or "").lower(), (
            "qualifications_idx GENERATION_EXPRESSION must reference JSON_EXTRACT"
        )

    def test_idx_qualifications_exists(self, db_cursor):
        assert _index_exists(db_cursor, "players", "idx_qualifications"), (
            "idx_qualifications index must exist on players"
        )


# ═══════════════════════════════════════════════════════════════════════════
# v2.0 Trinity Schema — player_houses tax columns
# ═══════════════════════════════════════════════════════════════════════════

class TestTrinityPlayerHousesTax:
    """Validate tax columns and indexes on player_houses table (v2.0)."""

    def test_player_houses_table_exists(self, db_cursor):
        assert _table_exists(db_cursor, "player_houses"), "player_houses table must exist"

    def test_last_tax_paid_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "player_houses", "last_tax_paid"), (
            "last_tax_paid column must exist on player_houses"
        )

    def test_last_tax_paid_is_int_unsigned(self, db_cursor):
        info = _get_column_info(db_cursor, "player_houses", "last_tax_paid")
        assert info is not None
        col_type = info["COLUMN_TYPE"]
        assert "int" in col_type.lower() and "unsigned" in col_type.lower(), (
            f"last_tax_paid should be INT UNSIGNED, got {col_type}"
        )

    def test_delinquent_count_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "player_houses", "delinquent_count"), (
            "delinquent_count column must exist on player_houses"
        )

    def test_delinquent_count_is_tinyint_unsigned(self, db_cursor):
        info = _get_column_info(db_cursor, "player_houses", "delinquent_count")
        assert info is not None
        col_type = info["COLUMN_TYPE"]
        assert "tinyint" in col_type.lower() and "unsigned" in col_type.lower(), (
            f"delinquent_count should be TINYINT UNSIGNED, got {col_type}"
        )

    def test_delinquent_count_default_zero(self, db_cursor):
        info = _get_column_info(db_cursor, "player_houses", "delinquent_count")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "0", (
            f"delinquent_count default should be 0, got {info['COLUMN_DEFAULT']}"
        )

    def test_idx_tax_exists(self, db_cursor):
        assert _index_exists(db_cursor, "player_houses", "idx_tax"), (
            "idx_tax index must exist on player_houses"
        )


# ═══════════════════════════════════════════════════════════════════════════
# v2.0 Trinity Schema — player_vehicles insurance/mileage columns
# ═══════════════════════════════════════════════════════════════════════════

class TestTrinityPlayerVehiclesLifecycle:
    """Validate insurance/mileage columns on player_vehicles table (v2.0)."""

    def test_player_vehicles_table_exists(self, db_cursor):
        assert _table_exists(db_cursor, "player_vehicles"), "player_vehicles table must exist"

    def test_last_insurance_paid_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "player_vehicles", "last_insurance_paid"), (
            "last_insurance_paid column must exist on player_vehicles"
        )

    def test_last_insurance_paid_is_int_unsigned(self, db_cursor):
        info = _get_column_info(db_cursor, "player_vehicles", "last_insurance_paid")
        assert info is not None
        col_type = info["COLUMN_TYPE"]
        assert "int" in col_type.lower() and "unsigned" in col_type.lower(), (
            f"last_insurance_paid should be INT UNSIGNED, got {col_type}"
        )

    def test_current_mileage_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "player_vehicles", "current_mileage"), (
            "current_mileage column must exist on player_vehicles"
        )

    def test_current_mileage_is_int_unsigned(self, db_cursor):
        info = _get_column_info(db_cursor, "player_vehicles", "current_mileage")
        assert info is not None
        col_type = info["COLUMN_TYPE"]
        assert "int" in col_type.lower() and "unsigned" in col_type.lower(), (
            f"current_mileage should be INT UNSIGNED, got {col_type}"
        )

    def test_current_mileage_default_zero(self, db_cursor):
        info = _get_column_info(db_cursor, "player_vehicles", "current_mileage")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "0", (
            f"current_mileage default should be 0, got {info['COLUMN_DEFAULT']}"
        )

    def test_idx_insurance_exists(self, db_cursor):
        assert _index_exists(db_cursor, "player_vehicles", "idx_insurance"), (
            "idx_insurance index must exist on player_vehicles"
        )


# ═══════════════════════════════════════════════════════════════════════════
# v2.0 Trinity Schema — economy_snapshots table
# ═══════════════════════════════════════════════════════════════════════════

class TestTrinityEconomySnapshots:
    """Validate economy_snapshots table schema (v2.0)."""

    def test_table_exists(self, db_cursor):
        assert _table_exists(db_cursor, "economy_snapshots"), (
            "economy_snapshots table must exist"
        )

    EXPECTED_COLUMNS = {
        "id":            "int",
        "week_start":    "date",
        "total_inflow":  "bigint",
        "total_outflow": "bigint",
        "total_sink":    "bigint",
        "vehicle_count": "int",
        "house_count":   "int",
        "global_multiplier": "decimal",
        "hot_activities":    "json",
        "generated_at":      "timestamp",
    }

    @pytest.mark.parametrize("col_name,expected_type", EXPECTED_COLUMNS.items())
    def test_column_exists_and_type(self, db_cursor, col_name, expected_type):
        assert _column_exists(db_cursor, "economy_snapshots", col_name), (
            f"Column '{col_name}' must exist on economy_snapshots"
        )
        info = _get_column_info(db_cursor, "economy_snapshots", col_name)
        assert info is not None
        assert info["DATA_TYPE"] == expected_type, (
            f"economy_snapshots.{col_name}: expected DATA_TYPE={expected_type}, "
            f"got {info['DATA_TYPE']}"
        )

    def test_id_is_auto_increment(self, db_cursor):
        info = _get_column_info(db_cursor, "economy_snapshots", "id")
        assert info is not None
        assert "auto_increment" in info["EXTRA"].lower(), (
            "economy_snapshots.id must be AUTO_INCREMENT"
        )

    def test_week_start_index_exists(self, db_cursor):
        assert _index_exists(db_cursor, "economy_snapshots", "idx_week"), (
            "idx_week index must exist on economy_snapshots"
        )


# ═══════════════════════════════════════════════════════════════════════════
# v2.0 Trinity Schema — npc_prices table
# ═══════════════════════════════════════════════════════════════════════════

class TestTrinityNpcPrices:
    """Validate npc_prices table schema (v2.0)."""

    def test_table_exists(self, db_cursor):
        assert _table_exists(db_cursor, "npc_prices"), (
            "npc_prices table must exist"
        )

    def test_item_name_is_primary_key(self, db_cursor):
        info = _get_column_info(db_cursor, "npc_prices", "item_name")
        assert info is not None
        assert info["COLUMN_NAME"] == "item_name"
        # PRIMARY should appear in EXTRA or the column should be the PK
        assert "PRI" in info.get("COLUMN_KEY", "") or "pri" in info["EXTRA"].lower(), (
            f"npc_prices.item_name must be PRIMARY KEY, got EXTRA={info['EXTRA']}"
        )

    def test_item_name_is_varchar_64(self, db_cursor):
        info = _get_column_info(db_cursor, "npc_prices", "item_name")
        assert info is not None
        assert "64" in info["COLUMN_TYPE"], (
            f"npc_prices.item_name should be VARCHAR(64), got {info['COLUMN_TYPE']}"
        )

    EXPECTED_COLUMNS = {
        "demand":       "int",
        "supply":       "int",
        "base_price":   "int",
        "last_updated": "timestamp",
    }

    @pytest.mark.parametrize("col_name,expected_type", EXPECTED_COLUMNS.items())
    def test_column_exists_and_type(self, db_cursor, col_name, expected_type):
        assert _column_exists(db_cursor, "npc_prices", col_name), (
            f"Column '{col_name}' must exist on npc_prices"
        )
        info = _get_column_info(db_cursor, "npc_prices", col_name)
        assert info is not None
        assert info["DATA_TYPE"] == expected_type, (
            f"npc_prices.{col_name}: expected DATA_TYPE={expected_type}, "
            f"got {info['DATA_TYPE']}"
        )

    def test_supply_default_one(self, db_cursor):
        info = _get_column_info(db_cursor, "npc_prices", "supply")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "1", (
            f"npc_prices.supply default should be 1, got {info['COLUMN_DEFAULT']}"
        )


# ═══════════════════════════════════════════════════════════════════════════
# v0.8 Ownership Engine — all 9 tables
# ═══════════════════════════════════════════════════════════════════════════

class TestOwnershipEngineTablesExist:
    """Verify all v0.8 ownership engine tables exist."""

    OWNERSHIP_TABLES = [
        "world_state",
        "world_events",
        "trust_graph",
        "patron_records",
        "governance_proposals",
        "skill_ranks",
        "cosmetic_items",
        "player_cosmetics",
        "organization_rules",
    ]

    @pytest.mark.parametrize("table_name", OWNERSHIP_TABLES)
    def test_table_exists(self, db_cursor, table_name):
        assert _table_exists(db_cursor, table_name), (
            f"Table '{table_name}' must exist (v0.8 ownership engine)"
        )


# ── world_state ────────────────────────────────────────────────────────────

class TestWorldStateSchema:
    """Validate world_state table columns and constraints."""

    def test_region_id_column(self, db_cursor):
        info = _get_column_info(db_cursor, "world_state", "region_id")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar"
        assert "64" in info["COLUMN_TYPE"]

    def test_state_key_column(self, db_cursor):
        info = _get_column_info(db_cursor, "world_state", "state_key")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar"
        assert "64" in info["COLUMN_TYPE"]

    def test_state_value_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "world_state", "state_value")
        assert info is not None
        assert info["DATA_TYPE"] == "json"

    def test_previous_value_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "world_state", "previous_value")
        assert info is not None
        assert info["DATA_TYPE"] == "json"

    def test_unique_region_key_constraint(self, db_cursor):
        assert _index_exists(db_cursor, "world_state", "idx_region_key"), (
            "idx_region_key unique constraint must exist"
        )
        assert _is_unique_index(db_cursor, "world_state", "idx_region_key"), (
            "idx_region_key must be a UNIQUE constraint on (region_id, state_key)"
        )


# ── world_events ───────────────────────────────────────────────────────────

class TestWorldEventsSchema:
    """Validate world_events table, especially the severity ENUM."""

    def test_severity_enum_values(self, db_cursor):
        vals = _get_enum_values(db_cursor, "world_events", "severity")
        expected = ["minor", "notable", "major", "legendary"]
        assert vals == expected, (
            f"world_events.severity ENUM should be {expected}, got {vals}"
        )

    def test_severity_default_minor(self, db_cursor):
        info = _get_column_info(db_cursor, "world_events", "severity")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "minor", (
            f"severity default should be 'minor', got {info['COLUMN_DEFAULT']}"
        )

    def test_event_type_column(self, db_cursor):
        info = _get_column_info(db_cursor, "world_events", "event_type")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar"
        assert "32" in info["COLUMN_TYPE"]

    def test_participants_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "world_events", "participants")
        assert info is not None
        assert info["DATA_TYPE"] == "json"

    def test_outcome_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "world_events", "outcome")
        assert info is not None
        assert info["DATA_TYPE"] == "json"

    def test_idx_type_time_exists(self, db_cursor):
        assert _index_exists(db_cursor, "world_events", "idx_type_time"), (
            "idx_type_time index must exist"
        )

    def test_idx_severity_exists(self, db_cursor):
        assert _index_exists(db_cursor, "world_events", "idx_severity"), (
            "idx_severity index must exist"
        )


# ── trust_graph ────────────────────────────────────────────────────────────

class TestTrustGraphSchema:
    """Validate trust_graph table and unique edge constraint."""

    def test_unique_edge_constraint(self, db_cursor):
        assert _index_exists(db_cursor, "trust_graph", "idx_trust_edge"), (
            "idx_trust_edge unique constraint must exist"
        )
        assert _is_unique_index(db_cursor, "trust_graph", "idx_trust_edge"), (
            "idx_trust_edge must be UNIQUE on (from_citizen, to_citizen, category)"
        )

    def test_weight_is_float(self, db_cursor):
        info = _get_column_info(db_cursor, "trust_graph", "weight")
        assert info is not None
        assert info["DATA_TYPE"] == "float"

    def test_category_column(self, db_cursor):
        info = _get_column_info(db_cursor, "trust_graph", "category")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar"
        assert "32" in info["COLUMN_TYPE"]


# ── patron_records ─────────────────────────────────────────────────────────

class TestPatronRecordsSchema:
    """Validate patron_records table and unique citizenid."""

    def test_citizenid_is_unique(self, db_cursor):
        assert _column_exists(db_cursor, "patron_records", "citizenid")
        # The schema declares citizenid as NOT NULL UNIQUE
        # Verify by checking COLUMN_KEY
        info = _get_column_info(db_cursor, "patron_records", "citizenid")
        assert info is not None
        assert info["COLUMN_KEY"] in ("UNI", "PRI", "MUL"), (
            f"patron_records.citizenid should be unique (COLUMN_KEY should be UNI), "
            f"got {info['COLUMN_KEY']}"
        )

    def test_tier_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "patron_records", "tier")

    def test_expires_at_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "patron_records", "expires_at")


# ── governance_proposals ───────────────────────────────────────────────────

class TestGovernanceProposalsSchema:
    """Validate governance_proposals table, especially ENUM columns."""

    def test_status_enum_values(self, db_cursor):
        vals = _get_enum_values(db_cursor, "governance_proposals", "status")
        expected = ["draft", "cosigning", "voting", "passed",
                    "rejected", "executed", "vetoed"]
        assert vals == expected, (
            f"governance_proposals.status ENUM should be {expected}, got {vals}"
        )

    def test_status_default_draft(self, db_cursor):
        info = _get_column_info(db_cursor, "governance_proposals", "status")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "draft", (
            f"status default should be 'draft', got {info['COLUMN_DEFAULT']}"
        )

    def test_scope_enum_values(self, db_cursor):
        vals = _get_enum_values(db_cursor, "governance_proposals", "scope")
        expected = ["organization", "server"]
        assert vals == expected, (
            f"governance_proposals.scope ENUM should be {expected}, got {vals}"
        )

    def test_cosigners_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "governance_proposals", "cosigners")
        assert info is not None
        assert info["DATA_TYPE"] == "json"

    def test_vote_details_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "governance_proposals", "vote_details")
        assert info is not None
        assert info["DATA_TYPE"] == "json"

    def test_execution_args_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "governance_proposals", "execution_args")
        assert info is not None
        assert info["DATA_TYPE"] == "json"


# ── skill_ranks ────────────────────────────────────────────────────────────

class TestSkillRanksSchema:
    """Validate skill_ranks table, especially rank ENUM."""

    def test_rank_enum_values(self, db_cursor):
        vals = _get_enum_values(db_cursor, "skill_ranks", "rank")
        expected = ["apprentice", "journeyman", "expert", "master"]
        assert vals == expected, (
            f"skill_ranks.rank ENUM should be {expected}, got {vals}"
        )

    def test_skill_name_column(self, db_cursor):
        info = _get_column_info(db_cursor, "skill_ranks", "skill_name")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar"
        assert "32" in info["COLUMN_TYPE"]

    def test_is_active_default_true(self, db_cursor):
        info = _get_column_info(db_cursor, "skill_ranks", "is_active")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "1", (
            f"is_active default should be 1 (TRUE), got {info['COLUMN_DEFAULT']}"
        )


# ── cosmetic_items ─────────────────────────────────────────────────────────

class TestCosmeticItemsSchema:
    """Validate cosmetic_items table and unique item_id."""

    def test_item_id_is_unique(self, db_cursor):
        info = _get_column_info(db_cursor, "cosmetic_items", "item_id")
        assert info is not None
        assert info["COLUMN_KEY"] == "UNI", (
            f"cosmetic_items.item_id must be UNIQUE, got COLUMN_KEY={info['COLUMN_KEY']}"
        )

    def test_item_type_column(self, db_cursor):
        info = _get_column_info(db_cursor, "cosmetic_items", "item_type")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar"
        assert "32" in info["COLUMN_TYPE"]

    def test_price_cny_is_int(self, db_cursor):
        info = _get_column_info(db_cursor, "cosmetic_items", "price_cny")
        assert info is not None
        assert info["DATA_TYPE"] == "int"


# ── player_cosmetics ───────────────────────────────────────────────────────

class TestPlayerCosmeticsSchema:
    """Validate player_cosmetics table and unique player-item constraint."""

    def test_unique_player_item_constraint(self, db_cursor):
        assert _index_exists(db_cursor, "player_cosmetics", "idx_player_item"), (
            "idx_player_item unique constraint must exist"
        )
        assert _is_unique_index(db_cursor, "player_cosmetics", "idx_player_item"), (
            "idx_player_item must be UNIQUE on (citizenid, item_id)"
        )

    def test_equipped_column_is_boolean(self, db_cursor):
        info = _get_column_info(db_cursor, "player_cosmetics", "equipped")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "0", (
            f"equipped default should be 0 (FALSE), got {info['COLUMN_DEFAULT']}"
        )

    def test_frozen_column_is_boolean(self, db_cursor):
        info = _get_column_info(db_cursor, "player_cosmetics", "frozen")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "0", (
            f"frozen default should be 0 (FALSE), got {info['COLUMN_DEFAULT']}"
        )


# ── organization_rules ─────────────────────────────────────────────────────

class TestOrganizationRulesSchema:
    """Validate organization_rules table and unique org-rule constraint."""

    def test_unique_org_rule_constraint(self, db_cursor):
        assert _index_exists(db_cursor, "organization_rules", "idx_org_rule"), (
            "idx_org_rule unique constraint must exist"
        )
        assert _is_unique_index(db_cursor, "organization_rules", "idx_org_rule"), (
            "idx_org_rule must be UNIQUE on (org_id, rule_key)"
        )

    def test_rule_value_is_json(self, db_cursor):
        info = _get_column_info(db_cursor, "organization_rules", "rule_value")
        assert info is not None
        assert info["DATA_TYPE"] == "json"


# ═══════════════════════════════════════════════════════════════════════════
# v0.7 Story Engine — player_choices and story_completions
# ═══════════════════════════════════════════════════════════════════════════

class TestStoryEngineTablesExist:
    """Verify v0.7 story engine tables exist."""

    STORY_TABLES = ["player_choices", "story_completions"]

    @pytest.mark.parametrize("table_name", STORY_TABLES)
    def test_table_exists(self, db_cursor, table_name):
        assert _table_exists(db_cursor, table_name), (
            f"Table '{table_name}' must exist (v0.7 story engine)"
        )


class TestPlayerChoicesSchema:
    """Validate player_choices table columns."""

    EXPECTED_COLUMNS = {
        "id":            "int",
        "citizenid":     "varchar",
        "decision_id":   "varchar",
        "chosen_option": "varchar",
        "arc_id":        "varchar",
        "chapter":       "int",
        "chosen_at":     "datetime",
    }

    @pytest.mark.parametrize("col_name,expected_type", EXPECTED_COLUMNS.items())
    def test_column_exists_and_type(self, db_cursor, col_name, expected_type):
        assert _column_exists(db_cursor, "player_choices", col_name), (
            f"Column '{col_name}' must exist on player_choices"
        )
        info = _get_column_info(db_cursor, "player_choices", col_name)
        assert info is not None
        assert info["DATA_TYPE"] == expected_type, (
            f"player_choices.{col_name}: expected DATA_TYPE={expected_type}, "
            f"got {info['DATA_TYPE']}"
        )

    def test_chapter_default_one(self, db_cursor):
        info = _get_column_info(db_cursor, "player_choices", "chapter")
        assert info is not None
        assert info["COLUMN_DEFAULT"] == "1", (
            f"chapter default should be 1, got {info['COLUMN_DEFAULT']}"
        )

    def test_idx_citizenid_exists(self, db_cursor):
        assert _index_exists(db_cursor, "player_choices", "idx_citizenid"), (
            "idx_citizenid index must exist on player_choices"
        )

    def test_idx_arc_chapter_exists(self, db_cursor):
        assert _index_exists(db_cursor, "player_choices", "idx_arc_chapter"), (
            "idx_arc_chapter index must exist on player_choices"
        )

    def test_idx_decision_exists(self, db_cursor):
        assert _index_exists(db_cursor, "player_choices", "idx_decision"), (
            "idx_decision index must exist on player_choices"
        )


class TestStoryCompletionsSchema:
    """Validate story_completions composite primary key."""

    def test_composite_primary_key(self, db_cursor):
        """Verify (citizenid, arc_id) is the primary key."""
        cursor = db_cursor
        cursor.execute(
            "SELECT COLUMN_NAME, COLUMN_KEY FROM information_schema.COLUMNS "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'story_completions' "
            "AND COLUMN_KEY = 'PRI'"
        )
        pk_columns = {row["COLUMN_NAME"] for row in cursor.fetchall()}
        assert pk_columns == {"citizenid", "arc_id"}, (
            f"story_completions primary key should be (citizenid, arc_id), "
            f"got {pk_columns}"
        )

    def test_completed_at_column(self, db_cursor):
        info = _get_column_info(db_cursor, "story_completions", "completed_at")
        assert info is not None
        assert info["DATA_TYPE"] == "datetime"


# ═══════════════════════════════════════════════════════════════════════════
# v2.1 Performance Indexes — phone_number virtual column + indexes
# ═══════════════════════════════════════════════════════════════════════════

class TestPerfIndexesPhoneNumber:
    """Validate v2.1 phone_number virtual column and its index."""

    def test_phone_number_virtual_column_exists(self, db_cursor):
        assert _column_exists(db_cursor, "players", "phone_number"), (
            "phone_number virtual generated column must exist (v2.1)"
        )

    def test_phone_number_is_generated(self, db_cursor):
        info = _get_column_info(db_cursor, "players", "phone_number")
        assert info is not None
        assert "VIRTUAL GENERATED" in info["EXTRA"], (
            f"phone_number should be VIRTUAL GENERATED, got EXTRA={info['EXTRA']}"
        )
        expr = (info["GENERATION_EXPRESSION"] or "").lower()
        assert "json_extract" in expr or "json_unquote" in expr, (
            "phone_number GENERATION_EXPRESSION must use JSON_EXTRACT/JSON_UNQUOTE"
        )

    def test_phone_number_is_varchar(self, db_cursor):
        info = _get_column_info(db_cursor, "players", "phone_number")
        assert info is not None
        assert info["DATA_TYPE"] == "varchar", (
            f"phone_number should be varchar, got {info['DATA_TYPE']}"
        )

    def test_idx_players_phone_exists(self, db_cursor):
        assert _index_exists(db_cursor, "players", "idx_players_phone"), (
            "idx_players_phone index must exist on players (v2.1)"
        )


class TestPerfIndexesBankStatements:
    """Validate v2.1 performance index on bank_statements."""

    def test_idx_bank_statements_date_exists(self, db_cursor):
        assert _index_exists(db_cursor, "bank_statements", "idx_bank_statements_date"), (
            "idx_bank_statements_date index must exist (v2.1)"
        )


class TestPerfIndexesPhoneTweets:
    """Validate v2.1 performance index on phone_tweets."""

    WAIT_FOR_TABLE = pytest.mark.skip(reason="phone_tweets table may not exist in all setups")

    def test_idx_phone_tweets_date_exists(self, db_cursor):
        # phone_tweets may not exist; gracefully skip
        if not _table_exists(db_cursor, "phone_tweets"):
            pytest.skip("phone_tweets table does not exist in this database")
        assert _index_exists(db_cursor, "phone_tweets", "idx_phone_tweets_date"), (
            "idx_phone_tweets_date index must exist (v2.1)"
        )


# ═══════════════════════════════════════════════════════════════════════════
# Cross-table FK-like citizenid reference patterns
# ═══════════════════════════════════════════════════════════════════════════

class TestCitizenIdReferencePatterns:
    """Verify citizenid appears consistently across tables that reference players."""

    CITIZENID_TABLES = [
        # (table_name, citizenid_column)
        ("players", "citizenid"),
        ("player_houses", "citizenid"),
        ("player_vehicles", "citizenid"),
        ("player_choices", "citizenid"),
        ("story_completions", "citizenid"),
        ("trust_graph", "from_citizen"),
        ("trust_graph", "to_citizen"),
        ("patron_records", "citizenid"),
        ("governance_proposals", "proposed_by"),
        ("skill_ranks", "citizenid"),
        ("player_cosmetics", "citizenid"),
        ("world_state", "changed_by"),
        ("world_events", "triggered_by"),
    ]

    @pytest.mark.parametrize("table_name,col_name", CITIZENID_TABLES)
    def test_citizenid_column_exists(self, db_cursor, table_name, col_name):
        if not _table_exists(db_cursor, table_name):
            pytest.skip(f"Table '{table_name}' does not exist in this database")
        assert _column_exists(db_cursor, table_name, col_name), (
            f"Column '{col_name}' must exist on table '{table_name}' "
            f"(FK-like citizenid reference)"
        )

    @pytest.mark.parametrize("table_name,col_name", CITIZENID_TABLES)
    def test_citizenid_is_varchar(self, db_cursor, table_name, col_name):
        if not _table_exists(db_cursor, table_name):
            pytest.skip(f"Table '{table_name}' does not exist in this database")
        info = _get_column_info(db_cursor, table_name, col_name)
        assert info is not None
        assert info["DATA_TYPE"] == "varchar", (
            f"{table_name}.{col_name}: expected varchar type for citizenid reference, "
            f"got {info['DATA_TYPE']}"
        )
