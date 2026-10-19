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

## Profile

The **You** tab is your profile: your picture (one of eight built-in tiles), your name, the sounds you're into, the artists you follow, and your shows, upcoming and past. It works without a crew or friend code and lives on this device. With a friend code, your friends see your picture and sound, and tapping a friend opens their profile. Changing your name updates it for your friends and your crew. This needs the `pic`/`sounds` columns, `friend_set_profile` and `crew_rename` from `supabase/setup.sql`.

## Watchlist

`watchlist.json` lists popular bass artists, grouped by sound, mostly taken from recent Lost Lands, Bass Canyon, WAKAAN, Electric Forest, EDC and Shambhala lineups. The daily updater checks 15 of them each day (rotating through the list, so everyone is covered about every 8 days) for Chicago-area tour dates, alongside the venue and listing sites. Add or remove names any time; the site itself doesn't read this file.
