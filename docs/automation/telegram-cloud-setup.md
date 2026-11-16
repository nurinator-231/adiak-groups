# ADIAK Telegram + Claude cloud automation

This integration is intentionally phone-operable after setup. Telegram is the control panel; GitHub Actions runs Claude in GitHub's hosted environment. No personal computer needs to stay online.

## Telegram commands

- `/feedback` — read the latest 10 new feedback records and create/reuse matching GitHub Issues.
- `/fix 15` — dispatch Claude for open GitHub Issue #15.
- `/status` — show the latest Claude workflow runs.
- `/prs` — list open pull requests.
- `/help` — show commands.

The existing `feedback-notify` function and its `tg_sent` behavior are not modified. Feedback-to-Issue synchronization happens when the owner sends `/feedback`; it uses a stable feedback-ID marker to reuse an existing Issue.

## Required secrets

### GitHub repository: Settings → Secrets and variables → Actions

Add these repository secrets:

| Secret | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude Code authentication for GitHub Actions. API usage is billed separately from a Claude Pro subscription. Do not add this secret unless the account owner approves the separate API billing. |
| `SUPABASE_ACCESS_TOKEN` | Allows the manually triggered deployment workflow to deploy the Edge Function. |
| `SUPABASE_PROJECT_REF` | Supabase project ref: `epenklutnevjvgpsjehp`. |
| `TELEGRAM_SETUP_SECRET` | Separate high-entropy secret used only by the deployment workflow to register the Telegram webhook. |

### Supabase project: Edge Functions → Secrets

Add:

| Secret | Purpose |
|---|---|
| `GITHUB_TOKEN` | Fine-grained token restricted to this repository. Grant Actions: Read and write; Issues: Read and write; Pull requests: Read-only. It is used to sync feedback Issues, dispatch the workflow, and read run/PR status. |
| `GITHUB_REPOSITORY` | `nurinator-231/adiak-groups` |
| `TELEGRAM_WEBHOOK_SECRET` | Random secret used by Telegram's webhook header. |
| `TELEGRAM_SETUP_SECRET` | Same value as the GitHub repository secret above. |

The existing `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` secrets are reused. Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions; never copy the service-role key into GitHub or source files.

## First deployment (manual, production-gated)

1. Merge the reviewed feature PR only after the owner approves it.
2. Add the required secrets listed above. Do not paste secret values into Telegram, Issues, PRs, or source files.
3. In GitHub Actions, open **Deploy Telegram control (manual approval only)**.
4. Select `main`, run the workflow, and set `confirm_production_deploy` to `true`. This explicit manual run deploys only `telegram-control` and registers its webhook.
5. Verify the workflow succeeds, then send `/help` to the bot in its private chat.

The function rejects group chats and messages from any private chat other than the configured `TELEGRAM_CHAT_ID`. The webhook itself is authenticated using Telegram's `X-Telegram-Bot-Api-Secret-Token` header. The setup endpoint uses a different secret.

## Claude execution and safety

- The workflow accepts only a positive Issue number and checks that the Issue is open and not a pull request.
- Claude reads `CLAUDE.md`, treats Issue content as untrusted input, and is instructed to create a draft PR targeting `main`.
- It must not merge, deploy, tag releases, run production migrations, or modify production Supabase state.
- The workflow is manually dispatched by the Telegram Edge Function; it does not poll Telegram or require a computer to remain online.
- Claude runs only after `ANTHROPIC_API_KEY` is configured. The API key is separate from Claude Pro billing; configure spending limits in the Anthropic account before enabling it.

## Important boundaries

- No production deployment occurs from a normal feedback or `/fix` command.
- The Edge Function deploy workflow is manual and requires the explicit boolean confirmation.
- The existing feedback notifier is left untouched.
- The feature branch is not merged automatically.
