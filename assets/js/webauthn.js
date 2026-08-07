// WebAuthn helpers — base64url encode/decode for binary WebAuthn fields.

// Convert an ArrayBuffer to a base64url-encoded string.
function arrayBufferToBase64Url(buf) {
  const bytes = new Uint8Array(buf)
  let binary = ""
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

// Convert a base64url-encoded string to an ArrayBuffer.
function base64UrlToArrayBuffer(str) {
  const raw = str.replace(/-/g, "+").replace(/_/g, "/")
  const padding = raw.length % 4 === 0 ? "" : "=".repeat(4 - (raw.length % 4))
  const binary = atob(raw + padding)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i)
  }
  return bytes.buffer
}

// Decode the server's base64url-encoded JSON options and convert all
// base64url-encoded values (challenge, user.id, credential ids) to ArrayBuffers
// before passing them to the WebAuthn API.
function prepareCreationOptions(options) {
  const pk = options.publicKey
  pk.challenge = base64UrlToArrayBuffer(pk.challenge)
  pk.user.id = base64UrlToArrayBuffer(pk.user.id)
  if (pk.excludeCredentials) {
    pk.excludeCredentials.forEach(c => { c.id = base64UrlToArrayBuffer(c.id) })
  }
  return pk
}

function prepareRequestOptions(options) {
  const pk = options.publicKey
  pk.challenge = base64UrlToArrayBuffer(pk.challenge)
  if (pk.allowCredentials) {
    pk.allowCredentials.forEach(c => { c.id = base64UrlToArrayBuffer(c.id) })
  }
  return pk
}

// Encode a PublicKeyCredential into a JSON-safe object with base64url-encoded
// binary fields.
function credentialToJson(cred) {
  const json = {
    id: cred.id,
    rawId: arrayBufferToBase64Url(cred.rawId),
    type: cred.type,
    response: {},
  }

  if (cred.response.attestationObject) {
    json.response.attestationObject = arrayBufferToBase64Url(cred.response.attestationObject)
  }
  if (cred.response.clientDataJSON) {
    json.response.clientDataJSON = arrayBufferToBase64Url(cred.response.clientDataJSON)
  }
  if (cred.response.authenticatorData) {
    json.response.authenticatorData = arrayBufferToBase64Url(cred.response.authenticatorData)
  }
  if (cred.response.signature) {
    json.response.signature = arrayBufferToBase64Url(cred.response.signature)
  }
  if (cred.response.userHandle) {
    json.response.userHandle = arrayBufferToBase64Url(cred.response.userHandle)
  }

  return json
}

// ── Registration ────────────────────────────────────

export async function registerPasskey(startUrl, finishUrl, csrfToken, label) {
  // 1. Fetch creation options from the server
  const startRes = await fetch(startUrl, {
    method: "POST",
    headers: {
      "X-CSRF-Token": csrfToken,
      "Accept": "application/json",
    },
  })
  if (!startRes.ok) {
    const err = await startRes.json().catch(() => ({}))
    throw new Error(err.error || `Failed to start registration: ${startRes.status}`)
  }
  const options = await startRes.json()

  // 2. Ask the authenticator to create a credential
  const cred = await navigator.credentials.create({
    publicKey: prepareCreationOptions(options),
  })
  if (!cred) throw new Error("User cancelled or authenticator returned no credential")

  // 3. Encode and POST the credential to the server for verification
  const body = credentialToJson(cred)
  if (label) body.label = label

  const finishRes = await fetch(finishUrl, {
    method: "POST",
    headers: {
      "X-CSRF-Token": csrfToken,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify(body),
  })
  if (!finishRes.ok) {
    const err = await finishRes.json().catch(() => ({}))
    throw new Error(err.error || `Registration failed: ${finishRes.status}`)
  }
  return await finishRes.json()
}

// ── Authentication ──────────────────────────────────

export async function authenticatePasskey(startUrl, finishUrl, email) {
  const csrfToken =
    document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

  // 1. Fetch authentication options from the server
  const body = email ? JSON.stringify({email}) : "{}"
  const startRes = await fetch(startUrl, {
    method: "POST",
    headers: {
      "X-CSRF-Token": csrfToken,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body,
  })
  if (!startRes.ok) {
    const err = await startRes.json().catch(() => ({}))
    throw new Error(err.error || `Failed to start authentication: ${startRes.status}`)
  }
  const options = await startRes.json()

  // 2. Ask the authenticator to sign the assertion
  const cred = await navigator.credentials.get({
    publicKey: prepareRequestOptions(options),
  })
  if (!cred) throw new Error("User cancelled authentication")

  // 3. Encode and POST the assertion to the server for verification
  const finishRes = await fetch(finishUrl, {
    method: "POST",
    headers: {
      "X-CSRF-Token": csrfToken,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify(credentialToJson(cred)),
  })

  if (finishRes.redirected) {
    // Successful authentication — the server redirected
    window.location.href = finishRes.url
    return
  }

  if (!finishRes.ok) {
    const err = await finishRes.json().catch(() => ({}))
    throw new Error(err.error || `Authentication failed: ${finishRes.status}`)
  }

  // Server returned JSON (e.g. for API login) — redirect manually
  const result = await finishRes.json()
  if (result.redirect) {
    window.location.href = result.redirect
  }
}
