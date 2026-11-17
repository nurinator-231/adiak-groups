// ADIAK 1.1 features in the browser (mocked Supabase): admin-as-student in groups, no approval step, topic picker,
// teacher topic upload, password change with the current password, read receipts, presence, admin empty group + day archive.
// Usage: node tests/v11-ui.mjs [label]
import { harness, assert, settle } from "./lib/harness.mjs";
import { IDS, profiles } from "./lib/fixtures.mjs";
const H = await harness(process.argv[2] || "v11-ui");
const calls = (env, fn) => (env.log.calls || []).filter(x => x.fn === fn);
const ready = p => p.waitForFunction(() => window.PX && PX.on && PX.loaded, null, { timeout: 8000 });
const goPres = async p => { await ready(p); await p.evaluate(() => goTab("pres")); await settle(p); };
const E = "00000000-0000-4000-8000-000000000004";
const topics = { pres_topics: [{ id: 1, event_id: 1, title: "Süni intellektin gələcəyi", position: 1, removed_at: null }, { id: 2, event_id: 1, title: "Kibertəhlükəsizlik", position: 2, removed_at: null },
  { id: 3, event_id: 1, title: "Bulud texnologiyaları", position: 3, removed_at: null }],
  pres_topic_picks: [{ event_id: 1, user_id: E, topic_id: 1, group_id: 2, user_name: "Elvin Hüseynov" }] };

