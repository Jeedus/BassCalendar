# BassCalendar

Dubstep, riddim, melodic bass and drum & bass shows around Chicago, plus Midwest bass festivals with their lineups.

**Open it:** https://jeedus.github.io/BassCalendar/

- Works on phones. Tap Share, then **Add to Home Screen**, and it opens like an app, even offline.
- Save shows to your own list and add them to Google Calendar.
- Updated daily. All listings live in `data.json`.

Lineups and set times change, so check the ticket link before you go.

## Crews

Crew plans (Going / Interested / Got tix) are stored in Supabase against each show and festival `id` in data.json. Never change an existing id: it would wipe everyone's plans for that show. Database setup is in `supabase/setup.sql`.
