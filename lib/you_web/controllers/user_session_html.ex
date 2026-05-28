defmodule YouWeb.UserSessionHTML do
  use YouWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:you, You.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
