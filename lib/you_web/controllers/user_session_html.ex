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

  @doc """
  Where the "Sign in with <provider>" button points.

  `ctx` is `nil` on the canonical host: a relative `/auth/:provider` reads
  this same session, as it always has. Off canonical (`UserSessionController.
  social_ctx/1`), the button has to reach `/auth/:provider` on the canonical
  host explicitly — that route's `redirect_uri` is registered with the
  upstream provider against canonical, so a ceremony started on an app host
  can never complete on it — carrying `ctx` so the canonical request can
  recover this session's flight state without a session of its own to read.
  """
  def social_auth_href(provider_slug, nil), do: ~p"/auth/#{provider_slug}"

  def social_auth_href(provider_slug, ctx) when is_binary(ctx),
    do: url(~p"/auth/#{provider_slug}?#{[ctx: ctx]}")
end
