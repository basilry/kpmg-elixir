defmodule Tickmark.Triage.AiTriage do
  @moduledoc """
  An AI suggestion for one finding. Immutable (DB trigger) and never changes the
  finding's review status. model, prompt_version and input_hash make every
  suggestion traceable and reproducible.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ai_triages" do
    # Requested model from config. response_model is what the API reports back.
    field :model, :string
    field :response_model, :string
    field :prompt_version, :string
    field :input_hash, :string
    field :input, :map
    field :risk_level, Ecto.Enum, values: [:low, :medium, :high]
    field :rationale, :string
    # jsonb column holding a JSON array: [%{"procedure" => _, "evidence_to_obtain" => _}]
    field :suggested_procedures, {:array, :map}
    field :missing_information, {:array, :string}, default: []
    field :stop_reason, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :latency_ms, :integer

    belongs_to :finding, Tickmark.Testing.Finding

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields [
    :model,
    :response_model,
    :prompt_version,
    :input_hash,
    :input,
    :risk_level,
    :rationale,
    :suggested_procedures,
    :missing_information,
    :stop_reason,
    :input_tokens,
    :output_tokens,
    :latency_ms
  ]

  @doc """
  finding_id is set by the Triage context, not cast.
  """
  def changeset(ai_triage, attrs) do
    ai_triage
    |> cast(attrs, @fields)
    |> validate_required(@fields -- [:missing_information])
    |> validate_format(:input_hash, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:suggested_procedures, min: 1, max: 4)
    |> validate_length(:missing_information, max: 5)
    |> unique_constraint([:finding_id, :prompt_version, :model, :input_hash])
    |> check_constraint(:input_hash, name: :input_hash_length)
    |> check_constraint(:risk_level, name: :risk_level_valid)
  end
end
