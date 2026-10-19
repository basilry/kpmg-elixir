defmodule TickmarkWeb.UserLive.Registration do
  use TickmarkWeb, :live_view

  alias Tickmark.Accounts
  alias Tickmark.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section
        id="registration-page"
        aria-labelledby="registration-title"
        class="mx-auto max-w-sm space-y-6 rounded-box border border-base-300 bg-base-100 p-6 text-sm"
      >
        <header class="space-y-2">
          <h1 id="registration-title" class="text-xl font-semibold">회원가입</h1>
          <p class="text-muted">
            이미 계정이 있나요?
            <.link
              id="login-link"
              navigate={~p"/users/log-in"}
              class="font-semibold text-primary hover:underline"
            >
              로그인
            </.link>
          </p>
        </header>

        <.form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          class="space-y-4"
        >
          <.input
            field={@form[:email]}
            type="email"
            label="이메일"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button
            id="registration-submit"
            phx-disable-with="만드는 중..."
            class="btn btn-primary w-full"
          >
            계정 만들기
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: TickmarkWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "확인 메일을 #{user.email} 로 보냈습니다. 메일의 링크로 로그인하세요."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
