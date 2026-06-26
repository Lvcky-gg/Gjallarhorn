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
	app := gh.App {
		db_type = .Postgres,
	}
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}
	if !gh.pg_open(&app.pg, cfg) {
		fmt.eprintln("migrate_test: postgres unavailable; skipping migration test")
		return
	}
	defer net.close(app.pg.sock)

	gh.remember(&app, MigrateModel)
	defer delete(app.models)

	// Stand in for an older schema: the table exists with only `id`, missing
	// the `title` and `score` fields the model has since grown.
	gh.pg_query(&app.pg, "DROP TABLE IF EXISTS migratemodels;", nil)
	gh.pg_query(&app.pg, "CREATE TABLE migratemodels (id BIGINT);", nil)

	before := gh.existing_columns(&app.pg, "migratemodels")
	testing.expect(t, !("title" in before), "precondition: title not yet present")
	testing.expect(t, !("score" in before), "precondition: score not yet present")

	gh.migrate(&app)

	after := gh.existing_columns(&app.pg, "migratemodels")
	testing.expect(t, "id" in after, "id stays")
	testing.expect(t, "title" in after, "title added by migrate")
	testing.expect(t, "score" in after, "score added by migrate")

	// The additions are recorded in the migration log.
	logged, _ := gh.pg_query(
		&app.pg,
		"SELECT name FROM mimir_migrations WHERE name LIKE 'add_column:migratemodels.%';",
		nil,
	)
	testing.expect(t, len(logged.rows) >= 2, "both column adds were logged")

	// Idempotent: a second migrate adds nothing more.
	gh.migrate(&app)
	again := gh.existing_columns(&app.pg, "migratemodels")
	testing.expect_value(t, len(again), len(after))

	gh.pg_query(&app.pg, "DROP TABLE IF EXISTS migratemodels;", nil)
}
