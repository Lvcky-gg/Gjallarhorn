package tests

// migrate_test.odin — schema migration beyond CREATE TABLE (GH-023). Simulates
// an older table that predates two model fields, then asserts migrate() ALTERs
// them in and logs the steps. DB-gated; skips if no docker Postgres.
// Run with: odin test ./tests   (needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:testing"
import gh "../gjallarhorn"

// table_name("MigrateModel") -> "migratemodels"
MigrateModel :: struct {
	id:    int    `db:"id,pk,auto"`,
	title: string `db:"title"`,
	score: int    `db:"score"`,
}

@(test)
migrate_adds_missing_columns :: proc(t: ^testing.T) {
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}

	app := gh.new(gh.Config{db_type = .Postgres, postgres = cfg, pool_size = 1})
	if !gh.connect(&app) {
		fmt.eprintln("migrate_test: postgres unavailable; skipping migration test")
		return
	}
	defer gh.disconnect(&app)

	gh.remember(&app, MigrateModel)
	defer delete(app.models)

	// A standalone connection for setup and column inspection.
	probe: gh.Pg_Conn
	gh.pg_open(&probe, cfg)
	defer net.close(probe.sock)

	// Stand in for an older schema: the table exists with only `id`, missing
	// the `title` and `score` fields the model has since grown.
	gh.pg_query(&probe, "DROP TABLE IF EXISTS migratemodels;", nil)
	gh.pg_query(&probe, "CREATE TABLE migratemodels (id BIGINT);", nil)

	before := gh.existing_columns(&probe, "migratemodels")
	testing.expect(t, !("title" in before), "precondition: title not yet present")
	testing.expect(t, !("score" in before), "precondition: score not yet present")

	gh.migrate(&app)

	after := gh.existing_columns(&probe, "migratemodels")
	testing.expect(t, "id" in after, "id stays")
	testing.expect(t, "title" in after, "title added by migrate")
	testing.expect(t, "score" in after, "score added by migrate")

	// The additions are recorded in the migration log.
	logged, _ := gh.pg_query(
		&probe,
		"SELECT name FROM mimir_migrations WHERE name LIKE 'add_column:migratemodels.%';",
		nil,
	)
	testing.expect(t, len(logged.rows) >= 2, "both column adds were logged")

	// Idempotent: a second migrate adds nothing more.
	gh.migrate(&app)
	again := gh.existing_columns(&probe, "migratemodels")
	testing.expect_value(t, len(again), len(after))

	gh.pg_query(&probe, "DROP TABLE IF EXISTS migratemodels;", nil)
}
