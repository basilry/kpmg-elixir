defmodule TickmarkWeb.UserLive.Login do
  use TickmarkWeb, :live_view

  alias Tickmark.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="login-page"
        aria-labelledby="login-title"
        class="mx-auto max-w-sm space-y-6 rounded-box border border-base-300 bg-base-100 p-6 text-sm"
      >
        <header class="space-y-2">
          <h1 id="login-title" class="text-xl font-semibold">로그인</h1>
          <p class="text-muted">
            <%= if @current_scope do %>
              계속하려면 다시 로그인하세요.
            <% else %>
              계정이 없나요?
              <.link
                id="registration-link"
                navigate={~p"/users/register"}
                class="font-semibold text-primary hover:underline"
              >회원가입</.link>
            <% end %>
          </p>
        </header>

        <div :if={local_mail_adapter?()} id="local-mail-notice" class="alert alert-info alert-outline">
          <.icon name="hero-information-circle" class="size-5 shrink-0" />
          <div>
            <p>개발 환경의 메일은 로컬 메일함에 저장됩니다.</p>
            <p>
              보낸 메일은 <.link href="/dev/mailbox" class="underline">개발 메일함</.link>에서 확인하세요.
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
          class="space-y-4"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            id="login_form_magic_email"
            type="email"
            label="이메일"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button id="login-magic-submit" class="btn btn-primary w-full">
            로그인 링크 받기
          </.button>
        </.form>

        <div class="flex items-center gap-3 text-xs text-muted">
          <span class="h-px flex-1 bg-base-300" aria-hidden="true" /> 또는
          <span class="h-px flex-1 bg-base-300" aria-hidden="true" />
        </div>

        <.form
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <.input
            readonly={!!@current_scope}
            field={@form[:email]}
            id="login_form_password_email"
            type="email"
            label="이메일"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="비밀번호"
            autocomplete="current-password"
            spellcheck="false"
          />
          <.input field={@form[:remember_me]} type="checkbox" label="로그인 상태 유지" />
          <.button id="login-password-submit" class="btn btn-primary w-full">
            비밀번호로 로그인
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "등록된 이메일이라면 로그인 링크를 보냈습니다. 메일함을 확인하세요."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:tickmark, Tickmark.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
