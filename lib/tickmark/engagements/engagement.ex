defmodule Tickmark.Engagements.Engagement do
  @moduledoc """
  An audit engagement: one client and fiscal year. Everything else hangs off it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "engagements" do
    field :client_name, :string
    field :fiscal_year, :integer
    field :period_end_date, :date
    field :performance_materiality, :decimal

    belongs_to :created_by, Tickmark.Accounts.User
    has_many :members, Tickmark.Engagements.Member

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  created_by_id is set by the context from the scope, never cast from params.
  """
  def changeset(engagement, attrs) do
    engagement
    |> cast(attrs, [:client_name, :fiscal_year, :period_end_date, :performance_materiality])
    |> validate_required([:client_name], message: "회사명을 입력하세요.")
    |> validate_required([:fiscal_year], message: "2000에서 2100 사이로 입력하세요.")
    |> validate_required([:period_end_date], message: "결산일을 선택하세요.")
    |> validate_required([:performance_materiality], message: "0보다 큰 금액을 입력하세요.")
    |> validate_length(:client_name, min: 1, max: 200)
    |> validate_number(:fiscal_year,
      greater_than_or_equal_to: 2000,
      less_than_or_equal_to: 2100,
      message: "2000에서 2100 사이로 입력하세요."
    )
    |> validate_number(:performance_materiality,
      greater_than: 0,
      message: "0보다 큰 금액을 입력하세요."
    )
    |> check_constraint(:fiscal_year,
      name: :fiscal_year_range,
      message: "2000에서 2100 사이로 입력하세요."
    )
    |> check_constraint(:performance_materiality,
      name: :performance_materiality_positive,
      message: "0보다 큰 금액을 입력하세요."
    )
  end
end
