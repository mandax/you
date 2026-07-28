defmodule YouWeb.UserSessionHTML do
  use YouWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:you, You.Mailer)[:adapter] == Swoosh.Adapters.Local
  end

  # `UserSessionController` passes `@providers` as a slug list, already
  # filtered to whatever the in-flight app allows; this resolves those slugs
  # back to full provider records so the button block can render each
  # provider's display name and icon, in `sort_order` (the order
  # `list_enabled_providers/0` already returns them in).
  defp ordered_providers(slugs) do
    allowed = MapSet.new(slugs)

    You.IdentityProviders.list_enabled_providers()
    |> Enum.filter(&MapSet.member?(allowed, &1.slug))
  end
end
