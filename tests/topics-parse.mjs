// Unit test for the teacher's topic-list parser (TXT/DOCX) in assets/js/app/studio.js. Dev-only, no browser, no network.
// Usage: node tests/topics-parse.mjs
import { readFileSync } from "node:fs";
import { deflateRawSync, crc32 } from "node:zlib";

const src = readFileSync(new URL("../assets/js/app/studio.js", import.meta.url), "utf8");
const code = src.slice(src.indexOf("/* topics-parser:start"), src.indexOf("/* topics-parser:end */"));
const P = new Function(code + "; return { stReadTopics, topicLines, topicClean };")();

// tiny ZIP writer (deflate or stored) to build real DOCX files
function zip(entries, store = false) {
  const parts = [], central = []; let off = 0;
  for (const [name, text] of entries) {
    const data = Buffer.from(text, "utf8"), comp = store ? data : deflateRawSync(data), nm = Buffer.from(name);
    const lh = Buffer.alloc(30); lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(store ? 0 : 8, 8);
    lh.writeUInt32LE(crc32(data), 14); lh.writeUInt32LE(comp.length, 18); lh.writeUInt32LE(data.length, 22); lh.writeUInt16LE(nm.length, 26);
    const ch = Buffer.alloc(46); ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(20, 4); ch.writeUInt16LE(20, 6); ch.writeUInt16LE(store ? 0 : 8, 10);
    ch.writeUInt32LE(crc32(data), 16); ch.writeUInt32LE(comp.length, 20); ch.writeUInt32LE(data.length, 24); ch.writeUInt16LE(nm.length, 28); ch.writeUInt32LE(off, 42);
    parts.push(lh, nm, comp); central.push(ch, nm); off += 30 + nm.length + comp.length;
  }
  const cd = Buffer.concat(central), end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(off, 16);
  return Buffer.concat([...parts, cd, end]);
}
const para = t => `<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t xml:space="preserve">${t}</w:t></w:r></w:p>`;
const docXml = ps => `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="x"><w:body>${ps.join("")}</w:body></w:document>`;
const file = (name, bytes) => new File([bytes], name);

let pass = 0, fail = 0;
const ok = (c, name) => { if (c) { pass++; } else { fail++; console.log("FAIL -", name); } };
const eq = (a, b, name) => ok(JSON.stringify(a) === JSON.stringify(b), name + (JSON.stringify(a) === JSON.stringify(b) ? "" : ` (got ${JSON.stringify(a)})`));
async function throws(p, re, name) { try { await p; ok(false, name + " (no error)"); } catch (e) { ok(re.test(e.message), name + ` (${e.message})`); } }

const want = ["Süni intellektin gələcəyi", "Kibertəhlükəsizlik", "Proqramlaşdırma dilləri", "Bulud texnologiyaları", "Verilənlər bazası"];
const txt = "1. Süni intellektin gələcəyi\r\n2. Kibertəhlükəsizlik\r\n\r\n3. Proqramlaşdırma dilləri\n4) Bulud texnologiyaları\n5 - Verilənlər bazası\n2. kibertəhlükəsizlik\n";
eq(await P.stReadTopics(file("movzular.txt", Buffer.from(txt))), want, "TXT: numbered list, CRLF, blank lines, duplicate removed");
eq(await P.stReadTopics(file("m.txt", Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("• Ə hərfi\n- İnternet")]))), ["Ə hərfi", "İnternet"], "TXT: UTF-8 BOM and bullets");
const u16 = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from("Şəbəkələr\r\nÇip", "utf16le")]);
eq(await P.stReadTopics(file("w.txt", u16)), ["Şəbəkələr", "Çip"], "TXT: UTF-16 (Notepad 'Unicode')");
eq(await P.stReadTopics(file("Mövzular.DOCX", zip([["[Content_Types].xml", "<Types/>"], ["word/document.xml", docXml(want.map((t, i) => para((i + 1) + ". " + t)))]]))), want, "DOCX: numbered paragraphs (deflate)");
eq(await P.stReadTopics(file("e.docx", zip([["word/document.xml", docXml([para("R&amp;D &lt;AI&gt;"), "<w:p></w:p>", `<w:p><w:r><w:t>Split </w:t></w:r><w:r><w:t>run</w:t></w:r></w:p>`])]], true))),
  ["R&D <AI>", "Split run"], "DOCX: entities, empty paragraph, text split across runs (stored)");
eq(P.topicLines(["A.I. future", "100-cü il", "a) Şəbəkələr", "(3) Robotlar"]), ["A.I. future", "100-cü il", "Şəbəkələr", "Robotlar"], "cleaning keeps real text");
await throws(P.stReadTopics(file("x.pdf", Buffer.from("x"))), /only txt and docx/i, "wrong format rejected");
await throws(P.stReadTopics(file("x.doc", Buffer.from("x"))), /\.doc/i, "old .doc explained");
await throws(P.stReadTopics(file("x.txt", Buffer.alloc(0))), /empty/i, "empty file rejected");
await throws(P.stReadTopics(file("x.txt", Buffer.from("\n  \n1.\n-\n"))), /no topics/i, "file without topics rejected");
await throws(P.stReadTopics(file("x.docx", Buffer.from("not a zip at all"))), /not a valid docx/i, "broken DOCX rejected");
await throws(P.stReadTopics(file("x.docx", zip([["word/other.xml", "<x/>"]]))), /not a valid docx/i, "DOCX without document.xml rejected");
await throws(P.stReadTopics(file("big.txt", Buffer.alloc(2 * 1024 * 1024 + 1, 65))), /too large/i, "file over 2 MB rejected");
await throws(Promise.resolve().then(() => P.topicLines(Array.from({ length: 302 }, (_, i) => "Topic " + i))), /300/, "more than 300 topics rejected");
console.log(`topics-parse: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
