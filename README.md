# BassCalendar

Dubstep, riddim, melodic bass and drum & bass shows around Chicago, plus Midwest bass festivals with their lineups.

**Open it:** https://jeedus.github.io/BassCalendar/

- Works on phones. Tap Share, then **Add to Home Screen**, and it opens like an app, even offline.
- Save shows to your own list and add them to Google Calendar.
- Updated daily. All listings live in `data.json`.

Lineups and set times change, so check the ticket link before you go.

## Crews

Crew plans (Going / Interested / Got tix) are stored in Supabase against each show and festival `id` in data.json. Never change an existing id: it would wipe everyone's plans for that show. Database setup is in `supabase/setup.sql`.

## Friends

Friends are people outside your crew. Each person gets a friend code (shown as a QR code and a `?friend=CODE` link). Opening someone's link and tapping Add makes you friends both ways, and friends see each other's plans. Plans are copied to Supabase whenever they change. The friend tables and `friend_*` functions are at the bottom of `supabase/setup.sql`. `qr.js` is the QR code library (qrcode-generator, MIT), loaded only on the Friends page.
