---
name: inbox-zero-send-email
description: >
  Send an email via the inbox-zero project's Gmail integration.
  Use when the user says "send an email", "email someone", "compose and send", or invokes /inbox-zero-send-email.
  Requires: recipient (--to), subject (--subject), body (--body). From-email defaults to chou.amen@gmail.com.
---

# inbox-zero-send-email

Send an outbound email using the inbox-zero Gmail client (OAuth tokens stored in the local Postgres DB).

## Script

```
/Users/haimengzhou/apps/inbox-zero/apps/web/scripts/sendEmail.ts
```

Run from `apps/web`:

```bash
cd /Users/haimengzhou/apps/inbox-zero/apps/web && \
  NODE_ENV=production npx tsx -r ./scripts/stub-server-only.cjs scripts/sendEmail.ts \
  <from-email> \
  --to "<recipient>" \
  --subject "<subject>" \
  --body "<body>" \
  [--cc "<cc>"] \
  [--bcc "<bcc>"]
```

## Default from-email

Always use `chou.amen@gmail.com` unless the user specifies otherwise.

## Steps

1. **Collect parameters** from the user's message:
   - `--to` — required; recipient address(es), comma-separated for multiple
   - `--subject` — required
   - `--body` — required; plain text
   - `--cc` / `--bcc` — optional

2. **Confirm before sending** — show the user a summary of the email (to, subject, body preview) and ask for confirmation before running the command.

3. **Run the script** once confirmed.

4. **Report result** — confirm success or surface the error message.

## Error cases

| Error | Fix |
|-------|-----|
| "Email account not found in DB" | The from-email has no row in `emailAccount` table — the account hasn't been authenticated via the inbox-zero web app |
| "Missing Gmail tokens" | OAuth tokens expired and couldn't be refreshed — re-authenticate via the web app |
