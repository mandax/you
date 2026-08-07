defmodule You.Hostname do
  @moduledoc """
  The DNS-label rule `hostname_label` is constrained by.

  A single label, not a hostname: `You.Hosting` builds the full app hostname
  by splicing this label into the configured template
  (`{label}.example.com`), so the label itself only ever needs to be valid as
  the one segment it fills in — `[a-z0-9]`, interior hyphens allowed, no
  leading or trailing hyphen, no dot, no underscore. Kept apart from
  `You.Admin.App`'s slug rules (#119) on purpose: the slug is the OAuth
  `client_id` and has its own, looser format (`[a-z0-9_-]+`, underscores
  allowed, no DNS constraint) — see `You.Admin.App` for why the two must not
  merge.
  """

  @label ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  @max_length 63

  @doc "The longest a single DNS label may be."
  def max_length, do: @max_length

  @doc """
  Whether `label` is a well-formed single DNS label.

  Case-sensitive on purpose — callers normalize (downcase) before storing or
  comparing, same as `You.WebAuthn.available_for_host?/1` and
  `YouWeb.RequestURL` do for full hostnames, so this only ever sees the
  canonical lowercase form.
  """
  def valid?(label) when is_binary(label) do
    byte_size(label) in 1..@max_length and Regex.match?(@label, label)
  end

  def valid?(_label), do: false
end