await H.test("item 4: an admin who is a student is listed as a member of their group", async () => {
  const P2 = profiles.map(p => p.id === IDS.student2 ? { ...p, perms: ["admin"] } : p);
  const env = await H.open({ user: IDS.student, over: { tables: { profiles: P2 } } }); await settle(env.page, 1200);
  const names = await env.page.evaluate(() => mem(1).map(p => p.name));
  assert(names.includes("Rəşad Əliyev") && names.includes("Aysel Məmmədova"), "group members: " + names.join(", "));
  const host = await env.page.evaluate(() => mem(null).some(p => p.name === "Admin Test"));
  assert(!host, "the class-less host account still does not appear as a student");
  return env;
});
await H.test("item 3: speaking order has no submit/approve step", async () => {
  const env = await H.open({ user: IDS.student }); await goPres(env.page);
  await env.page.evaluate(() => pxSec("order")); await settle(env.page);
  const t = await env.page.textContent(".pxwrap");
  assert(t.includes("təsdiq lazım deyil"), "explains automatic saving: " + t.slice(0, 300));
  assert(!(await env.page.$("button:has-text('Sıranı göndər')")) && !(await env.page.$("button:has-text('Sıranı təsdiqlə')")), "no submit/approve buttons");
  return env;
});
await H.test("item 9: student sees the topic list, a taken topic is marked, picking calls pres_topic_pick", async () => {
  const env = await H.open({ user: IDS.student, over: { tables: topics } }); await goPres(env.page);
  const t = await env.page.textContent(".pxtopics"); assert(t.includes("Təqdimat mövzuları") && t.includes("Kibertəhlükəsizlik") && t.includes("Elvin Hüseynov"), "topics card: " + t);
  assert((await env.page.textContent(".pxtopics li:first-child")).includes("Tutulub"), "taken topic marked (one student per topic)");
  await env.page.click(".pxtopics li:nth-child(2) button:has-text('Seç')"); await settle(env.page, 400);
  const c = calls(env, "pres_topic_pick")[0]; assert(c && c.body.tid === 2, "pick call " + JSON.stringify(c));
  await H.shot(env.page, "topics-student"); return env;
});
await H.test("item 9: teacher creates a presentation from a TXT topic list (title -> file -> create)", async () => {
  const acc = { uid: IDS.teacher, role: "teacher", owner: false, admin: false, perms: ["points"], class: null, group: null, teaches: [{ tag: "10A", title: "10-cu sinif A", perms: [] }], leads: [] };
  const env = await H.open({ user: IDS.teacher, over: { rpc: { my_access: acc, staff_classes: [{ tag: "10A", title: "10-cu sinif A", role: "teacher", perms: [], students: 6 }], pres_event_save: 9, pres_topics_add: 3 } } });
  await ready(env.page); await settle(env.page, 700); if (await env.page.$(".clgrid")) { await env.page.click(".clcard"); await settle(env.page, 900); }
  await env.page.evaluate(() => { goTab("studio"); stSetClass("10A"); ST.sec = "pres"; ST.ev = "new"; render(); }); await settle(env.page, 500);
  assert(!(await env.page.$("#std")), "no description field in the new form");
  await env.page.fill("#stt", "Texnologiya mövzuları");
  await env.page.setInputFiles(".stfile input[type=file]", { name: "movzular.txt", mimeType: "text/plain", buffer: Buffer.from("1. Süni intellekt\n2. Kibertəhlükəsizlik\n\n3. Bulud\n") });
  await env.page.waitForFunction(() => ST.newTopics && !ST.topicsBusy, null, { timeout: 5000 }); await settle(env.page, 200);
  const prev = await env.page.textContent(".stfile"); assert(prev.includes("3 mövzu tapıldı") && prev.includes("Kibertəhlükəsizlik"), "preview: " + prev.replace(/\s+/g, " "));
  assert((await env.page.inputValue("#stt")) === "Texnologiya mövzuları", "title kept after the file was read");
  await env.page.setInputFiles(".stfile input[type=file]", { name: "x.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF") }); await env.page.waitForFunction(() => ST.topicsErr, null, { timeout: 5000 }); await settle(env.page, 200);
  assert((await env.page.textContent(".stfile")).includes("Yalnız TXT və DOCX"), "wrong format error shown");
  await env.page.setInputFiles(".stfile input[type=file]", { name: "movzular.txt", mimeType: "text/plain", buffer: Buffer.from("Süni intellekt\nKibertəhlükəsizlik\nBulud") }); await env.page.waitForFunction(() => !ST.topicsErr && ST.newTopics, null, { timeout: 5000 }); await settle(env.page, 200);
  await H.shot(env.page, "topics-teacher-form");
  await env.page.click(".stform ~ .row button.ok"); await settle(env.page, 900);
  const s = calls(env, "pres_event_save")[0], a = calls(env, "pres_topics_add")[0];
  assert(s && s.body.ttl === "Texnologiya mövzuları" && s.body.dsc === "", "event saved with title only: " + JSON.stringify(s && s.body));
  assert(a && a.body.e === 9 && a.body.items.length === 3 && a.body.src === "movzular.txt", "topics sent: " + JSON.stringify(a && a.body));
  return env;
});
await H.test("item 7: password change needs the current password and uses the server check", async () => {
  let n = 0;
  const env = await H.open({ user: IDS.student, over: { rpc: { change_my_password: () => (++n === 1 ? "wrong" : "ok") } } }); await settle(env.page, 1200);
  await env.page.evaluate(() => goTab("settings")); await settle(env.page);
  await env.page.fill("#cp1", "yeni-parol"); await env.page.fill("#cp2", "yeni-parol"); await env.page.click("#cpbtn"); await settle(env.page, 300);
  assert(!calls(env, "change_my_password").length, "no server call without the current password");
  assert((await env.page.textContent("#toast")).includes("Cari parolu daxil edin"), "asks for the current password");
  await env.page.fill("#cp0", "kohne"); await env.page.click("#cpbtn"); await settle(env.page, 500);
  assert((await env.page.textContent("#toast")).includes("Cari parol düzgün deyil"), "wrong current password reported");
  await env.page.fill("#cp0", "dogru-parol"); await env.page.fill("#cp1", "yeni-parol"); await env.page.fill("#cp2", "yeni-parol"); await env.page.click("#cpbtn"); await settle(env.page, 500);
  assert((await env.page.textContent("#toast")).includes("✓"), "success message");
  const c = calls(env, "change_my_password"); assert(c.length === 2 && c[1].body.cur === "dogru-parol" && c[1].body.pw === "yeni-parol", "rpc args");
  assert(!env.log.writes.some(w => w.startsWith("auth ")), "the app no longer changes the password through supabase.auth");
  return env;
});
await H.test("item 6: own messages show Göndərildi/Görüldü from message_reads; opening a chat marks it read", async () => {
  const reads = [{ channel: "g:1", user_id: IDS.student2, last_read_id: 1, read_at: new Date().toISOString() }];
  const env = await H.open({ user: IDS.student, over: { tables: { message_reads: reads } } }); await settle(env.page, 1200);
  await env.page.evaluate(() => openChat("g:1")); await settle(env.page, 900);
  const m1 = await env.page.textContent("#m1 time"), m4 = await env.page.textContent("#m4 time");
  assert(m1.includes("✓✓"), "message 1 seen: " + m1); assert(m4.includes("Göndərildi") && !m4.includes("✓✓"), "latest own message not yet seen: " + m4);
  const mr = calls(env, "mark_read").find(x => x.body.ch === "g:1"); assert(mr && mr.body.mid === 5 - 1 + 0 || (mr && mr.body.mid >= 4), "mark_read for the open chat: " + JSON.stringify(mr));
  // live receipt via realtime -> "Görüldü · 1"
  await env.page.evaluate(id => rdIn({ new: { channel: "g:1", user_id: id, last_read_id: 4, read_at: new Date().toISOString() } }), IDS.student2); await settle(env.page, 300);
  assert((await env.page.textContent("#m4 time")).includes("Görüldü · 1"), "receipt updates live");
  await env.page.click("#m4 .rd[role=button]"); await settle(env.page, 300);
  assert((await env.page.textContent("#modal")).includes("Rəşad Əliyev"), "group: who has seen it");
  await H.shot(env.page, "chat-receipts"); return env;
});
await H.test("item 6: presence — online dot, last seen in the DM header, idle/hidden untracks", async () => {
  const seen = [{ user_id: IDS.student2, last_seen_at: new Date(Date.now() - 5 * 60000).toISOString() }];
  const env = await H.open({ user: IDS.student, over: { tables: { user_presence: seen } } }); await settle(env.page, 1500);
  const dm = await env.page.evaluate(id => dmKey(uid, id), IDS.student2);
  await env.page.evaluate(k => openChat(k), dm); await settle(env.page, 800);
  const h = await env.page.textContent(".thd"); assert(/son aktivlik: (5|4|6) dəq əvvəl/.test(h), "last seen: " + h);
  await env.page.evaluate(id => { online = new Set([uid, id]); render(); }, IDS.student2); await settle(env.page, 300);
  assert((await env.page.textContent(".thd")).includes("onlayn"), "online label");
  assert(await env.page.$(".av.onl"), "online dot on the avatar");
  await env.page.evaluate(id => { online = new Set([uid]); LS[id] = undefined; online.forEach(() => {}); }, IDS.student2);
  const pings = calls(env, "presence_ping").length; assert(pings >= 1, "presence_ping sent while active");
  await env.page.evaluate(() => { actAt = Date.now() - 6 * 60000; presOff(); }); await settle(env.page, 300);
  assert(calls(env, "presence_bye").length >= 1, "going idle/hidden stores last seen (presence_bye)");
  await H.shot(env.page, "chat-presence"); return env;
});
await H.test("admin: create an empty group (no members required) and add a student later", async () => {
  const env = await H.open({ user: IDS.admin, path: "/admin/index.html", over: { rpc: { staff_classes: [{ tag: "10A" }], admin_create_group: 7 } } }); await settle(env.page, 1500);
  await env.page.evaluate(() => switchTab("groups")); await settle(env.page, 600);
  await env.page.click("button:has-text('Yeni boş qrup')"); await settle(env.page, 300);
  await env.page.fill("#ng_name", "Gamma"); await env.page.click("#ng_go"); await settle(env.page, 600);
  const c = calls(env, "admin_create_group")[0]; assert(c && c.body.nm === "Gamma" && c.body.cls === "10A" && c.body.cap === 5, "create call " + JSON.stringify(c));
  await env.page.selectOption("#gadd1", IDS.idle); await env.page.click("#gadd1 ~ button"); await settle(env.page, 500);
  const m = calls(env, "admin_move_member")[0]; assert(m && m.body.u === IDS.idle && m.body.g === 1, "add member call " + JSON.stringify(m));
  await H.shot(env.page, "admin-groups"); return env;
});
await H.test("admin: close the day with a class scope; archive shows presentations with their files", async () => {
  const ap = [{ id: 1, archive_id: 1, event_id: 1, class_tag: "10A", title: "Ekologiya layihəsi", day: "2026-11-17", snapshot: { event: { id: 1 }, teams: [{ group_id: 1, group_name: "Alfa", members: [{ name: "Aysel" }],
    order: [{ pos: 1, name: "Aysel" }], topics: [{ name: "Aysel", topic: "Bulud" }], final: { name: "final.pdf", path: "e1/g1/22222222-2222-4222-8222-222222222222.pdf" }, files: [{ name: "draft.pptx", path: "e1/g1/11111111-1111-4111-8111-111111111111.pptx" }] }] } }];
  const env = await H.open({ user: IDS.admin, path: "/admin/index.html", over: { tables: { archived_presentations: ap }, rpc: { staff_classes: [{ tag: "10A" }], close_day: { archive_id: 1, messages: 5, presentations: 1, skipped_live: 0 } } } });
  await settle(env.page, 1500); await env.page.evaluate(() => switchTab("day")); await settle(env.page, 600);
  await env.page.selectOption("#d_cls", "10A"); await env.page.click("#d_go"); await settle(env.page, 300);
  await env.page.click("#modal button:has-text('Bəli')"); await settle(env.page, 800);
  const c = calls(env, "close_day")[0]; assert(c && c.body.cls === "10A" && c.body.dissolve === false, "close_day call " + JSON.stringify(c));
  assert((await env.page.textContent("#toast")).includes("1 təqdimat"), "result reported");
  await env.page.click(".panel .li.pc"); await settle(env.page, 800);
  const t = await env.page.textContent("#modal"); assert(t.includes("Ekologiya layihəsi") && t.includes("final.pdf") && t.includes("draft.pptx") && t.includes("Alfa"), "archive view: " + t.slice(0, 200));
  await H.shot(env.page, "admin-archive"); return env;
});
await H.test("phone 360: topic picker and chat receipts fit without horizontal overflow", async () => {
  const over = (p) => p.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  const env = await H.open({ user: IDS.student, width: 360, height: 760, over: { tables: { ...topics, message_reads: [{ channel: "g:1", user_id: IDS.student2, last_read_id: 4, read_at: new Date().toISOString() }] } } });
  await goPres(env.page); await env.page.evaluate(() => { const el = document.querySelector(".pxtopics"); if (el) el.scrollIntoView(); }); await settle(env.page, 300);
  assert(await env.page.$(".pxtopics"), "topics card on phone"); assert((await over(env.page)) <= 0, "topics overflow " + await over(env.page));
  await H.shot(env.page, "phone-topics");
  await env.page.evaluate(() => openChat("g:1")); await settle(env.page, 900);
  assert((await over(env.page)) <= 0, "chat overflow"); assert((await env.page.textContent("#m4 time")).includes("Görüldü"), "receipt on phone");
  await H.shot(env.page, "phone-chat-receipts"); return env;
});
await H.done();
