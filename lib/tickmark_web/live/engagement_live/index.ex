defmodule TickmarkWeb.EngagementLive.Index do
  @moduledoc """
  S1: the engagements the user belongs to. `:new` opens an inline create panel
  above the list on the same screen (no modal).
  """
  use TickmarkWeb, :live_view

  import TickmarkWeb.EngagementLive.Components

  alias Tickmark.Engagements
  alias Tickmark.Engagements.Engagement

  @impl true
  def mount(_params, _session, socket) do
    engagements = Engagements.list_engagements(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "감사 대상")
     |> stream(:engagements, engagements)}
  end

  # mount runs once; handle_params runs on every patch between :index and
  # :new, so the panel opens and closes without reloading the list.
  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action)}
  end

  defp apply_action(socket, :index), do: assign(socket, :form, nil)

  defp apply_action(socket, :new) do
    assign(socket, :form, to_form(Engagements.change_engagement(%Engagement{})))
  end

  @impl true
  def handle_event("validate", %{"engagement" => params}, socket) do
    changeset = Engagements.change_engagement(%Engagement{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"engagement" => params}, socket) do
    case Engagements.create_engagement(socket.assigns.current_scope, params) do
      {:ok, engagement} ->
        {:noreply,
         socket
         |> put_flash(:info, "감사 대상을 만들었습니다.")
         |> push_navigate(to: ~p"/engagements/#{engagement}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        감사 대상
        <:actions>
          <.button
            :if={@live_action == :index}
            id="new-engagement-button"
            patch={~p"/engagements/new"}
          >
            <.icon name="hero-plus" /> 새 감사 대상
          </.button>
        </:actions>
      </.header>

      <section
        :if={@form}
        id="new-engagement-panel"
        aria-labelledby="new-engagement-title"
        class="mb-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <h2 id="new-engagement-title" class="mb-2 font-semibold">새 감사 대상</h2>
        <.form for={@form} id="engagement-form" phx-change="validate" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2">
            <.input field={@form[:client_name]} label="회사명" />
            <.input field={@form[:fiscal_year]} type="number" label="회계연도" placeholder="2025" />
            <.input field={@form[:period_end_date]} type="date" label="결산일" />
            <.input
              field={@form[:performance_materiality]}
              label="수행중요성 (원)"
              inputmode="decimal"
              placeholder="225000000"
            />
          </div>
          <p class="mt-1 flex items-center gap-1.5 text-xs text-base-content/70">
            <.icon name="hero-information-circle" class="size-4" />
            만든 사람은 이 감사 대상의 작성자 멤버가 됩니다. 검토자는 상세 화면에서 추가합니다.
          </p>
          <div class="mt-3 flex justify-end gap-2">
            <.button patch={~p"/engagements"} class="btn btn-sm">취소</.button>
            <.button
              id="create-engagement-button"
              class="btn btn-primary btn-sm"
              phx-disable-with="만드는 중"
            >
              만들기
            </.button>
          </div>
        </.form>
      </section>

      <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table class="table tk-table">
          <caption class="sr-only">내가 속한 감사 대상</caption>
          <thead>
            <tr>
              <th scope="col">회사명</th>
              <th scope="col">회계연도</th>
              <th scope="col">결산일</th>
              <th scope="col" class="text-right">수행중요성(원)</th>
              <th scope="col">내 역할</th>
            </tr>
          </thead>
          <tbody id="engagements" phx-update="stream">
            <tr id="engagements-empty" class="hidden only:table-row">
              <td colspan="5" class="py-6 text-center text-base-content/70">
                감사 대상이 없습니다.
                <.link patch={~p"/engagements/new"} class="link link-primary">새 감사 대상 만들기</.link>
              </td>
            </tr>
            <tr :for={{dom_id, engagement} <- @streams.engagements} id={dom_id}>
              <td>
                <.link navigate={~p"/engagements/#{engagement}"} class="link link-hover font-medium">
                  {engagement.client_name}
                </.link>
              </td>
              <td>{fiscal_year_label(engagement.fiscal_year)}</td>
              <td class="tabular-nums">{Date.to_iso8601(engagement.period_end_date)}</td>
              <td class="text-right tabular-nums whitespace-nowrap">
                {format_krw(engagement.performance_materiality)}
              </td>
              <td><.role_badge role={my_role(engagement)} /></td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
