defmodule You.IdentityProviders.Setup do
  @moduledoc """
  Where an admin gets a client id and secret for each preset.

  Taken from each vendor's own current documentation, not from memory — several
  of these consoles were reorganised recently enough that older tutorials send
  you hunting for menus that no longer exist. Each entry carries the source it
  came from so it can be rechecked when a console changes again.

  `caveat` is for the thing that will waste someone's afternoon: a secret shown
  once, a scope that must be requested separately, or a flow You cannot yet
  support.
  """

  @setup %{
    "google" => %{
      source: "https://developers.google.com/workspace/guides/create-credentials",
      redirect_field: "Authorized redirect URIs",
      scopes: "No product to enable — openid, email and profile are available by default.",
      caveat:
        "The console was reorganised: the old \"OAuth consent screen\" and \"Credentials\" pages are now Google Auth Platform, with Branding, Audience and Clients tabs. Tutorials older than 2024 describe menus that no longer exist.",
      steps: [
        "Open Google Cloud Console and select or create a project.",
        "Go to Google Auth Platform → Branding, set the app name and support email.",
        "Go to Google Auth Platform → Audience and add test users if the app is unpublished.",
        "Go to Google Auth Platform → Clients and click Create Client.",
        "Choose application type Web application and name it.",
        "Under Authorized redirect URIs, click Add URI and paste the callback URL below.",
        "Click Create, then copy the Client ID and Client secret."
      ]
    },
    "microsoft" => %{
      source: "https://learn.microsoft.com/en-us/entra/identity-platform/how-to-add-credentials",
      redirect_field: "Redirect URI (Authentication blade, platform type Web)",
      scopes:
        "No product to enable — openid, profile and email are default delegated permissions.",
      caveat:
        "The secret Value is shown once and never again, and secrets expire after at most 24 months. Diarise the rotation: an expired secret fails silently at login.",
      steps: [
        "In the Microsoft Entra admin center, open App registrations and register or select your app.",
        "Open Authentication, add a platform, choose Web, and enter the redirect URI.",
        "Open Certificates & secrets → Client secrets → New client secret.",
        "Add a description and pick an expiry (24 months maximum).",
        "Click Add and copy the secret's Value immediately.",
        "Copy the Application (client) ID from the app's Overview page."
      ]
    },
    "github" => %{
      source:
        "https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app",
      redirect_field: "Authorization callback URL",
      scopes: "Requested per authorization: read:user and user:email.",
      caveat:
        "An OAuth App, not a GitHub App — they are different things in the same menu. Only one callback URL is allowed, and the secret is shown once.",
      steps: [
        "Go to Settings → Developer settings → OAuth Apps → New OAuth App.",
        "Fill in the application name and homepage URL.",
        "Paste the callback URL into Authorization callback URL.",
        "Click Register application.",
        "Click Generate a new client secret.",
        "Copy the Client ID and the secret."
      ]
    },
    "gitlab" => %{
      source: "https://docs.gitlab.com/integration/oauth_provider/",
      redirect_field: "Redirect URI",
      scopes: "Tick openid when creating the application, or OpenID Connect will not work.",
      caveat:
        "gitlab.com supports user-owned and group-owned applications only; instance-wide ones need self-managed GitLab. Rotate with Renew secret.",
      steps: [
        "Sign in to GitLab and open Edit profile, or a group's Settings for a group-owned app.",
        "In the sidebar choose Access → Applications.",
        "Click Add new application.",
        "Enter a name and the redirect URI.",
        "Under Scopes, tick openid plus anything else you need.",
        "Save, then copy the Application ID and the Secret."
      ]
    },
    "discord" => %{
      source: "https://docs.discord.com/developers/topics/oauth2",
      redirect_field: "Redirects",
      scopes: "identify for the profile, and email — without it Discord returns no address.",
      caveat:
        "You needs an email address to create an account, so the email scope is not optional here. The secret is only revealed when you reset it.",
      steps: [
        "In the Discord Developer Portal, click New Application, name it, and create it.",
        "Open OAuth2 → General.",
        "Under Redirects, click Add Redirect, paste the callback URL, and save.",
        "Copy the Client ID from Client Information.",
        "Click Reset Secret, confirm, and copy the secret."
      ]
    },
    "linkedin" => %{
      source:
        "https://learn.microsoft.com/en-us/linkedin/consumer/integrations/self-serve/sign-in-with-linkedin-v2",
      redirect_field: "Authorized redirect URLs for your app",
      scopes: "Request the product \"Sign In with LinkedIn using OpenID Connect\" first.",
      caveat:
        "Without that product the openid, profile and email scopes are simply refused. It replaced the older r_liteprofile and r_emailaddress scopes — tutorials naming those are out of date.",
      steps: [
        "Create or select an app at linkedin.com/developers/apps.",
        "In the Products tab, request Sign In with LinkedIn using OpenID Connect.",
        "Open the Auth tab and note the Client ID and Client Secret.",
        "Next to Authorized redirect URLs, click the pencil icon.",
        "Add the callback URL and click Update."
      ]
    },
    "twitch" => %{
      source: "https://dev.twitch.tv/docs/authentication/register-app/",
      redirect_field: "OAuth Redirect URLs",
      scopes: "Requested per authorization: user:read:email for the address.",
      caveat:
        "Your Twitch account needs two-factor authentication before it can register an app at all, and Client Type must be Confidential for a server-side flow.",
      steps: [
        "Enable two-factor authentication on your Twitch account.",
        "At dev.twitch.tv/console/apps, click Register Your Application.",
        "Name it, and add the callback URL under OAuth Redirect URLs.",
        "Pick a category and set Client Type to Confidential.",
        "Complete the CAPTCHA and click Create.",
        "Open the app, click Manage, copy the Client ID, then click New Secret."
      ]
    },
    "slack" => %{
      source: "https://docs.slack.dev/authentication/sign-in-with-slack/",
      redirect_field: "Redirect URLs (under OAuth & Permissions)",
      scopes: "openid, email and profile — the OIDC scopes, not bot or user token scopes.",
      caveat:
        "Slack keeps Sign in with Slack scopes separate from the classic Bot and User Token scopes. Adding the wrong kind yields no ID token and the flow fails with no obvious cause.",
      steps: [
        "Create an app at api.slack.com/apps and pick a workspace.",
        "Open OAuth & Permissions.",
        "Under Redirect URLs, add the callback URL and save.",
        "Add the openid, email and profile scopes for Sign in with Slack.",
        "Open Basic Information and copy the Client ID and Client Secret.",
        "Install the app to the workspace to activate the flow."
      ]
    }
  }

  @doc """
  Setup guidance for a preset, or `nil` for one with none (the generic OIDC
  preset, where the endpoints come from the admin's own issuer).
  """
  def for_preset(name) when is_binary(name), do: Map.get(@setup, name)
  def for_preset(_), do: nil

  @doc "Preset names that carry setup guidance."
  def documented, do: Map.keys(@setup)
end
