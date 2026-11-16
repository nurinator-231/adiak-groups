import { createClient } from "npm:@supabase/supabase-js@2";
import {
  escapeHtml, feedbackIssueBody, feedbackIssueTitle, feedbackMarker,
  isAuthorizedPrivateMessage, parseCommand, safeEqual,
  type FeedbackRow, type TelegramUpdate,
} from "./lib.ts";

const env = (name: string) => Deno.env.get(name) || "";
const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_ROLE = env("SUPABASE_SERVICE_ROLE_KEY");
const BOT_TOKEN = env("TELEGRAM_BOT_TOKEN");
const CHAT_ID = env("TELEGRAM_CHAT_ID");
const WEBHOOK_SECRET = env("TELEGRAM_WEBHOOK_SECRET");
const GITHUB_TOKEN = env("GITHUB_TOKEN");
const GITHUB_REPOSITORY = env("GITHUB_REPOSITORY");
const WORKFLOW_FILE = "telegram-claude-fix.yml";
const db = SUPABASE_URL && SERVICE_ROLE ? createClient(SUPABASE_URL, SERVICE_ROLE) : null;

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json; charset=utf-8" },
});

async function telegram(method: string, payload: Record<string, unknown>) {
  const response = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/${method}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok || !result.ok) throw new Error(`Telegram ${method} failed (${response.status})`);
  return result;
}

async function reply(chatId: number | string, text: string) {
  return telegram("sendMessage", { chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: true });
}

async function github(path: string, init: RequestInit = {}) {
  const response = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "content-type": "application/json",
      ...(init.headers || {}),
    },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`GitHub API failed (${response.status})`);
  return body;
}

function repoPath(path: string) {
  return `/repos/${GITHUB_REPOSITORY}${path}`;
}

async function syncFeedback(): Promise<string> {
  if (!db) throw new Error("Supabase is not configured");
  const { data, error } = await db.from("feedback")
    .select("id,body,class_tag,created_at")
    .eq("status", "new")
    .order("created_at", { ascending: false })
    .limit(10);
  if (error) throw new Error("Could not read feedback");
  const rows = (data || []) as FeedbackRow[];
  if (!rows.length) return "Hazırda yeni feedback yoxdur.";

  const existing = await github(repoPath("/issues?state=all&per_page=100"));
  const issues = Array.isArray(existing) ? existing : [];
  const output: string[] = [];
  for (const row of rows) {
    const marker = feedbackMarker(row.id);
    let issue = issues.find((item: { body?: string | null; number?: number; html_url?: string }) => item.body?.includes(marker));
    if (!issue) {
      issue = await github(repoPath("/issues"), {
        method: "POST",
        body: JSON.stringify({
          title: feedbackIssueTitle(row),
          body: feedbackIssueBody(row),
          labels: ["user-feedback"],
        }),
      });
      issues.unshift(issue);
    }
    output.push(`#${issue.number} — <a href="${issue.html_url}">GitHub Issue</a>`);
  }
  return `<b>Yeni feedback-lər (${rows.length})</b>\n${output.join("\n")}\n\nDüzəliş başlatmaq üçün: <code>/fix ISSUE_NUMBER</code>`;
}

async function startFix(issueNumber: number): Promise<string> {
  const issue = await github(repoPath(`/issues/${issueNumber}`));
  if (issue.pull_request || issue.state !== "open") {
    return `#${issueNumber} açıq Issue deyil. Yalnız açıq GitHub Issue-ları Claude-a göndərmək olar.`;
  }
  await github(repoPath(`/actions/workflows/${WORKFLOW_FILE}/dispatches`), {
    method: "POST",
    body: JSON.stringify({ ref: "main", inputs: { issue_number: String(issueNumber) } }),
  });
  return `<b>Claude işi qəbul etdi.</b>\nIssue: <a href="${issue.html_url}">#${issueNumber} — ${escapeHtml(issue.title || "")}</a>\nNəticə hazır olanda PR GitHub-da açılacaq. Merge və deploy avtomatik edilməyəcək.`;
}

async function status(): Promise<string> {
  const result = await github(repoPath(`/actions/workflows/${WORKFLOW_FILE}/runs?per_page=5`));
  const runs = Array.isArray(result.workflow_runs) ? result.workflow_runs : [];
  if (!runs.length) return "Hələ Claude workflow işə düşməyib.";
  return "<b>Son Claude işləri</b>\n" + runs.map((run: { display_title?: string; status?: string; conclusion?: string | null; html_url?: string }) =>
    `• <a href="${run.html_url}">${escapeHtml(run.display_title || "Claude run")}</a> — ${escapeHtml(run.status || "")}${run.conclusion ? " / " + escapeHtml(run.conclusion) : ""}`
  ).join("\n");
}

async function openPullRequests(): Promise<string> {
  const prs = await github(repoPath("/pulls?state=open&per_page=10"));
  if (!Array.isArray(prs) || !prs.length) return "Açıq PR yoxdur.";
  return "<b>Açıq Pull Request-lər</b>\n" + prs.map((pr: { number: number; title: string; html_url: string }) =>
    `• <a href="${pr.html_url}">#${pr.number} — ${escapeHtml(pr.title)}</a>`
  ).join("\n");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  if (!WEBHOOK_SECRET || !safeEqual(req.headers.get("x-telegram-bot-api-secret-token") || "", WEBHOOK_SECRET)) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }
  if (!BOT_TOKEN || !CHAT_ID || !GITHUB_TOKEN || !GITHUB_REPOSITORY || !db) {
    return json({ ok: false, error: "server_not_configured" }, 503);
  }

  const update = await req.json().catch(() => null) as TelegramUpdate | null;
  if (!update || !isAuthorizedPrivateMessage(update, CHAT_ID)) return json({ ok: true, ignored: true });
  const message = update.message!;
  const chatId = message.chat!.id!;
  const command = parseCommand(message.text || "");
  if (!command) {
    if ((message.text || "").trim().startsWith("/")) await reply(chatId, "Əmri başa düşmədim. Kömək üçün <code>/help</code> yaz.");
    return json({ ok: true, ignored: true });
  }

  try {
    let answer = "";
    if (command.command === "feedback") answer = await syncFeedback();
    else if (command.command === "fix") answer = await startFix(command.issueNumber!);
    else if (command.command === "status") answer = await status();
    else if (command.command === "prs") answer = await openPullRequests();
    else answer = "<b>ADIAK idarəetmə</b>\n<code>/feedback</code> — yeni feedback-ləri GitHub Issue-larına sinxronlaşdır\n<code>/fix 15</code> — Issue #15 üçün Claude-u işə sal\n<code>/status</code> — son Claude işlərinin vəziyyəti\n<code>/prs</code> — açıq PR-lər";
    await reply(chatId, answer);
    return json({ ok: true });
  } catch (error) {
    console.error("telegram-control:", String(error));
    await reply(chatId, "Əməliyyat alınmadı. GitHub/Supabase konfiqurasiyasını və workflow icazələrini yoxlamaq lazımdır.");
    return json({ ok: false, error: "operation_failed" }, 502);
  }
});
