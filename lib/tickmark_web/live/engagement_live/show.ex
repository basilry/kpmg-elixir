defmodule TickmarkWeb.EngagementLive.Show do
  @moduledoc """
  S2: engagement overview, members, GL imports and test runs.

  Buttons are hidden by role for convenience only. The context functions check
  permissions again, so a hand-crafted event cannot get past them.
  """
  use TickmarkWeb, :live_view

  import TickmarkWeb.EngagementLive.Components

  alias Tickmark.Engagements
  alias Tickmark.Ledger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    # Raises Ecto.NoResultsError (404) for non-members and malformed ids.
    engagement = Engagements.get_engagement!(scope, id)

    # Only the connected (websocket) mount subscribes. The first, static
    # render is a plain HTTP response with no process to receive messages.
    if connected?(socket) do
      :ok = Engagements.subscribe(scope, engagement.id)
    end

    role = my_role(engagement)

    {:ok,
     socket
     |> assign(:page_title, engagement.client_name)
     |> assign(:engagement, engagement)
     |> assign(:can_import, role == :preparer)
     |> assign(:can_manage_members, engagement.created_by_id == scope.user.id)
     |> assign(:member_form, new_member_form())
     |> stream(:members, Engagements.list_members(scope, engagement))
     |> stream(:imports, Ledger.list_imports(scope, engagement.id))}
  end

  @impl true
  def handle_event(
        "add_member",
        %{"member" => %{"email" => email, "role" => role} = params},
        socket
      ) do
    %{current_scope: scope, engagement: engagement} = socket.assigns

    case Engagements.add_member(scope, engagement, email, role) do
      {:ok, member} ->
        {:noreply,
         socket
         |> put_flash(:info, "멤버를 추가했습니다.")
         |> assign(:member_form, new_member_form())
         |> stream_insert(:members, member)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "멤버를 추가할 권한이 없습니다.")}

      {:error, :user_not_found} ->
        {:noreply,
         assign(socket, :member_form, member_form(params, email: "가입한 사용자 중 이 이메일이 없습니다."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :member_form, member_form(params, member_errors(changeset)))}
    end
  end

  # The four engagement topic messages (architecture doc 6). The message
  # carries only a few fields, so the import is read again. stream_insert/4
  # updates a row already on screen in place and puts a new one on top. The
  # other three wait for the Testing and Review contexts.
  @impl true
  def handle_info({:import_updated, %{import_id: import_id}}, socket) do
    ledger_import = Ledger.get_import!(socket.assigns.current_scope, import_id)
    {:noreply, stream_insert(socket, :imports, ledger_import, at: 0)}
  end

  def handle_info({:test_run_updated, _payload}, socket), do: {:noreply, socket}
  def handle_info({:finding_updated, _payload}, socket), do: {:noreply, socket}
  def handle_info({:audit_appended, _payload}, socket), do: {:noreply, socket}

  defp role_options, do: [{"작성자", "preparer"}, {"검토자", "reviewer"}]

  defp new_member_form, do: member_form(%{"email" => "", "role" => "reviewer"}, [])

  defp member_form(params, errors) do
    to_form(params, as: :member, errors: Enum.map(errors, fn {key, msg} -> {key, {msg, []}} end))
  end

  # The unique index on (engagement_id, user_id) is mapped to :user_id; the
  # form shows it next to the email the user typed.
  defp member_errors(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :user_id) do
      [email: "이미 이 감사 대상의 멤버입니다."]
    else
      [role: "역할을 다시 선택하세요."]
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <nav aria-label="이동 경로" class="mb-1 text-sm text-base-content/70">
        <.link navigate={~p"/engagements"} class="link link-hover">감사 대상</.link>
        <span aria-hidden="true">/</span>
        <span>{@engagement.client_name} {fiscal_year_label(@engagement.fiscal_year)}</span>
      </nav>

      <.header>
        {@engagement.client_name}
        <span class="text-base-content/70">{fiscal_year_label(@engagement.fiscal_year)}</span>
        <:subtitle>
          <span id="engagement-overview" class="flex flex-wrap gap-x-4">
            <span>결산일 <span class="tabular-nums">{Date.to_iso8601(@engagement.period_end_date)}</span></span>
            <span>
              수행중요성 <span class="tabular-nums">{format_krw(@engagement.performance_materiality)}</span>원
            </span>
          </span>
        </:subtitle>
        <:actions>
          <div class="flex gap-2">
            <%!-- The audit log is read-only (:view), so every member gets the link. --%>
            <.button id="audit-log-link" navigate={~p"/engagements/#{@engagement}/audit"} class="btn">
              감사 로그
            </.button>
            <.button
              :if={@can_import}
              id="import-link"
              navigate={~p"/engagements/#{@engagement}/imports/new"}
              class="btn btn-primary"
            >
              <.icon name="hero-arrow-up-tray" /> GL 불러오기
            </.button>
          </div>
        </:actions>
      </.header>

      <section id="members-section" aria-labelledby="members-title" class="mb-8">
        <h2 id="members-title" class="mb-2 font-semibold">멤버</h2>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table tk-table">
            <caption class="sr-only">멤버</caption>
            <thead>
              <tr>
                <th scope="col">이메일</th>
                <th scope="col">역할</th>
              </tr>
            </thead>
            <tbody id="members" phx-update="stream">
              <tr :for={{dom_id, member} <- @streams.members} id={dom_id}>
                <td class="font-mono text-sm">
                  {member.user.email}
                  <span
                    :if={member.user_id == @current_scope.user.id}
                    class="text-xs text-base-content/70"
                  >
                    (나)
                  </span>
                </td>
                <td><.role_badge role={member.role} /></td>
              </tr>
            </tbody>
          </table>
        </div>

        <.form
          :if={@can_manage_members}
          for={@member_form}
          id="member-form"
          phx-submit="add_member"
          aria-label="멤버 추가"
          class="mt-3 flex flex-wrap items-start gap-x-3"
        >
          <div class="w-64">
            <.input
              field={@member_form[:email]}
              type="email"
              label="이메일"
              placeholder="name@example.com"
            />
          </div>
          <div class="w-36">
            <.input field={@member_form[:role]} type="select" label="역할" options={role_options()} />
          </div>
          <.button id="add-member-button" class="btn btn-sm mt-7" phx-disable-with="추가 중">
            <.icon name="hero-plus" /> 추가
          </.button>
        </.form>
        <p :if={@can_manage_members} class="mt-1 text-xs text-base-content/70">
          한 사용자는 한 역할만 가집니다. 추가 폼은 감사 대상을 만든 사람에게만 보입니다.
        </p>
      </section>

      <section id="imports-section" aria-labelledby="imports-title" class="mb-8">
        <h2 id="imports-title" class="mb-2 font-semibold">GL 적재</h2>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table tk-table">
            <caption class="sr-only">GL 적재 목록</caption>
            <thead>
              <tr>
                <th scope="col">출처</th>
                <th scope="col">상태</th>
                <th scope="col" class="text-right">전표</th>
                <th scope="col" class="text-right">라인</th>
                <th scope="col" class="text-right">차변 합계(원)</th>
                <th scope="col" class="text-right">대변 합계(원)</th>
                <th scope="col" class="text-right">오류</th>
                <th scope="col" class="text-right">경고</th>
                <th scope="col">해시</th>
                <th scope="col">적재 시각 (KST)</th>
              </tr>
            </thead>
            <tbody id="imports" phx-update="stream">
              <%!-- Shown by CSS only while the stream is empty (streams cannot be counted). --%>
              <tr id="imports-empty" class="hidden only:table-row">
                <td colspan="10" class="text-sm text-base-content/70">아직 불러온 GL이 없습니다.</td>
              </tr>
              <tr :for={{dom_id, ledger_import} <- @streams.imports} id={dom_id}>
                <td class={[ledger_import.source_kind == :upload && "font-mono text-sm"]}>
                  {import_source(ledger_import)}
                </td>
                <td><.import_status status={ledger_import.status} /></td>
                <%= if ledger_import.status == :succeeded do %>
                  <td class="text-right tabular-nums">{format_count(ledger_import.entry_count)}</td>
                  <td class="text-right tabular-nums">{format_count(ledger_import.line_count)}</td>
                  <td class="text-right tabular-nums">{format_krw(ledger_import.total_debit)}</td>
                  <td class="text-right tabular-nums">{format_krw(ledger_import.total_credit)}</td>
                <% else %>
                  <td :for={_ <- 1..4} class="text-right text-base-content/70">
                    -<span class="sr-only">없음</span>
                  </td>
                <% end %>
                <td class={["text-right tabular-nums", ledger_import.error_count > 0 && "text-error"]}>
                  {format_count(ledger_import.error_count)}
                </td>
                <td class="text-right tabular-nums">{format_count(ledger_import.warning_count)}</td>
                <td class="font-mono text-sm slashed-zero" title={ledger_import.sha256}>
                  {String.slice(ledger_import.sha256, 0, 8)}
                </td>
                <td><.kst_time at={ledger_import.inserted_at} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section id="test-runs-section" aria-labelledby="test-runs-title">
        <h2 id="test-runs-title" class="mb-2 font-semibold">테스트 실행</h2>
        <p
          id="test-runs-empty"
          class="rounded-box border border-base-300 bg-base-100 p-4 text-sm text-base-content/70"
        >
          아직 테스트 실행이 없습니다.
        </p>
      </section>
    </Layouts.app>
    """
  end
end
