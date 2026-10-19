defmodule Tickmark.Testing.RulesLabelTest do
  use Tickmark.DataCase, async: true

  import Tickmark.AccountsFixtures
  import Tickmark.SchemaFixtures

  alias NimbleCSV.RFC4180, as: CSV
  alias Tickmark.Accounts.Scope
  alias Tickmark.Ledger
  alias Tickmark.Ledger.{Generator, JournalEntry, JournalLine}
  alias Tickmark.Testing.{RuleContext, Rules}

  setup do
    user = user_fixture()
    engagement = insert_engagement(user)
    insert_member(engagement, user, :preparer)
    %{scope: Scope.for_user(user), engagement: engagement}
  end

  # Each seed is generated and imported exactly once; both acceptance criteria
  # and the score/count checks share that import. No excluded slow-test tag.
  for seed <- [Generator.default_seed(), 7] do
    @seed seed
    test "all rule sets, scores and triage agree with labels for seed #{seed}", ctx do
      seed = @seed

      assert {:ok, imported} =
               Ledger.generate_sample_import(ctx.scope, ctx.engagement, seed: seed)

      gl_path =
        Path.join(Application.fetch_env!(:tickmark, :import_dir), imported.stored_filename)

      labels_path = String.replace_suffix(gl_path, ".csv", ".labels.csv")

      on_exit(fn ->
        File.rm(gl_path)
        File.rm(labels_path)
      end)

      assert {:ok, %{status: :succeeded} = loaded} = Ledger.process_import(imported.id)
      labels = read_labels(labels_path)

      entries =
        Repo.all(
          from e in JournalEntry,
            where: e.ledger_import_id == ^loaded.id,
            select: {e.id, e.entry_number}
        )
        |> Map.new()

      assert MapSet.new(Map.values(entries)) == MapSet.new(labels, & &1["entry_number"])

      actual = run_rules(loaded, ctx.engagement, entries, seed)
      weights = Map.new(Rules.all(), &{&1.id(), &1.weight()})

      for label <- labels do
        number = label["entry_number"]
        expected = String.split(label["expected_rules"], ";", trim: true) |> Enum.sort()
        actual_rules = Map.get(actual, number, []) |> Enum.sort()

        message =
          "seed=#{seed} entry_number=#{number} scenario_id=#{label["scenario_id"]} expected_rules=#{inspect(expected)} actual_rules=#{inspect(actual_rules)}"

        assert actual_rules == expected, message
        assert score(actual_rules, weights) == String.to_integer(label["expected_score"]), message
      end

      actual_triage =
        actual
        |> Enum.filter(fn {_number, rules} -> score(rules, weights) >= 25 end)
        |> MapSet.new(&elem(&1, 0))

      expected_triage =
        labels
        |> Enum.filter(&(&1["expected_triage"] == "true"))
        |> MapSet.new(& &1["entry_number"])

      assert actual_triage == expected_triage

      if seed == Generator.default_seed() do
        assert loaded.entry_count == 8_341
        assert loaded.line_count == 19_804

        assert Repo.aggregate(
                 from(l in JournalLine, where: l.ledger_import_id == ^loaded.id),
                 :count
               ) == 19_804

        assert MapSet.size(actual_triage) == 52

        assert Enum.count(actual, fn {_number, rules} -> score(rules, weights) in 1..24 end) ==
                 213
      end
    end
  end

  defp read_labels(path) do
    [header | rows] = path |> File.read!() |> CSV.parse_string(skip_headers: false)
    Enum.map(rows, &Map.new(Enum.zip(header, &1)))
  end

  defp run_rules(imported, engagement, entries, seed) do
    Enum.reduce(Rules.all(), %{}, fn rule, actual ->
      context = %RuleContext{
        test_run_id: Ecto.UUID.generate(),
        ledger_import_id: imported.id,
        engagement: engagement,
        params: rule.default_params()
      }

      {microseconds, result} = :timer.tc(fn -> rule.run(context) end)
      assert {:ok, hits} = result
      numbers = Enum.map(hits, &Map.fetch!(entries, &1.journal_entry_id))

      assert numbers == Enum.sort(Enum.uniq(numbers)),
             "#{rule.id()}: hits must be unique and in entry_number order"

      if System.get_env("RULE_TIMINGS") == "1" do
        IO.puts(
          "rule_timing seed=#{seed} rule=#{rule.id()} microseconds=#{microseconds} hits=#{length(hits)}"
        )
      end

      Enum.reduce(numbers, actual, fn number, acc ->
        Map.update(acc, number, [rule.id()], &[rule.id() | &1])
      end)
    end)
  end

  defp score(rule_ids, weights), do: min(100, Enum.sum_by(rule_ids, &Map.fetch!(weights, &1)))
end
