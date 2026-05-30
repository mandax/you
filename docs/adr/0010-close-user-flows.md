# Complete the app-directed signup, login, and password reset flows

A user arriving from an app at `you/login?callback_url=...&scope=...` must be able to sign up, log in, or reset their password and return to the app with an auth code — without losing the callback context.

## Decisions

**Registration preserves callback_url and scope.** The registration controller accepts `callback_url` and `scope` params, stores them in session, and embeds them as query params in the magic link confirmation URL. When the user clicks the link and confirms, the session is restored and You redirects to the app with an auth code.

**Forgot password is a portal page.** A new "Forgot password?" link on the login form leads to a single-field form (email). On submit, You sends a reset link. The reset link carries `callback_url` and `scope` so the user returns to the app after setting a new password. The flow matches phx.gen.auth's pattern but adds callback preservation.

**The login form shows signup and forgot-password links.** Three entry points are always visible: Log in (main form), Sign up (link to register), Forgot password? (link to reset). All preserve the callback context.

**Is this a gateway page, not a separate portal.** The login page at `/users/log-in` is already the gateway. Signup and reset are companion pages reachable from it. No separate "portal" concept is needed — the page and its companions form the complete entry point.

## Consequences

- `UserRegistrationController.new/2` and `create/2` accept callback params.
- `deliver_login_instructions` URL function embeds callback_url and scope as query params.
- A new `UserResetPasswordController` handles the forgot → reset flow.
- The login template gains a "Forgot password?" link.
- All flows tested end-to-end: register → confirm → redirect to app; login → redirect to app; reset → set password → redirect to app.
