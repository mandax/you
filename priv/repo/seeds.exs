# Populates the database with a realistic demo dataset: users, apps,
# organizations, role assignments, passkeys, federated identities, consents,
# webhook endpoints and instance settings.
#
#     mix run priv/repo/seeds.exs
#
# Idempotent-ish: reruns add nothing new for records keyed by a unique field
# (emails, app slugs, org slugs), but it is meant for a fresh dev database.

import Ecto.Query

alias You.Accounts.{Consent, FederatedIdentity, Passkey, User}
alias You.Admin
alias You.Admin.App
alias You.Organizations
alias You.Repo
alias You.Roles
alias You.Settings
alias You.Webhooks

:rand.seed(:exsss, {42, 42, 42})

now = DateTime.utc_now() |> DateTime.truncate(:second)
ago = fn days -> DateTime.add(now, -days * 86_400, :second) end

# One bcrypt round for the whole seed: hashing 60 passwords individually takes
# minutes and every demo account shares the same password anyway.
demo_hash = Bcrypt.hash_pwd_salt("demopassword123")

IO.puts("→ admin")
{:ok, admin} = Admin.bootstrap_admin("admin@you.dev", "demopassword123")

# ── users ──────────────────────────────────────────────────────────────
IO.puts("→ users")

people = [
  {"Ada Lovelace", "ada.lovelace", "you.dev"},
  {"Alan Turing", "alan.turing", "you.dev"},
  {"Grace Hopper", "grace.hopper", "you.dev"},
  {"Joan Clarke", "joan.clarke", "you.dev"},
  {"Katherine Johnson", "katherine.johnson", "you.dev"},
  {"Margaret Hamilton", "margaret.hamilton", "you.dev"},
  {"Barbara Liskov", "barbara.liskov", "northwind.io"},
  {"Radia Perlman", "radia.perlman", "northwind.io"},
  {"Leslie Lamport", "leslie.lamport", "northwind.io"},
  {"Edsger Dijkstra", "edsger.dijkstra", "northwind.io"},
  {"Tony Hoare", "tony.hoare", "northwind.io"},
  {"Robin Milner", "robin.milner", "northwind.io"},
  {"Frances Allen", "frances.allen", "acme-labs.com"},
  {"Jean Bartik", "jean.bartik", "acme-labs.com"},
  {"Mary Wilkes", "mary.wilkes", "acme-labs.com"},
  {"Evelyn Boyd", "evelyn.boyd", "acme-labs.com"},
  {"Annie Easley", "annie.easley", "acme-labs.com"},
  {"Dorothy Vaughan", "dorothy.vaughan", "acme-labs.com"},
  {"Shafi Goldwasser", "shafi.goldwasser", "meridian.co"},
  {"Cynthia Dwork", "cynthia.dwork", "meridian.co"},
  {"Silvio Micali", "silvio.micali", "meridian.co"},
  {"Whitfield Diffie", "whit.diffie", "meridian.co"},
  {"Martin Hellman", "martin.hellman", "meridian.co"},
  {"Ralph Merkle", "ralph.merkle", "meridian.co"},
  {"Ron Rivest", "ron.rivest", "kestrel.dev"},
  {"Adi Shamir", "adi.shamir", "kestrel.dev"},
  {"Len Adleman", "len.adleman", "kestrel.dev"},
  {"Taher Elgamal", "taher.elgamal", "kestrel.dev"},
  {"Bruce Schneier", "bruce.schneier", "kestrel.dev"},
  {"Daniel Bernstein", "dj.bernstein", "kestrel.dev"},
  {"Joe Armstrong", "joe.armstrong", "beamworks.net"},
  {"Robert Virding", "robert.virding", "beamworks.net"},
  {"Mike Williams", "mike.williams", "beamworks.net"},
  {"José Valim", "jose.valim", "beamworks.net"},
  {"Chris McCord", "chris.mccord", "beamworks.net"},
  {"Saša Jurić", "sasa.juric", "beamworks.net"},
  {"Fred Hebert", "fred.hebert", "beamworks.net"},
  {"Ulf Wiger", "ulf.wiger", "beamworks.net"},
  {"Linus Torvalds", "linus.torvalds", "harbor-tech.com"},
  {"Ken Thompson", "ken.thompson", "harbor-tech.com"},
  {"Dennis Ritchie", "dennis.ritchie", "harbor-tech.com"},
  {"Rob Pike", "rob.pike", "harbor-tech.com"},
  {"Brian Kernighan", "brian.kernighan", "harbor-tech.com"},
  {"Doug McIlroy", "doug.mcilroy", "harbor-tech.com"},
  {"Guido van Rossum", "guido.vanrossum", "orbital.studio"},
  {"Yukihiro Matsumoto", "yukihiro.matsumoto", "orbital.studio"},
  {"Anders Hejlsberg", "anders.hejlsberg", "orbital.studio"},
  {"Bjarne Stroustrup", "bjarne.stroustrup", "orbital.studio"},
  {"Rich Hickey", "rich.hickey", "orbital.studio"},
  {"Simon Marlow", "simon.marlow", "orbital.studio"},
  {"Philip Wadler", "philip.wadler", "lumen-io.dev"},
  {"Simon Peyton Jones", "simon.peytonjones", "lumen-io.dev"},
  {"Xavier Leroy", "xavier.leroy", "lumen-io.dev"},
  {"Benjamin Pierce", "ben.pierce", "lumen-io.dev"},
  {"Robert Harper", "robert.harper", "lumen-io.dev"},
  {"Conor McBride", "conor.mcbride", "lumen-io.dev"},
  {"Nancy Lynch", "nancy.lynch", "vertex-cloud.com"},
  {"Maurice Herlihy", "maurice.herlihy", "vertex-cloud.com"},
  {"Eric Brewer", "eric.brewer", "vertex-cloud.com"},
  {"Werner Vogels", "werner.vogels", "vertex-cloud.com"},
  {"Jeff Dean", "jeff.dean", "vertex-cloud.com"},
  {"Sanjay Ghemawat", "sanjay.ghemawat", "vertex-cloud.com"}
]

