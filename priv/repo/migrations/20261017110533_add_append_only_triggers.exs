defmodule Tickmark.Repo.Migrations.AddAppendOnlyTriggers do
  use Ecto.Migration

  # The database refuses UPDATE and DELETE on evidence tables, so a mistaken
  # Repo.update_all or a manual SQL session cannot rewrite history either.
  def change do
    execute(
      """
      CREATE FUNCTION tickmark_reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'append-only table %: % is not allowed', TG_TABLE_NAME, TG_OP;
      END $$
      """,
      "DROP FUNCTION tickmark_reject_mutation()"
    )

    execute(
      """
      CREATE TRIGGER audit_events_no_update_delete BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION tickmark_reject_mutation()
      """,
      "DROP TRIGGER audit_events_no_update_delete ON audit_events"
    )

    execute(
      """
      CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON audit_events
        FOR EACH STATEMENT EXECUTE FUNCTION tickmark_reject_mutation()
      """,
      "DROP TRIGGER audit_events_no_truncate ON audit_events"
    )

    execute(
      """
      CREATE TRIGGER ai_triages_no_update_delete BEFORE UPDATE OR DELETE ON ai_triages
        FOR EACH ROW EXECUTE FUNCTION tickmark_reject_mutation()
      """,
      "DROP TRIGGER ai_triages_no_update_delete ON ai_triages"
    )

    execute(
      """
      CREATE TRIGGER conclusions_no_update_delete BEFORE UPDATE OR DELETE ON conclusions
        FOR EACH ROW EXECUTE FUNCTION tickmark_reject_mutation()
      """,
      "DROP TRIGGER conclusions_no_update_delete ON conclusions"
    )

    execute(
      """
      CREATE TRIGGER review_decisions_no_update_delete BEFORE UPDATE OR DELETE ON review_decisions
        FOR EACH ROW EXECUTE FUNCTION tickmark_reject_mutation()
      """,
      "DROP TRIGGER review_decisions_no_update_delete ON review_decisions"
    )
  end
end
