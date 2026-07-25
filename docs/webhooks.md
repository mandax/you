# Webhooks — Outbound Events

You can push signed event notifications to any HTTPS endpoint you control.
Use it to wire signups into Stripe, mirror audit events into your own
logging, or trigger anything else that should react to identity events.

Create and manage endpoints in the console under **Webhooks**: URL,
subscribed events, enabled flag, and the signing secret (shown once, after
creation or rotation).

## Delivery format

Every delivery is a POST with a JSON body:

```json
{
  "id": "evt_Xk2mPq9Rt",
  "type": "user.registered",
  "created": "2026-07-25T05:03:52.100177Z",
  "data": {"user_id": 42, "email": "alice@example.com"}
}
```

And a signature header:

```
you-signature: t=1753415032,v1=9a205a759af962c682c571c3...
```

`v1` is the hex HMAC-SHA256 of `"<t>.<raw request body>"` keyed with your
endpoint's secret. Always verify it before acting on a delivery.

```elixir
[t, v1] =
  conn
  |> Plug.Conn.get_req_header("you-signature")
  |> hd()
  |> String.split(",")
  |> Enum.map(&String.trim_leading(&1, ["t=", "v1="]))

expected =
  :hmac
  |> :crypto.mac(:sha256, secret, "#{t}.#{raw_body}")
  |> Base.encode16(case: :lower)

Plug.Crypto.secure_compare(v1, expected)
```

With openssl:

```bash
echo -n "$T.$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex
```

Events subscribe per endpoint:

| Event | Payload `data` |
|-------|----------------|
| `user.registered` | `user_id`, `email` |
| `user.anonymized` | `user_id` |
| `login:attempt` | `user_id`, `email`, `result` |
| `login:totp` | `user_id`, `result` |
| `admin:action` | `admin_user_id`, `action`, `target` |
| `token:exchange` | `user_id`, `scopes` |
| `token:revoke` | `user_id`, `jti` |
| `token:refresh` | `user_id` |
| `account:update` | `user_id`, `action` |
| `consent:grant` / `consent:revoke` | `user_id`, `app_slug`, `scopes` |

## Delivery policy

- Endpoints are independent: one slow or failing endpoint never delays the
  others.
- Each delivery tries up to 3 times: immediately, after 2s, after 10s.
  Retries happen on 5xx and transport errors; 4xx is treated as final.
- 5 second response timeout. Deliveries are not persisted, so a restart
  drops in-flight retries. For durable audit shipping use the audit
  webhook under Settings, or poll `GET /api/v1/audit`.
- Respond 2xx fast and process asynchronously; treat `id` as an idempotency
  key.

Only register endpoints you control: deliveries originate from the server,
so an endpoint URL is a request You will make on your behalf.

## Recipe: Stripe customers on signup

1. Add an endpoint subscribed to `user.registered`, pointing at your app:
   `https://yourapp.example/hooks/you`.
2. In your handler: verify the signature, read `data.email` and
   `data.user_id`, then `Stripe.Customer.create(%{email: email, metadata: %{you_user_id: user_id}})`
   and store the returned customer id against your local user record.
3. Return 200. If Stripe is unreachable, return 500 and You retries twice
   more for you.