user_rows =
  people
  |> Enum.with_index()
  |> Enum.map(fn {{_name, handle, domain}, i} ->
    inserted = ago.(rem(i * 7, 210) + 3)

    # Roughly one in nine accounts is still waiting on confirmation, and the
    # unconfirmed ones are the recent signups.
    confirmed? = rem(i, 9) != 4

    %{
      email: "#{handle}@#{domain}",
      hashed_password: demo_hash,
      confirmed_at: if(confirmed?, do: DateTime.add(inserted, 3600, :second)),
      totp_enabled: rem(i, 5) == 0,
      totp_secret: if(rem(i, 5) == 0, do: NimbleTOTP.secret() |> Base.encode32(padding: false)),
      email_2fa_enabled: rem(i, 11) == 3,
      is_admin: handle in ["grace.hopper", "jose.valim", "nancy.lynch"],
      inserted_at: inserted,
      updated_at: inserted
    }
  end)

Repo.insert_all(User, user_rows, on_conflict: :nothing)
users = Repo.all(from u in User, where: u.email != ^admin.email, order_by: u.id)
IO.puts("  #{length(users)} users + 1 bootstrap admin")

# ── apps ───────────────────────────────────────────────────────────────
IO.puts("→ apps")

app_specs = [
  {"Console", "console", "https://console.you.dev/auth/callback", "https://console.you.dev",
   "#7c3aed", ~w(user admin owner), true},
  {"Northwind CRM", "northwind-crm", "https://crm.northwind.io/oauth/callback",
   "https://crm.northwind.io", "#0ea5e9", ~w(user manager admin), false},
  {"Meridian Billing", "meridian-billing", "https://billing.meridian.co/session/callback",
   "https://billing.meridian.co", "#22c55e", ~w(user finance admin), false},
  {"Kestrel Vault", "kestrel-vault", "https://vault.kestrel.dev/callback",
   "https://vault.kestrel.dev", "#f97316", ~w(user auditor admin), false},
  {"Harbor Deploy", "harbor-deploy", "https://deploy.harbor-tech.com/oidc/callback",
   "https://deploy.harbor-tech.com", "#ef4444", ~w(user operator admin), true},
  {"Orbital Docs", "orbital-docs", "https://docs.orbital.studio/auth", nil, "#eab308",
   ~w(user editor admin), false},
  {"Lumen Analytics", "lumen-analytics", "https://analytics.lumen-io.dev/callback",
   "https://analytics.lumen-io.dev", "#14b8a6", ~w(user analyst admin), false}
]

