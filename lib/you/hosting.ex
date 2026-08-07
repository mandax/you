defmodule You.Hosting do
  @moduledoc """
  The one place that answers "is this request host one of You's own, and if
  so which app is it" (#121, #123).

  Before this module, that question was starting to get asked three separate
  ways: `YouWeb.RequestURL.allowed_hosts/0` (which links are safe to build),
  `You.WebAuthn.available_for_host?/1` (which hosts may offer passkeys), and
  the endpoint's `check_origin` (which origins a LiveView socket may connect
  from). Three independent predicates that can disagree is a security bug
  waiting to happen — a host that resolves to an app for branding but is
  refused for links, or vice versa. `resolve/1` is now the single source of
  truth for host recognition; `RequestURL.allowed_hosts/0` and
  `check_origin?/1` both defer to it. `You.WebAuthn.available_for_host?/1` is
  deliberately **not** rebuilt on top of it: passkeys are gated on a
  registrable-suffix check against `WEBAUTHN_RP_ID`, a genuinely broader
  question ("is this host under the RP ID's zone") than "is this an app You
  has a row for" — see its own moduledoc.

  ## Resolution

  A request host resolves one of three ways:

  - `:canonical` — matches `YouWeb.Endpoint.host/0` (`PHX_HOST`).
  - `{:app, app}` — matches a registered app's rendered hostname
    (`hostname_label` spliced into `hostname_template`).
  - `:unknown` — neither. Never branded, never treated as one of You's own.

  ## One gate for resolution and #123's routing rules

  `enabled?/0` — `feature_app_hostnames` on *and* a syntactically valid
  template configured — is the single switch both this module's resolution
  and the router's canonical-only redirects (`YouWeb.Plugs.
  RequireCanonicalHost`, `YouWeb.Plugs.CanonicalHostRedirect`) are driven
  by. #121's security review flagged the risk of resolution going live
  before #123's routing rules do — a recognised app host would then also
  serve discovery, JWKS and `/oauth/*`, an alternate issuer with a real
  app's name on it. Driving both off this one function makes that ordering
  impossible to get wrong by configuration: there is no environment or
  console state that turns on resolution without also turning on the
  redirects, because they read the same flag through the same code path. A
  separate boot-time assertion would only be guarding against two
  independently-wired mechanisms drifting apart — they are not
  independently wired. "Syntactically valid" is `split_template/0`
  succeeding (exactly one `{label}` placeholder) — a template present but
  malformed does not leave resolution permanently dead while the redirects
  fire anyway; both stay off together.

  Feature off, or no valid template: `resolve/1` never returns `{:app, _}`,
  `hosts/0` is exactly `[canonical]`, and `check_origin?/1` accepts only the
  canonical origin — byte-identical to today.

  ## Who sets the template

  `APP_HOSTNAME_TEMPLATE` is environment-only, like `WEBAUTHN_RP_ID` and
  `PHX_HOST` (`You.Settings.forbidden_keys/0`) — set by the Operator, not
  the console. It gates which hosts an emailed link is allowed to point at
  and which origins a LiveView socket accepts, the same class of value
  those two are: something a login depends on, which must not sit behind
  that login. `feature_app_hostnames` (whether to use the template at all)
  stays a console/Admin-owned switch, same as every other feature flag —
  the Admin decides whether to turn per-app hostnames on for apps they
  manage; the Operator decides what pattern those hostnames take, because
  only the Operator controls the DNS and certificates the pattern has to
  match.
  """

  alias You.Admin
  alias You.Admin.App

  @doc """
  Whether per-app hostname resolution is live on this instance.

  Both halves are required: a template with the feature off, or a feature on
  with a missing or malformed template, resolve nothing — there would be no
  rule to turn a request host into a label. Malformed (not exactly one
  `{label}` placeholder) counts as absent here, not merely at the point
  resolution is attempted — otherwise a bad template leaves resolution
  permanently dead while `feature_app_hostnames` still trips #123's
  canonical-only redirects on, which is the drift #121's review named.
  """
  def enabled? do
    You.Settings.enabled?(:feature_app_hostnames) and not is_nil(split_template())
  end

  @doc """
  The configured hostname template (`{label}.example.com`), or nil.

  Set via `APP_HOSTNAME_TEMPLATE` — environment-only, see this module's
  moduledoc. Not normalized here: `split_template/0` is what every other
  function in this module actually resolves and renders against, and it
  downcases — call that instead of comparing against this raw value.
  """
  def template do
    case Application.get_env(:you, :app_hostname_template) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether a template is configured *and* well-formed enough to be worth
  showing an Admin as ready: exactly one `{label}` placeholder
  (`split_template/0` succeeding), and its static part actually names a
  domain rather than being blank — a bare `"{label}"` template is
  syntactically fine for `enabled?/0`'s parsing purposes (see that
  function's own moduledoc on what "malformed" means there) but would
  render an app's hostname as the label alone, with no domain at all, which
  is not a configuration any real Operator would deploy. Requiring a dot
  keeps this stricter, console-facing signal from reading "well-formed" on
  a template that is really only valid in the narrow, parser sense.

  `false` covers "no template", "a template, but malformed", and this
  degenerate case alike — the console (#127) needs to tell "nothing set"
  apart from "something set that needs the Operator's attention", so pair
  this with `template/0` rather than reading this alone as "is it set".
  """
  def template_valid? do
    case split_template() do
      {prefix, suffix} -> String.contains?(prefix <> suffix, ".")
      nil -> false
    end
  end

  @doc "The canonical host: `YouWeb.Endpoint.host/0`, i.e. `PHX_HOST`."
  def canonical_host, do: YouWeb.Endpoint.host()

  @doc """
  Resolves `host` to `:canonical`, `{:app, app}`, or `:unknown`.

  Checked in that order: a host equal to the canonical host is always
  `:canonical`, even with the feature on — an Admin cannot accidentally
  shadow the instance's own front door by giving an app a colliding label,
  and `App.changeset/2` refuses that label at write time regardless (see
  `label_collides_with_canonical?/1`). Checking canonical first here is not
  cosmetic: it is the only defence left against a label that *became*
  colliding after being accepted — a template set later, or `PHX_HOST`
  itself renamed, can't have been checked against at write time, since
  `label_collides_with_canonical?/1` only ever runs then, against whatever
  the template was at that moment.
  """
  def resolve(host) when is_binary(host) do
    normalized = normalize(host)

    cond do
      normalized == normalize(canonical_host()) -> :canonical
      enabled?() -> resolve_app(normalized)
      true -> :unknown
    end
  end

  def resolve(_host), do: :unknown

  @doc "Whether `host` is one of You's own — canonical or a recognised app host."
  def own_host?(host), do: resolve(host) != :unknown

  @doc "Whether `host` is exactly the canonical host."
  def canonical?(host), do: resolve(host) == :canonical

  @doc """
  Every hostname a request-built link may point at: the canonical host, plus
  the rendered hostname of every app that has a `hostname_label` — empty
  when the feature is off or the template is unset. Configuration-derived,
  never from a request: `YouWeb.RequestURL.allowed_hosts/0` delegates here.
  """
  def hosts do
    [canonical_host() | app_hostnames()]
  end

  @doc """
  The `check_origin` predicate for `YouWeb.Endpoint`'s WebSocket transport,
  wired as `{You.Hosting, :check_origin?, []}`.

  Phoenix calls this with the parsed `Origin` header as a bare `%URI{}` (see
  `Phoenix.Socket.Transport`). Accepts only a host `resolve/1` recognises,
  and — same as Phoenix's own default `check_origin: true` — a scheme and
  port matching the endpoint's configured `:url`, when configured; an unset
  scheme or port in `:url` (as in `config/config.exs`) imposes no
  restriction on that dimension, exactly as Phoenix's own comparison does.
  """
  def check_origin?(%URI{host: host, scheme: scheme, port: port}) do
    own_host?(host) and url_matches?(:scheme, scheme) and url_matches?(:port, port)
  end

  @doc """
  Whether `label`, rendered through the configured template, produces the
  canonical host.

  Checked at write time (`App.changeset/2`) rather than only at resolution
  time: an Admin setting `hostname_label = "id"` while the canonical host is
  `id.example.com` would otherwise mint an app whose hostname *is* the
  instance's own front door — a takeover of canonical, not a naming
  collision. Computed from the *current* template rather than a hard-coded
  name, so a later template change cannot silently reopen the hole a stale
  list would leave.

  This is write-time only, though: a label accepted while no template was
  configured, or while `PHX_HOST` named a different host, is never
  re-checked. `resolve/1` checking canonical ahead of app resolution is
  what keeps that gap from becoming a live takeover — see its moduledoc.
  """
  def label_collides_with_canonical?(label) when is_binary(label) do
    case render_hostname(label) do
      nil -> false
      rendered -> normalize(rendered) == normalize(canonical_host())
    end
  end

  @doc """
  Splices `label` into the configured template, or `nil` when no template is
  configured. Used both to render an app's hostname and, in reverse
  (`parse_label/1`), to recover a label from a request host.
  """
  def render_hostname(label) when is_binary(label) do
    case split_template() do
      {prefix, suffix} -> prefix <> label <> suffix
      nil -> nil
    end
  end

  # -- Resolution internals

  defp resolve_app(host) do
    with label when is_binary(label) <- parse_label(host),
         true <- You.Hostname.valid?(label),
         %App{} = app <- Admin.get_app_by_hostname_label(label) do
      {:app, app}
    else
      _ -> :unknown
    end
  end

  defp parse_label(host) do
    with {prefix, suffix} <- split_template() do
      extract_label(host, prefix, suffix)
    end
  end

  defp extract_label(host, prefix, suffix) do
    plen = byte_size(prefix)
    slen = byte_size(suffix)
    hlen = byte_size(host)

    if hlen > plen + slen and
         binary_part(host, 0, plen) == prefix and
         binary_part(host, hlen - slen, slen) == suffix do
      label = binary_part(host, plen, hlen - plen - slen)
      if String.contains?(label, "."), do: nil, else: label
    end
  end

  # Exactly one `{label}` placeholder, and downcased before it's split —
  # `resolve/1` and `hosts/0` both compare or emit against a request host
  # that `normalize/1` has already downcased, so a template typed with any
  # uppercase (`{label}.Example.COM`) would otherwise agree with
  # `render_hostname/1` (used to build the emailed-link allowlist) while
  # disagreeing with `resolve/1` (used to decide whether the same host may
  # actually be branded) — exactly the split between "allowed to receive a
  # link" and "recognised for branding" this module exists to prevent.
  # Boot validates the raw `APP_HOSTNAME_TEMPLATE` too (`config/runtime.exs`)
  # so a malformed value is caught early with a real error message, but this
  # is what every caller here actually resolves and renders against, so it
  # normalizes and fails closed on its own rather than trusting that boot
  # check ran — `template/0` can also be set directly (tests do), bypassing
  # it entirely.
  defp split_template do
    case template() do
      nil ->
        nil

      raw ->
        case raw |> String.downcase() |> String.split("{label}", parts: 2) do
          [prefix, suffix] ->
            if String.contains?(suffix, "{label}"), do: nil, else: {prefix, suffix}

          _ ->
            nil
        end
    end
  end

  defp app_hostnames do
    if enabled?() do
      Admin.list_apps()
      |> Enum.filter(& &1.hostname_label)
      |> Enum.map(&render_hostname(&1.hostname_label))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp url_matches?(key, value) do
    allowed = (YouWeb.Endpoint.config(:url) || [])[key]
    is_nil(allowed) or to_string(value) == to_string(allowed)
  end

  defp normalize(nil), do: nil

  defp normalize(host) do
    host = String.downcase(host)
    if String.ends_with?(host, "."), do: binary_part(host, 0, byte_size(host) - 1), else: host
  end
end
