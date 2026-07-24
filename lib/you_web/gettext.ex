defmodule YouWeb.Gettext do
  @moduledoc """
  Gettext backend for internationalization.
  """
  use Gettext.Backend, otp_app: :you
end