apps =
  Enum.map(app_specs, fn {name, slug, callback, launch, color, roles, first_party} ->
    case Repo.get_by(App, slug: slug) do
      nil ->
        {:ok, app, _secret} =
          Admin.create_app(%{
            "name" => name,
            "slug" => slug,
            "callback_url" => callback,
            "launch_url" => launch,
            "brand_color" => color,
            "allowed_roles" => roles,
            "first_party" => first_party
          })

        app

      existing ->
        existing
    end
  end)

IO.puts("  #{length(apps)} apps")

# ── organizations + memberships ────────────────────────────────────────
IO.puts("→ organizations")

org_specs = [
  {"Northwind Trading", "northwind"},
  {"Acme Labs", "acme-labs"},
  {"Meridian Financial", "meridian"},
  {"Kestrel Security", "kestrel"},
  {"BEAM Works", "beamworks"},
  {"Harbor Technologies", "harbor-tech"},
  {"Orbital Studio", "orbital"},
  {"Lumen IO", "lumen-io"},
  {"Vertex Cloud", "vertex-cloud"}
]

orgs =
  Enum.map(org_specs, fn {name, slug} ->
    case Repo.get_by(You.Organizations.Organization, slug: slug) do
      nil ->
        {:ok, org} = Organizations.create_organization(%{"name" => name, "slug" => slug})
        org

      existing ->
        existing
    end
  end)

# Members are drawn from the email domain when it matches an org slug, so the
# memberships line up with the user list; everyone else lands in Acme Labs.
by_slug = Map.new(orgs, &{&1.slug, &1})

# Memberships are uniquely indexed on (org, user): on a rerun, set the role
# instead of failing the insert.
ensure_member = fn org, user, role ->
  case Organizations.add_member(org, user, role) do
    {:ok, membership} -> membership
    {:error, _} -> Organizations.update_member_role(org, user, role)
  end
end

Enum.each(users, fn user ->
  [_, domain] = String.split(user.email, "@")
  slug = domain |> String.replace(".com", "") |> String.replace(~r/\.(io|dev|co|net|studio)$/, "")

  org = Map.get(by_slug, slug, by_slug["acme-labs"])

  role =
    cond do
      user.is_admin -> "owner"
      rem(user.id, 4) == 0 -> "admin"
      true -> "member"
    end

  ensure_member.(org, user, role)
end)

ensure_member.(by_slug["northwind"], admin, "owner")

IO.puts(
  "  #{length(orgs)} orgs, #{Repo.aggregate(You.Organizations.Membership, :count)} memberships"
)

# ── app role assignments ───────────────────────────────────────────────
IO.puts("→ role assignments")

assignment_count =
  for app <- apps, user <- users, rem(user.id + app.id, 3) != 0, reduce: 0 do
    acc ->
      role =
        cond do
          user.is_admin -> "admin"
          rem(user.id + app.id, 7) == 1 -> Enum.at(app.allowed_roles, 1, "user")
          rem(user.id + app.id, 11) == 5 -> "admin"
          true -> "user"
        end

      case Roles.set_role(app, user, role) do
        {:ok, _} -> acc + 1
        _ -> acc
      end
  end

Enum.each(apps, &Roles.set_role(&1, admin, "admin"))
IO.puts("  #{assignment_count} assignments")

# ── passkeys, federated identities, consents ───────────────────────────
IO.puts("→ credentials")

