defmodule Tickmark.Ledger do
  @moduledoc """
  GL files and the journal entries loaded from them (architecture doc 9).

  A file is copied into the import directory and registered as a pending
  import together with its audit event and an `ImportWorker` job. The worker
  calls `process_import/1`, which loads the whole file in one transaction or
  nothing at all.

  Every change commits with its audit event, and PubSub messages go out only
  after the commit.
  """
  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias Tickmark.Accounts.Scope
  alias Tickmark.AuditTrail
  alias Tickmark.Engagements
  alias Tickmark.Engagements.Engagement

  alias Tickmark.Ledger.{
    Generator,
    Importer,
    ImportWorker,
    JournalEntry,
    JournalLine,
    LedgerImport
  }

  alias Tickmark.Repo

  # Same limit as the upload (allow_upload max_file_size), checked again here.
  @max_file_bytes 20_000_000
  @worker_actor {:system, "ledger.import_worker"}
  @no_errors %{errors: [], error_count: 0}

  @doc """
  Registers an uploaded CSV. The file at `path` is copied into the import
  directory, because the upload's temporary file goes away with the upload.
  """
  @spec create_import(Scope.t(), Engagement.t(), %{path: String.t(), filename: String.t()}) ::
          {:ok, LedgerImport.t()} | {:error, :forbidden | :file_too_large | Ecto.Changeset.t()}
  def create_import(scope, %Engagement{} = engagement, %{path: path, filename: filename}) do
    with {:ok, _role} <- Engagements.authorize(scope, engagement.id, :import_ledger),
         :ok <- check_file_size(path) do
      stored_filename = "#{Ecto.UUID.generate()}.csv"
      File.mkdir_p!(import_dir())
      File.cp!(path, stored_path(stored_filename))

      register_import(scope, engagement, %{
        source_kind: :upload,
        # Browsers may send a path. Only the name is kept.
        original_filename: Path.basename(filename),
        stored_filename: stored_filename
      })
    end
  end

  @doc """
  Generates the synthetic GL (domain doc 7) and registers it the same way as
  an upload. The answer labels go next to it as `<uuid>.labels.csv` and are
  never loaded into the database.

  Options: `:seed` (default `Generator.default_seed/0`). The same seed gives
  the same file.
  """
  @spec generate_sample_import(Scope.t(), Engagement.t(), keyword()) ::
          {:ok, LedgerImport.t()} | {:error, :forbidden | term()}
  def generate_sample_import(scope, %Engagement{} = engagement, opts \\ []) do
    opts = Keyword.validate!(opts, seed: Generator.default_seed())

    with {:ok, _role} <- Engagements.authorize(scope, engagement.id, :import_ledger) do
      %{gl_csv: gl_csv, labels_csv: labels_csv} = Generator.generate(seed: opts[:seed])
      id = Ecto.UUID.generate()
      labels_path = stored_path("#{id}.labels.csv")
      File.mkdir_p!(import_dir())
      File.write!(stored_path("#{id}.csv"), gl_csv)
      File.write!(labels_path, labels_csv)

      attrs = %{
        source_kind: :generated,
        original_filename: "synthetic-gl-seed-#{opts[:seed]}.csv",
        stored_filename: "#{id}.csv"
      }

      case register_import(scope, engagement, attrs) do
        {:ok, ledger_import} ->
          {:ok, ledger_import}

        # register_import/3 has removed the GL copy. The labels go with it.
        {:error, error} ->
          File.rm(labels_path)
          {:error, error}
      end
    end
  end

  @doc "Imports of an engagement, newest first. Empty without :view."
  @spec list_imports(Scope.t(), Ecto.UUID.t()) :: [LedgerImport.t()]
  def list_imports(scope, engagement_id) do
    case Engagements.authorize(scope, engagement_id, :view) do
      {:ok, _role} ->
        Repo.all(
          from i in LedgerImport,
            where: i.engagement_id == ^engagement_id,
            order_by: [desc: i.inserted_at, desc: i.id]
        )

      {:error, :forbidden} ->
        []
    end
  end

  @doc """
  Raises `Ecto.NoResultsError` for an unknown or malformed id and for an
  import the scope cannot view, so the two cases look the same.
  """
  @spec get_import!(Scope.t(), Ecto.UUID.t()) :: LedgerImport.t()
  def get_import!(scope, id), do: get_visible!(scope, LedgerImport, id)

  @doc "Like `get_import!/2`, with lines preloaded in line_number order."
  @spec get_entry!(Scope.t(), Ecto.UUID.t()) :: JournalEntry.t()
  def get_entry!(scope, id) do
    scope
    |> get_visible!(JournalEntry, id)
    |> Repo.preload(lines: from(l in JournalLine, order_by: l.line_number))
  end

  @doc """
  Loads the import's file. For `ImportWorker` only.

  Returns `{:ok, import}` whenever the import ended up with an outcome:
  succeeded, failed because the file was rejected or missing, or already
  finished by an earlier call (nothing is loaded twice). Returns
  `{:error, :not_found}` for an unknown id. Database errors raise, and the
  job retries.
  """
  @spec process_import(Ecto.UUID.t()) :: {:ok, LedgerImport.t()} | {:error, term()}
  def process_import(import_id) do
    with {:ok, id} <- cast_id(import_id),
         {:ok, ledger_import} <- start_processing(id) do
      load(ledger_import)
    else
      {:finished, ledger_import} -> {:ok, ledger_import}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Marks an unfinished import failed after the job gave up. `reason` goes to
  the log only. Always returns `:ok`, because the caller is a failure handler
  that has nothing left to do.
  """
  @spec mark_import_failed(Ecto.UUID.t(), term()) :: :ok
  def mark_import_failed(import_id, reason) do
    Logger.error("Ledger import #{inspect(import_id)} failed in the worker: #{inspect(reason)}")

    with {:ok, id} <- cast_id(import_id),
         {:ok, _ledger_import} <- fail_import(id, @no_errors, "worker_failed") do
      :ok
    else
      {:error, :not_found} ->
        :ok

      {:error, error} ->
        Logger.error("Ledger import #{import_id} could not be marked failed: #{inspect(error)}")
        :ok
    end
  end

  # Registration -------------------------------------------------------------

  # Registers a file that is already in the import directory: the pending row,
  # its audit event and the job commit together. create_import/3 and
  # generate_sample_import/3 both end here (architecture doc 2.1).
  defp register_import(scope, engagement, %{stored_filename: stored_filename} = attrs) do
    path = stored_path(stored_filename)
    attrs = Map.merge(attrs, %{byte_size: File.stat!(path).size, sha256: sha256!(path)})

    changeset =
      LedgerImport.create_changeset(
        %LedgerImport{engagement_id: engagement.id, uploaded_by_id: scope.user.id},
        attrs
      )

    Multi.new()
    |> Multi.insert(:ledger_import, changeset)
    |> AuditTrail.append(:audit_event, fn %{ledger_import: ledger_import} ->
      audit_event(ledger_import, AuditTrail.actor(scope), "ledger_import.created", %{
        "source_kind" => Atom.to_string(ledger_import.source_kind),
        "original_filename" => ledger_import.original_filename,
        "byte_size" => ledger_import.byte_size,
        "sha256" => ledger_import.sha256
      })
    end)
    |> Oban.insert(:job, fn %{ledger_import: ledger_import} ->
      ImportWorker.new(%{"ledger_import_id" => ledger_import.id})
    end)
    |> transact_or_remove(path)
    |> case do
      {:ok, %{ledger_import: ledger_import}} ->
        broadcast_update(ledger_import)
        {:ok, ledger_import}

      {:error, _step, error, _changes} ->
        File.rm(path)
        {:error, error}
    end
  end

  # A raise (for example a lost connection) must not leave the copy behind
  # either. The error itself is re-raised.
  defp transact_or_remove(multi, path) do
    Repo.transact(multi)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      File.rm(path)
      reraise error, __STACKTRACE__
  end

  defp check_file_size(path) do
    if File.stat!(path).size > @max_file_bytes, do: {:error, :file_too_large}, else: :ok
  end

  # Reads the file in 64 KiB blocks, so a 20MB file is never held in memory.
  defp sha256!(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Loading ------------------------------------------------------------------

  defp start_processing(id) do
    Multi.new()
    |> Multi.run(:ledger_import, fn _repo, _changes -> lock_unfinished(id) end)
    |> Multi.update(:processing, fn %{ledger_import: ledger_import} ->
      LedgerImport.processing_changeset(ledger_import, DateTime.utc_now())
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{processing: ledger_import}} ->
        broadcast_update(ledger_import)
        {:ok, ledger_import}

      {:error, _step, error, _changes} ->
        unwrap_lock_error(error)
    end
  end

  defp load(%LedgerImport{} = ledger_import) do
    path = stored_path(ledger_import.stored_filename)

    if File.regular?(path) do
      load_file(ledger_import, path)
    else
      Logger.error("Ledger import #{ledger_import.id}: the stored file is missing")
      fail_import(ledger_import.id, @no_errors, "file_missing")
    end
  end

  # All or nothing: the rows, the outcome and its audit event are one
  # transaction. A rejected file rolls back everything it wrote so far.
  defp load_file(ledger_import, path) do
    Multi.new()
    |> Multi.run(:ledger_import, fn _repo, _changes -> lock_unfinished(ledger_import.id) end)
    |> Multi.run(:summary, fn _repo, %{ledger_import: locked} -> Importer.run(locked, path) end)
    |> Multi.update(:succeeded, fn %{ledger_import: locked, summary: summary} ->
      LedgerImport.succeeded_changeset(locked, summary, DateTime.utc_now())
    end)
    |> AuditTrail.append(:audit_event, fn %{succeeded: loaded} ->
      audit_event(loaded, @worker_actor, "ledger_import.succeeded", %{
        "entry_count" => loaded.entry_count,
        "line_count" => loaded.line_count,
        "total_debit" => Decimal.to_string(loaded.total_debit),
        "total_credit" => Decimal.to_string(loaded.total_credit),
        "warning_count" => loaded.warning_count
      })
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{succeeded: loaded}} ->
        broadcast_update(loaded)
        {:ok, loaded}

      {:error, :summary, summary, _changes} ->
        fail_import(ledger_import.id, summary, "validation_failed")

      {:error, _step, error, _changes} ->
        already_finished_or_error(error)
    end
  end

  # Its own transaction, after the load (if any) has rolled back.
  defp fail_import(id, result, reason) do
    Multi.new()
    |> Multi.run(:ledger_import, fn _repo, _changes -> lock_unfinished(id) end)
    |> Multi.update(:failed, fn %{ledger_import: ledger_import} ->
      LedgerImport.failed_changeset(ledger_import, result, DateTime.utc_now())
    end)
    |> AuditTrail.append(:audit_event, fn %{failed: failed} ->
      audit_event(failed, @worker_actor, "ledger_import.failed", %{
        "reason" => reason,
        "error_count" => failed.error_count
      })
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{failed: failed}} ->
        broadcast_update(failed)
        {:ok, failed}

      {:error, _step, error, _changes} ->
        already_finished_or_error(error)
    end
  end

  # SELECT ... FOR UPDATE serializes workers on the same import, so a job that
  # runs twice cannot load the file twice.
  defp lock_unfinished(id) do
    query = from i in LedgerImport, where: i.id == ^id, lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :not_found}
      ledger_import -> unfinished(ledger_import)
    end
  end

  defp unfinished(ledger_import) do
    if LedgerImport.finished?(ledger_import),
      do: {:error, {:finished, ledger_import}},
      else: {:ok, ledger_import}
  end

  # Before the load: a finished import stops process_import/1 early.
  defp unwrap_lock_error({:finished, ledger_import}), do: {:finished, ledger_import}
  defp unwrap_lock_error(error), do: {:error, error}

  # After the load started: another run finished first, which is an outcome too.
  defp already_finished_or_error({:finished, ledger_import}), do: {:ok, ledger_import}
  defp already_finished_or_error(error), do: {:error, error}

  # Helpers ------------------------------------------------------------------

  defp get_visible!(scope, schema, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %{engagement_id: engagement_id} = record <- Repo.get(schema, id),
         {:ok, _role} <- Engagements.authorize(scope, engagement_id, :view) do
      record
    else
      _ -> raise Ecto.NoResultsError, queryable: schema
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp audit_event(ledger_import, actor, action, payload) do
    %{
      actor: actor,
      action: action,
      engagement_id: ledger_import.engagement_id,
      subject_type: "ledger_import",
      subject_id: ledger_import.id,
      payload: payload
    }
  end

  defp broadcast_update(%LedgerImport{} = ledger_import) do
    Engagements.broadcast(
      ledger_import.engagement_id,
      {:import_updated,
       %{
         import_id: ledger_import.id,
         status: ledger_import.status,
         entry_count: ledger_import.entry_count,
         error_count: ledger_import.error_count
       }}
    )
  end

  defp import_dir, do: Application.fetch_env!(:tickmark, :import_dir)

  defp stored_path(stored_filename), do: Path.join(import_dir(), stored_filename)
end
