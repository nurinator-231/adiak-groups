# Changelog

butun qeydolunasi deyisiklikler buradadi
format keep a changelog tipindedi

## [Unreleased] — ADIAK 1.2 (branch `claude/loving-bell-1ydez1`, not deployed)

### Added
- Teacher creates a presentation in two steps: title, then a TXT/DOCX topic list (parsed in the browser, validated on the server).
  Students pick topics (limit per topic, 1 = exclusive, 0 = unlimited); teachers see who picked what, edit/remove topics and release picks.
- Chat read receipts ("Göndərildi" / "Görüldü", group: who has seen it), live; online dots, "last seen" with idle/hidden detection.
- Admin: create empty groups, add students later, supervising teacher per group (can follow the group chat).
- "Günü bitir" archives the day's finished presentations (teams, files, finals, order, topics) together with the chats; teachers can end the day for their class.
- Push texts for the new events (topic list, topic released, supervising teacher).

### Changed
- Speaking order and final presentation take effect without teacher approval (staff can still return/reopen).
- Password change requires the current password, checked on the server (`change_my_password`), feedback #13.
- An admin who is also a student is a normal member of their group (system role and group role are separate).
- Notifications are never sent to the user who triggered the event; no double push for mentions.

### Fixed
- Feedback #11: uploaded presentation files were stored correctly but hidden in two places: Teacher Studio only listed the
  chosen final, and a student who changed team lost sight of their own uploads. Both now show the files.

### Database (7 additive migrations, not applied to production)
`20261117100000_pres_auto_accept` … `20261117100600_push_rules`; rollback `supabase/rollback/v12_restore.sql`.

## [1.1.0] - 2026-11-06

stabillik ve gorunum duzelisleri,server terefi deyisiklik yoxdu

### Added

- svg ikonlari ve favicon
- lokal snapshot'dan suretli yuklenme (data arxaplanda sinxronizasiya olur)
- saniyede 1 mesaj atma istek limiti (istifadeci terefinde)
- medallar ucun profile'da ve home'da tablar
- telefon ve mobil ucun responsiv dizayn
- offlayn admin paneli (deyisiklik etmek ucun internet helede lazimdir)

### Changed

- dizay,rengler,ui ikonlari
- daha tutarli kenar yuvarlaqlasdirmasi ve daha yumsag kolgeler
- her defe yerine yalniz deyisikliklerde supabase sorgulari
- yalniz gorunende yuklenen cat sekilleri
- mobilde admin cedvelleri ve filtrler

### Fixed

- profili acanda artiq animasiyalar tekrarlanmir
- xos gelmisiniz/medallar arasi titreme
- baglanti problemlerinde aydin xeta idareetmesi ve yeniden cehd
- daha tehlukesiz mesaj silme/reaksiya ve admin kopyala/eksport hadiseleri
- canli sessiya yoxlanisi ve yeniden qosulma

### Removed

- home sehifesindeki suretli kecidler
- sag altda duran "yaradanlar" penceresi
- istifade olunmayan asset'ler ve cache-busting parametrleri

### Security

- admin parol kopyalama ve stiker yollari ucun tehlukesiz escaping

### Notes

- Supabase sxemi, RLS prinsipleri ve RPC funksiyalari deyisilmedi
- cat rate-limit'i istifadeci terefindedi
- lokal snapshot her istifadecide ayridir ve hesabdan cixisda silinir
- easter egg:lider taci ikonunun adi "yusf.svg"-dir
- elave qeyd:ui ikonlari hazirlamaq ucun "muse spark 1.3" modelinden,kod tamamlama ucun "deepseek v4.1 flash" modeli istifade olunub
