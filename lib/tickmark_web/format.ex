defmodule TickmarkWeb.Format do
  @moduledoc """
  Display names and formatting shared by the audit screens.

  Existing S1/S2 amount, count and KST helpers are reused until those screens
  move their helpers here, so the same value never has two formatting rules.
  """

  alias Tickmark.Testing.Rules
  alias TickmarkWeb.EngagementLive.Components

  @short_rule_names %{
    "weekend_holiday_posting" => "휴일",
    "off_hours_entry" => "시간 외",
    "round_amount" => "라운드",
    "period_end_manual" => "기말 수기",
    "approval_control_gap" => "승인 이탈",
    "backdated_posting" => "증빙일",
    "rare_account_pair" => "희귀 조합",
    "duplicate_entry" => "중복"
  }

  def short_rule_name(rule_id), do: Map.get(@short_rule_names, rule_id, rule_id)

  def rule_name(rule_id) do
    case Rules.fetch(rule_id) do
      {:ok, module} -> module.name()
      :error -> rule_id
    end
  end

  @doc "Registry order first; unknown ids follow in alphabetical order."
  def sort_rule_ids(rule_ids) do
    positions = Rules.ids() |> Enum.with_index() |> Map.new()
    Enum.sort_by(rule_ids, &{Map.get(positions, &1, map_size(positions)), &1})
  end

  def format_krw(nil), do: "-"
  def format_krw(value), do: Components.format_krw(value)
  defdelegate format_count(value), to: Components

  def format_date(%Date{} = date), do: Date.to_iso8601(date)
  def format_date(nil), do: "-"

  def format_kst(%DateTime{} = at), do: Components.format_kst(at)
  def format_kst(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  def format_kst(nil), do: "-"

  @doc "Detailed system timestamps include seconds; GL wall clock times stay KST."
  def format_kst(%DateTime{} = at, :second) do
    at |> DateTime.add(9, :hour) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  def format_kst(%NaiveDateTime{} = at, :second),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")

  def utc_title(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  def run_status_label(:running), do: "실행 중"
  def run_status_label(:completed), do: "완료"
  def run_status_label(:completed_with_errors), do: "일부 실패"

  def rule_status_label(:queued), do: "대기"
  def rule_status_label(:running), do: "실행 중"
  def rule_status_label(:succeeded), do: "완료"
  def rule_status_label(:skipped), do: "미실행"
  def rule_status_label(:failed), do: "실패"

  def review_status_label(:open), do: "-"
  def review_status_label(:concluded), do: "검토 대기"
  def review_status_label(:approved), do: "승인"
  def review_status_label(:rejected), do: "반려"

  def score_band(score) when score < 25, do: "경미"
  def score_band(score) when score < 50, do: "중"
  def score_band(score) when score < 75, do: "상"
  def score_band(_score), do: "최상"
end
