gatekeeper-mcp fails against auth servers that require pre-registered OAuth clients (no support for a static client_id)

## Summary

Connecting `https://mcp.slack.com/mcp` through `gatekeeper-mcp` fails with a 502 and the following server-side error:

```
Error: Incompatible auth server: does not support dynamic client registration
    at async continueConnect (.../gatekeeper-mcp/.wrangler/tmp/.../mcp.js:15665:15)
```

Slack's MCP endpoint requires a pre-registered `client_id` (RFC 7591 dynamic client registration is not supported). The gatekeeper's OAuth client provider only ever reads back the result of dynamic registration — there's no way to configure a static, pre-registered client.

## Where I looked

`packages/mcp-shared/src/account.ts`, the `OAuthClientProvider` built in the connect flow:

```ts
return {
  redirectUrl: `${this.baseUrl()}/oauth`,
  clientMetadata: {
    client_name: clientName(this.env),
    redirect_uris: [`${this.baseUrl()}/oauth`],
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
  },
  clientInformation: context => {
    const client = this.ctx.storage.kv.get<StoredOAuthClientInformation>("oauthClient");
    ...
  },
  ...
};
```

`clientInformation` only ever returns a previously *stored* (i.e. dynamically registered) client. There's no code path that reads a pre-provisioned `client_id`/`client_secret` from env, so any auth server without dynamic client registration is unreachable — regardless of endpoint.

For reference, the official Slack Skills plugin ships a fixed client_id for exactly this reason:

```json
{ "mcpServers": { "slack": { "url": "https://mcp.slack.com/mcp",
  "oauth": { "clientId": "1601185624273.8899143856786", "callbackPort": 3118 } } } }
```

## Impact

Since `gatekeeper-mcp`'s pitch is "One Worker covers every MCP server, so a server needs no Gadgets-specific work to be usable from a Gadget" (README), this silently breaks that promise for any server behind a pre-registration-only auth server — which includes at least Slack's official MCP server.

## Suggested fix

Allow a per-connection (or per-deployment) static `client_id` / `client_secret` to be supplied — e.g. via an env var keyed by host, similar to how `SHARED_GATEKEEPER_CREDS` seeds OAuth app credentials for the other gatekeepers in `run-dev-server.js`. When present, `clientInformation` should return it directly and skip dynamic registration.

## Repro

1. Configure `gatekeeper-mcp` locally (no extra env needed per the README).
2. Connect `https://mcp.slack.com/mcp` as a new MCP server resource.
3. Observe `connect.failed` in the gatekeeper logs with the error above, and a 502 on the connect request.
