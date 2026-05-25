# Where to promote kawpow-mac / Unmineable-Mac

## Tier 1 — start here, biggest signal

### Hacker News — Show HN
- **URL**: https://news.ycombinator.com/submit
- **Why**: engineering bug-bisection story is HN catnip; reverse-engineering + Apple Silicon + crypto angle covers three popular HN themes
- **Format**: `Show HN: Five bugs between a closed-source crypto miner and a working one`
- **Body**: use `promo-long.md`
- **Best post time**: weekday morning US Pacific (around 8-10 AM PT)

### r/Ravencoin
- **URL**: https://reddit.com/r/Ravencoin
- **Why**: direct user base, mods generally OK with open-source miner posts
- **Format**: Title + medium body from `promo-medium.md` (variant A)
- **Note**: include "first open-source M3/M4/M5 KawPow miner" in title — that's the news

### r/Unmineable
- **URL**: https://reddit.com/r/unmineable
- **Why**: the pool's own subreddit; the integration is directly useful here
- **Format**: emphasize the Unmineable-Mac integration, not just kawpow-mac
- **Body**: medium variant A

---

## Tier 2 — niche but on-target

### r/MacMining
- Small subreddit, but every reader is in your exact target audience.

### r/AppleSilicon
- Frame it as: Metal compute, reverse-engineering a Swift binary, Keccak from scratch. Lead with the engineering. Use medium variant B.

### r/swift
- Engineering-pitch variant B. Highlight: Metal integration, no Keccak in CryptoKit so DIY, Swift Package Manager.

### r/programming
- Use long-form. The 5-bug bisection story does well there.

### lobste.rs
- High signal-to-noise technical audience. Use long-form. **Requires invite.**

---

## Tier 3 — supplementary

### Twitter / X / Mastodon / Bluesky
- Use one of the three short variants from `promo-short.md`
- Tag `@RavencoinHQ`, `@unMineableTeam`, `@SwiftLang`
- Hashtags: `#KawPow`, `#AppleSilicon`, `#Ravencoin`, `#Swift`

### unMineable Discord
- Their official Discord — share in `#help` or `#general` after asking
  a mod where it fits
- Use short variant B (user-pitch)

### Ravencoin Discord
- Same approach

### r/CryptoMining, r/EtherMining, r/CryptoCurrency
- Lower signal/noise. Optional. Use short or medium body.

---

## Posting order (recommended)

1. **HN Show HN first** — single biggest traffic source if it sticks. If it falls off the front page after 30 min, that's just how HN works, don't take it personally.
2. **r/Ravencoin + r/Unmineable simultaneously** — different audiences, no overlap penalty.
3. After 24h see the HN reception → **r/programming** if HN went well; otherwise skip.
4. Then **Twitter/X + Discords + r/MacMining + r/AppleSilicon + r/swift**.

---

## What to have ready before posting

- A short GIF or screen recording showing the miner connecting and the
  first `result:true` from the pool. 10-15 seconds is enough.
- A screenshot of the Unmineable-Mac UI with shares accepted (the new
  share-counter feature).
- One sentence comeback to "but it's not profitable on a Mac": "Agreed
  — this isn't a profit pitch, it's a salvage of the existing
  open-source GUI for users who already have the hardware."

---

## Things to NOT do

- Don't post in five subs simultaneously — reddit anti-spam will eat
  you. Wait at least an hour between posts.
- Don't change the title across posts to look like new content. Same
  honest title each time.
- Don't engage with low-effort attacks (the "mining is dumb" crowd).
  Engage substantively with technical questions.
- Don't post the standalone kawpow-mac and the Unmineable-Mac app as
  *separate* Show HNs. They're one story; one HN submission.
