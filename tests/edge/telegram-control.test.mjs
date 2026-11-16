import {
  escapeHtml, feedbackIssueBody, feedbackIssueTitle, feedbackMarker,
  isAuthorizedPrivateMessage, parseCommand, safeEqual,
} from "../../supabase/functions/telegram-control/lib.ts";

let pass = 0, fail = 0;
const ok = (condition, name) => {
  if (condition) pass++;
  else fail++;
  console.log((condition ? "  ok   " : "  FAIL ") + name);
};

ok(safeEqual("secret", "secret"), "matching webhook secrets accepted");
ok(!safeEqual("secret", "secreT") && !safeEqual("secret", "secret-long"), "different secrets rejected");
ok(isAuthorizedPrivateMessage({ message: { chat: { id: 123, type: "private" }, text: "/help" } }, "123"), "authorized private chat accepted");
ok(!isAuthorizedPrivateMessage({ message: { chat: { id: -123, type: "group" }, text: "/help" } }, "-123"), "group chat rejected");
ok(!isAuthorizedPrivateMessage({ message: { chat: { id: 456, type: "private" }, text: "/help" } }, "123"), "other private chat rejected");
ok(parseCommand("/feedback")?.command === "feedback", "/feedback parsed");
ok(parseCommand("/feedback@adiak_bot")?.command === "feedback", "Telegram bot command suffix parsed");
ok(parseCommand("/fix 15")?.issueNumber === 15, "/fix issue number parsed");
ok(parseCommand("/issue 42")?.issueNumber === 42 && parseCommand("/publish 42")?.issueNumber === 42, "feedback preview and explicit publish commands parsed");
ok(parseCommand("/publish") === null && parseCommand("/issue 0") === null, "public publish requires a valid feedback ID");
ok(parseCommand("/fix") === null && parseCommand("/fix 0") === null && parseCommand("/fix 1.5") === null, "invalid fix arguments rejected");
ok(parseCommand("/status")?.command === "status" && parseCommand("/prs")?.command === "prs" && parseCommand("/help")?.command === "help", "status, prs and help parsed");
ok(parseCommand("/prs 3") === null && parseCommand("/unknown") === null, "unexpected arguments and unknown commands rejected");
ok(escapeHtml("<b>A & B</b>") === "&lt;b&gt;A &amp; B&lt;/b&gt;", "Telegram HTML escaped");
const row = { id: 42, body: "App crashes after login", class_tag: "10A", created_at: "2026-11-16T10:00:00Z" };
ok(feedbackMarker(42) === "<!-- adiak-feedback-id:42 -->", "stable feedback id marker generated");
ok(feedbackIssueTitle(row).startsWith("ADIAK feedback #42:"), "feedback title includes stable ID");
ok(feedbackIssueBody(row).includes(feedbackMarker(42)) && feedbackIssueBody(row).includes("App crashes after login"), "issue body contains marker and feedback");
ok(feedbackIssueBody(row).includes("untrusted user input"), "issue body labels feedback as untrusted");

console.log(`telegram-control: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
