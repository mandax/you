# Auth code flow via redirect and Erlang distribution

You serves its own login UI (LiveView). Apps redirect users to You and receive a single-use authorization code back via redirect callback. Apps exchange that code for a JWT by calling `You.IAM.Server` over Erlang distribution, so no JWT ever appears in a URL.

This replaces the REST API approach (`POST /api/login`, etc.) because the REST endpoints become dead code once You owns the login UI.

## Considered Options

**JWT in the redirect URL**: simplest, but the JWT leaks through browser history, referrer headers, and server access logs. The JWT is a long-lived credential; an authorization code expires in 5 minutes and is a random opaque string.

**Full OAuth2 with token endpoint**: standard, but adds an HTTP token endpoint. Since You and apps already communicate via Erlang distribution for token validation, adding HTTP for the code exchange would introduce a second transport for no benefit.

**Authorization code exchange via Erlang distribution**: chosen. The code is a single-use random token (same pattern as magic links in `users_tokens`). Exchange happens through the existing `You.IAM.Server` GenServer, which apps already connect to. No JWT in URLs, no new HTTP endpoint, no `state` param needed (single-use codes mitigate CSRF).

## Consequences

- REST controllers (`ApiAuthController`, `JwksController`) and their routes become dead code: remove them.
- phx.gen.auth HTML controllers need a new LiveView overlay or replacement.
- `You.IAM.Server` gains a new message: `{:exchange_code, code}`.
- `You.SDK` gains a new function: `exchange_code(code)`.
- Authorization codes reuse the existing `users_tokens` table with `context: "oauth_code"`, so no migration needed.
