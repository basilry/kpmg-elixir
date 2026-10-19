defmodule TickmarkWeb.UserLive.Confirmation do
  use TickmarkWeb, :live_view

  alias Tickmark.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="confirmation-page"
        aria-labelledby="confirmation-title"
        class="mx-auto max-w-sm space-y-6 rounded-box border border-base-300 bg-base-100 p-6 text-sm"
      >
        <header class="space-y-2">
          <h1 id="confirmation-title" class="text-xl font-semibold">이 계정으로 로그인</h1>
          <p class="break-all text-muted">{@user.email}</p>
        </header>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
          class="space-y-3"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            id="confirmation-remember-submit"
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="확인 중..."
            class="btn btn-primary w-full"
          >
            확인하고 로그인 상태 유지
          </.button>
          <.button
            id="confirmation-submit"
            phx-disable-with="확인 중..."
            class="btn btn-primary btn-soft w-full"
          >
            확인하고 이번만 로그인
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
          class="space-y-3"
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button
              id="confirmation-login-submit"
              phx-disable-with="로그인 중..."
              class="btn btn-primary w-full"
            >
              로그인
            </.button>
          <% else %>
            <.button
              id="confirmation-login-remember-submit"
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="로그인 중..."
              class="btn btn-primary w-full"
            >
              로그인 상태 유지
            </.button>
            <.button
              id="confirmation-login-submit"
              phx-disable-with="로그인 중..."
              class="btn btn-primary btn-soft w-full"
            >
              이번만 로그인
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="text-sm text-muted">
          비밀번호로 로그인하려면 로그인 후 계정 설정에서 비밀번호를 등록하세요.
        </p>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "링크가 잘못됐거나 만료됐습니다.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
