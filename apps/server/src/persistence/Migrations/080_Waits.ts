import * as Effect from "effect/Effect";
import * as SqlClient from "effect/sql/SqlClient";

export default Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;

  yield* sql`
    CREATE TABLE IF NOT EXISTS waits (
      wait_id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      condition_json TEXT NOT NULL,
      next TEXT NOT NULL,
      created_at TEXT NOT NULL,
      created_by TEXT NOT NULL,
      origin_json TEXT NOT NULL,
      state TEXT NOT NULL,
      auto_continue INTEGER NOT NULL,
      last_checked_at TEXT,
      last_result TEXT,
      failures INTEGER NOT NULL DEFAULT 0,
      next_check_at TEXT,
      ready_at TEXT,
      continued_at TEXT
    )
  `;
  yield* sql`
    CREATE INDEX IF NOT EXISTS waits_due_idx ON waits(state, next_check_at)
  `;
});