passkey_rows =
  users
  |> Enum.filter(&(rem(&1.id, 3) == 0))
  |> Enum.flat_map(fn user ->
    labels = if rem(user.id, 6) == 0, do: ["MacBook Pro", "iPhone"], else: ["YubiKey 5C"]

    Enum.map(labels, fn label ->
      %{
        user_id: user.id,
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: :crypto.strong_rand_bytes(64),
        sign_count: :rand.uniform(400),
        label: label,
        aaguid: :crypto.strong_rand_bytes(16),
        inserted_at: ago.(:rand.uniform(120)),
        updated_at: now
      }
    end)
  end)

Repo.insert_all(Passkey, passkey_rows, on_conflict: :nothing)

identity_rows =
  users
  |> Enum.filter(&(rem(&1.id, 4) in [1, 2]))
  |> Enum.map(fn user ->
    provider = Enum.at(~w(google github gitlab microsoft), rem(user.id, 4))

    %{
      user_id: user.id,
      provider: provider,
      subject: "#{provider}|#{:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)}",
      email: user.email,
      inserted_at: ago.(:rand.uniform(150)),
      updated_at: now
    }
  end)

Repo.insert_all(FederatedIdentity, identity_rows, on_conflict: :nothing)

consent_rows =
  for user <- users, app <- apps, rem(user.id * 3 + app.id, 5) == 0 do
    granted = ago.(:rand.uniform(90))

    %{
      user_id: user.id,
      app_id: app.id,
      scopes: Enum.take(~w(openid profile email roles offline_access), 2 + rem(app.id, 3)),
      granted_at: granted,
      expires_at: DateTime.add(granted, 365 * 86_400, :second),
      # `consents` keeps naive timestamps, unlike the other schemas here.
      inserted_at: DateTime.to_naive(granted),
      updated_at: DateTime.to_naive(granted)
    }
  end

Repo.insert_all(Consent, consent_rows, on_conflict: :nothing)

IO.puts(
  "  #{length(passkey_rows)} passkeys, #{length(identity_rows)} federated identities, " <>
    "#{length(consent_rows)} consents"
)

# ── webhook endpoints ──────────────────────────────────────────────────
IO.puts("→ webhooks")

all_events = Webhooks.events()

webhook_specs = [
  {"https://hooks.northwind.io/you/audit", all_events, true},
  {"https://siem.kestrel.dev/ingest/you", ~w(login:attempt login:totp admin:action), true},
  {"https://api.meridian.co/webhooks/identity", ~w(user.registered user.anonymized), true},
  {"https://ops.harbor-tech.com/you-events", ~w(token:exchange token:revoke token:refresh),
   false},
  {"https://hooks.slack-relay.orbital.studio/identity", ~w(consent:grant consent:revoke), true}
]

Enum.each(webhook_specs, fn {url, events, enabled} ->
  unless Repo.get_by(You.Webhooks.Endpoint, url: url) do
    {:ok, _} =
      Webhooks.create_endpoint(%{
        "url" => url,
        "events" => events,
        "enabled" => enabled
      })
  end
end)

IO.puts("  #{length(Webhooks.list_endpoints())} endpoints")

# ── instance settings ──────────────────────────────────────────────────
IO.puts("→ settings")

Settings.set(:session_expiry_hours, 12)
Settings.set(:jwt_expiry_hours, 1)
Settings.set(:code_expiry_minutes, 5)
Settings.set(:magic_link_expiry_minutes, 20)
Settings.set(:erlang_node_name, "you@identity.internal")
Settings.set(:epmd_port, 4369)
Settings.set(:audit_webhook_url, "")

IO.puts("""

Seed complete.

  users ........... #{Repo.aggregate(User, :count)}
  apps ............ #{Repo.aggregate(App, :count)}
  organizations ... #{Repo.aggregate(You.Organizations.Organization, :count)}
  assignments ..... #{Repo.aggregate(You.Roles.Assignment, :count)}
  webhooks ........ #{Repo.aggregate(You.Webhooks.Endpoint, :count)}

Log in at /users/log-in with admin@you.dev / demopassword123
""")
