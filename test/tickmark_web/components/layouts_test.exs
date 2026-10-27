defmodule TickmarkWeb.LayoutsTest do
  use ExUnit.Case, async: true
  use TickmarkWeb, :html

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TickmarkWeb.EngagementLive.Components

  @scope %{user: %{id: "user-1", email: "writer@example.com"}}
  @engagement %{id: "engagement-1", client_name: "누리정밀 주식회사", fiscal_year: 2025}

  test "outside an engagement, the shell shows the brand, theme and guest links" do
    document = render_shell(%{presence: [%{id: "user-1", name: "김작성"}]})

    assert document |> LazyHTML.query("#topbar-brand") |> LazyHTML.attribute("href") == ["/"]

    assert document |> LazyHTML.query("#topbar-auth a[href='/users/log-in']") |> LazyHTML.text() ==
             "로그인"

    assert document |> LazyHTML.query("#topbar-auth a[href='/users/register']") |> LazyHTML.text() ==
             "회원가입"

    assert document |> LazyHTML.query("#topbar-theme button") |> Enum.count() == 3
    assert document |> LazyHTML.query("#shell-content") |> LazyHTML.text() == "본문"

    assert document
           |> LazyHTML.query(
             "#topbar-engagement, #topbar-audit, #topbar-presence, #topbar-user-menu"
           )
           |> Enum.empty?()
  end

  test "a logged-in user gets the settings and DELETE logout menu" do
    document = render_shell(%{current_scope: @scope})

    assert document |> LazyHTML.query("#topbar-brand") |> LazyHTML.attribute("href") == [
             "/engagements"
           ]

    assert document |> LazyHTML.query("#topbar-user-menu summary") |> LazyHTML.text() =~
             @scope.user.email

    assert document
           |> LazyHTML.query("#topbar-user-menu a[href='/users/settings']")
           |> LazyHTML.text() =~ "설정"

    assert document
           |> LazyHTML.query("#topbar-user-menu a[data-method=delete]")
           |> LazyHTML.attribute("data-to") == ["/users/log-out"]

    assert document |> LazyHTML.query("#topbar-auth") |> Enum.empty?()
  end

  test "engagement and audit links show their current page independently" do
    for {active, current, other} <- [
          {:engagement, "#topbar-engagement", "#topbar-audit"},
          {:audit, "#topbar-audit", "#topbar-engagement"}
        ] do
      document = render_shell(%{current_scope: @scope, engagement: @engagement, active: active})

      assert document |> LazyHTML.query("#topbar-engagement") |> LazyHTML.text() |> String.trim() ==
               "누리정밀 주식회사 FY2025"

      assert document |> LazyHTML.query("#topbar-engagement") |> LazyHTML.attribute("href") == [
               "/engagements/engagement-1"
             ]

      assert document |> LazyHTML.query("#topbar-audit") |> LazyHTML.attribute("href") == [
               "/engagements/engagement-1/audit"
             ]

      assert document |> LazyHTML.query(current) |> LazyHTML.attribute("aria-current") == ["page"]
      assert document |> LazyHTML.query(other) |> LazyHTML.attribute("aria-current") == []
      assert document |> LazyHTML.query("#topbar-presence") |> Enum.empty?()
    end
  end

  test "screens within an engagement can leave both navigation links unselected" do
    document = render_shell(%{engagement: @engagement})

    assert document |> LazyHTML.query("#topbar-engagement, #topbar-audit") |> Enum.count() == 2
    assert document |> LazyHTML.query("#topbar [aria-current]") |> Enum.empty?()
  end

  test "five viewers show four initials, +1 and the full accessible list" do
    presence = [
      %{id: "user-1", name: "김작성"},
      %{id: "user-2", name: "박검토"},
      %{id: "user-3", name: "이작성"},
      %{id: "user-4", name: "최검토"},
      %{id: "user-5", name: "정작성"}
    ]

    document = render_shell(%{current_scope: @scope, engagement: @engagement, presence: presence})

    assert document |> LazyHTML.query("#topbar-presence [data-presence-id]") |> Enum.count() == 4

    assert document
           |> LazyHTML.query("#topbar-presence [data-presence-id='user-1'].avatar-self")
           |> LazyHTML.text()
           |> String.trim() == "김"

    assert document
           |> LazyHTML.query("#topbar-presence-overflow")
           |> LazyHTML.text()
           |> String.trim() == "+1"

    assert document |> LazyHTML.query("#topbar-presence .sr-only") |> LazyHTML.text() ==
             "지금 보는 사람: 김작성, 박검토, 이작성, 최검토, 정작성"
  end

  test "connection notices use Korean and keep their reconnect behavior" do
    document = render_shell()

    assert document |> LazyHTML.query("#client-error") |> LazyHTML.text() =~ "인터넷 연결을 찾을 수 없습니다"
    assert document |> LazyHTML.query("#server-error") |> LazyHTML.text() =~ "서버에 문제가 생겼습니다"

    assert document |> LazyHTML.query("#client-error, #server-error") |> LazyHTML.text() =~
             "다시 연결하는 중"

    assert document
           |> LazyHTML.query("#client-error[hidden][phx-disconnected][phx-connected]")
           |> Enum.count() == 1

    assert document
           |> LazyHTML.query("#server-error[hidden][phx-disconnected][phx-connected]")
           |> Enum.count() == 1
  end

  test "flash notices start below the top bar and under its layer, so the user menu stays usable" do
    document = render_shell(%{current_scope: @scope, flash: %{"info" => "데모 작성자로 로그인했습니다."}})

    topbar_z = document |> class_list("#topbar") |> z_index()
    toasts = LazyHTML.query(document, "#flash-group .toast")

    assert document |> LazyHTML.query("#topbar-user-menu") |> Enum.count() == 1
    assert document |> LazyHTML.query("#flash-info") |> Enum.count() == 1
    assert Enum.count(toasts) == 3

    for class <- LazyHTML.attribute(toasts, "class") do
      classes = String.split(class)

      assert "top-16" in classes
      assert z_index(classes) < topbar_z
    end
  end

  test "KST display retains the ISO datetime and gives a readable UTC title" do
    document =
      render_component(&Components.kst_time/1, at: ~U[2025-12-31 15:42:10.123456Z])
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query("time") |> LazyHTML.attribute("datetime") == [
             "2025-12-31T15:42:10.123456Z"
           ]

    assert document |> LazyHTML.query("time") |> LazyHTML.attribute("title") == [
             "2025-12-31 15:42:10 UTC"
           ]

    assert document |> LazyHTML.query("time") |> LazyHTML.text() |> String.trim() ==
             "2026-01-01 00:42"
  end

  defp render_shell(attrs \\ %{}) do
    defaults = %{current_scope: nil, engagement: nil, active: nil, presence: [], flash: %{}}

    render_component(&shell/1, Map.merge(defaults, attrs)) |> LazyHTML.from_fragment()
  end

  defp class_list(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> hd() |> String.split()
  end

  defp z_index(classes) do
    Enum.find_value(classes, fn
      "z-" <> layer -> String.to_integer(layer)
      _other -> nil
    end)
  end

  defp shell(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      engagement={@engagement}
      active={@active}
      presence={@presence}
    >
      <p id="shell-content">본문</p>
    </Layouts.app>
    """
  end
end
