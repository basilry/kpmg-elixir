defmodule Tickmark.Accounts.UserNotifier do
  import Swoosh.Email

  alias Tickmark.Mailer
  alias Tickmark.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"Tickmark", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "[Tickmark] 이메일 변경 확인", """

    Tickmark 이메일 변경 안내

    #{user.email} 계정의 이메일을 변경하려면 아래 링크를 눌러 주세요.

    #{url}

    요청하지 않았다면 이 메일을 무시하세요.
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "[Tickmark] 로그인 링크", """

    Tickmark 로그인 안내

    #{user.email} 계정으로 로그인하려면 아래 링크를 눌러 주세요.

    #{url}

    요청하지 않았다면 이 메일을 무시하세요.
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "[Tickmark] 회원가입 확인", """

    Tickmark 회원가입 안내

    #{user.email} 계정을 확인하고 로그인하려면 아래 링크를 눌러 주세요.

    #{url}

    요청하지 않았다면 이 메일을 무시하세요.
    """)
  end
end
