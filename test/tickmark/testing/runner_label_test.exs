defmodule Tickmark.Testing.RunnerLabelTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias NimbleCSV.RFC4180, as: CSV
  alias Tickmark.Accounts.Scope
  alias Tickmark.Ledger
  alias Tickmark.Ledger.{Generator, JournalEntry}
  alias Tickmark.Testing
  alias Tickmark.Testing.{Finding, RuleResult, Rules}

  setup do
    user = user_fixture()
    engagement = insert_engagement(user)
    insert_member(engagement, user, :preparer)
    %{scope: Scope.for_user(user), engagement: engagement}
  end

  # The labels stay outside the database. Both queues execute the same jobs
  # used by the application, including result insertion and final aggregation.
  for seed <- [Generator.default_seed(), 7] do
    @seed seed
    test "import and rule jobs produce findings matching every label for seed #{seed}", ctx do
      assert {:ok, imported} =
               Ledger.generate_sample_import(ctx.scope, ctx.engagement, seed: @seed)

      path = Path.join(Application.fetch_env!(:tickmark, :import_dir), imported.stored_filename)
      labels_path = String.replace_suffix(path, ".csv", ".labels.csv")

      on_exit(fn ->
        File.rm(path)
        File.rm(labels_path)
      end)

      labels = read_labels(labels_path)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :ingest, with_safety: false)
      loaded = Ledger.get_import!(ctx.scope, imported.id)
      assert loaded.status == :succeeded
      assert loaded.entry_count == length(labels)

      entry_numbers =
        Repo.all(
          from e in JournalEntry,
            where: e.ledger_import_id == ^loaded.id,
            select: e.entry_number
        )

      assert MapSet.new(entry_numbers) == MapSet.new(labels, & &1["entry_number"])

      assert {:ok, run} = Testing.start_test_run(ctx.scope, loaded, :all)
      rule_count = length(Rules.ids())

      assert %{success: ^rule_count, failure: 0} =
               Oban.drain_queue(queue: :rules, with_safety: false)

      completed = Testing.get_test_run!(ctx.scope, run.id)
      assert completed.status == :completed
      assert completed.finished_at
      assert length(completed.test_run_rules) == rule_count
      assert Enum.all?(completed.test_run_rules, &(&1.status == :succeeded))

      actual_rules =
        Repo.all(
          from r in RuleResult,
            join: e in JournalEntry,
            on: e.id == r.journal_entry_id,
            where: r.test_run_id == ^run.id,
            order_by: r.rule_id,
            select: {e.entry_number, r.rule_id}
        )
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      findings =
        Repo.all(
          from f in Finding,
            join: e in JournalEntry,
            on: e.id == f.journal_entry_id,
            where: f.test_run_id == ^run.id,
            select: {e.entry_number, f}
        )
        |> Map.new()

      assert completed.finding_count == map_size(findings)
      assert map_size(findings) == map_size(actual_rules)

      # Domain 7.6 criterion 1: exact rule sets for anomalies, benign triggers
      # and clean entries. Clean entries must not produce findings at all.
      for label <- labels do
        number = label["entry_number"]
        expected = String.split(label["expected_rules"], ";", trim: true) |> Enum.sort()
        actual = Map.get(actual_rules, number, [])

        message =
          "seed=#{@seed} entry=#{number} label=#{label["label"]} scenario=#{label["scenario_id"]} expected=#{inspect(expected)} actual=#{inspect(actual)}"

        assert actual == expected, message

        case expected do
          [] ->
            refute Map.has_key?(findings, number), message

          _ ->
            finding = Map.fetch!(findings, number)
            assert finding.rule_ids == expected, message
            assert finding.hit_count == length(expected), message
            assert finding.score == String.to_integer(label["expected_score"]), message
            assert finding.status == :open and finding.triage_status == :none, message
        end
      end

      # Domain 7.6 criterion 2: the persisted score and run threshold select
      # exactly the labeled triage set, not just the same number of entries.
      expected_triage =
        labels
        |> Enum.filter(&(&1["expected_triage"] == "true"))
        |> MapSet.new(& &1["entry_number"])

      actual_triage =
        findings
        |> Enum.filter(fn {_number, finding} -> finding.score >= completed.triage_threshold end)
        |> MapSet.new(&elem(&1, 0))

      assert actual_triage == expected_triage

      if @seed == Generator.default_seed() do
        assert loaded.entry_count == 8_341
        assert loaded.line_count == 19_804
        assert completed.finding_count == 265
        assert MapSet.size(actual_triage) == 52
        assert Testing.count_findings(ctx.scope, run.id).minor == 213
      end
    end
  end

  defp read_labels(path) do
    [header | rows] = path |> File.read!() |> CSV.parse_string(skip_headers: false)
    Enum.map(rows, &Map.new(Enum.zip(header, &1)))
  end
end
