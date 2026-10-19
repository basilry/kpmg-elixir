defmodule TickmarkWeb.UserLive.Settings do
  use TickmarkWeb, :live_view

  on_mount {TickmarkWeb.UserAuth, :require_sudo_mode}

  alias Tickmark.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="settings-page" class="mx-auto max-w-xl space-y-6 text-sm">
        <header class="space-y-2">
          <h1 id="settings-title" class="text-xl font-semibold">계정 설정</h1>
          <p class="text-muted">이메일과 비밀번호를 변경할 수 있습니다.</p>
        </header>

        <section
          aria-labelledby="email-settings-title"
          class="rounded-box border border-base-300 bg-base-100 p-6"
        >
          <h2 id="email-settings-title" class="mb-4 text-base font-semibold">이메일 변경</h2>
          <.form
            for={@email_form}
            id="email_form"
            phx-submit="update_email"
            phx-change="validate_email"
            class="space-y-4"
          >
            <.input
              field={@email_form[:email]}
              type="email"
              label="새 이메일"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button id="email-update-submit" variant="primary" phx-disable-with="변경 중...">이메일 변경</.button>
          </.form>
        </section>

        <section
          aria-labelledby="password-settings-title"
          class="rounded-box border border-base-300 bg-base-100 p-6"
        >
          <h2 id="password-settings-title" class="mb-4 text-base font-semibold">비밀번호 변경</h2>
          <.form
            for={@password_form}
            id="password_form"
            action={~p"/users/update-password"}
            method="post"
            phx-change="validate_password"
            phx-submit="update_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-4"
          >
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label="새 비밀번호"
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label="새 비밀번호 확인"
              autocomplete="new-password"
              spellcheck="false"
            />
            <.button id="password-update-submit" variant="primary" phx-disable-with="저장 중...">
              비밀번호 저장
            </.button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "이메일을 변경했습니다.")

        {:error, _} ->
          put_flash(socket, :error, "이메일 변경 링크가 잘못됐거나 만료됐습니다.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "새 이메일로 확인 링크를 보냈습니다. 메일의 링크로 변경을 완료하세요."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
