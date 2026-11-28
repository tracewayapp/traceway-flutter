# The journey (generated from shared/journey.json — do not edit)

Shared version 2. Viewport 412 × 892. Built by `tools/journey/build.mjs` from the fixtures (seed 20261128) and `shared/labels.json`.

## Rules

- t is milliseconds after T0 (the app's FM_READY). A step starts at t, never earlier. More than lateMs late for any step marks the run late.
- reveal: before acting, make the element fully visible: dismiss the on-screen keyboard if it covers it, then scroll its scroll container with a drag (not a programmatic scroll) until it is. Budgeted at revealMs.
- A fling ends with velocity so the list keeps moving; dir is the direction the finger moves (up scrolls a list towards its end). distance is a fraction of the element's size along dir.
- drag with hold: true leaves the finger down at `to`; the next release step lifts it. A checkpoint with during: "drag" is taken while the finger is held. A driver that cannot hold does the whole drag, takes the checkpoint right after and records the deviation.
- type: one character at a time through the keyboard path into the focused field (into names it).
- pick: choose `value` in the picker of `id` with its normal UI, opening it first if it is not open. A date value of +Nd is N days after the run's start on the device clock.
- checkpoint: wait settleMs, record the device clock as the checkpoint time; in evidence runs take a screenshot and the boxes of the `shows` texts and of the `masked` ids that are on screen. checkpointCaptureMs is the budget for that.
- shows are texts certainly visible at the checkpoint on the phone layout (412 x 892 and 390 x 844), taken from the fixtures and shared/labels.json. hides are the sentinels typed so far; masked are ids whose content must be masked in the replay.
- Steps with `platforms` run only on those platforms. A scenario with `platforms` exists only on those.

Durations used to check that input steps never overlap: tap 250 ms, reveal +900 ms, typing 120 ms per character, pick 2500 ms unless stated, checkpoint settle + 300 ms.

Sentinels (never in anything the SDK sends): `5105 1051 0510 5100`, `7391`, `Zx9!fieldmart-PW`, `Ada Fieldtest`, `ada.fieldtest@example.test`, `77 Sentinel Quay, Flat 12`, `LOY-88442211`.

Differences from the prose of 02-APP-SPEC.md §5.4, made so that every step names an element that is certainly there:

- S2: the three "Helpful" taps come before the eight review flings (after the flings nobody can know which reviews are on screen); they also bring the reviews into view.
- S5 and S6: the order of the review section is terms, menu, sheet (the checkpoint list of §5.4 S5 names the sheet before the menu).
- S6: Markets runs 122–151 s, Feed 151–174 s and Checkout from 174.5 s to about 265 s (the whole form at 120 ms per character does not fit in 190–270 s); the handled exception is still at about 240 s; then Home and idle to 300 s.
- Element ids added: `fm-more-diag` (More → Diagnostics), `fm-checkout-terms-text` (the scrolling text of the terms dialog), `fm-checkout-loyalty` (the loyalty number with the mask marker), `fm-search-results` (the results list).
- Product reviews have string ids (`r17-0`), so `fm-product-helpful-r17-0` is the first review's button.

## S0 — Cold start and idle

70 s · measured · 2 steps · 1 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:05.000 | checkpoint | **s0-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |

## S1 — Browse

75 s · measured · 36 steps · 6 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:22.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:25.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:27.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:32.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:35.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.800 | checkpoint | **s1-grid-deep**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:40.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:42.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:45.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:47.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:50.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:52.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:55.000 | tap | `fm-home-logo` |
| 0:56.500 | checkpoint | **s1-top**, settle 400 ms<br>shows: "Fieldmart", "Today's deals", "Outdoor" |
| 0:58.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 0:59.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:00.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:01.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:02.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:03.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:04.400 | checkpoint | **s1-deals**, settle 400 ms<br>shows: "Fieldmart", "Today's deals" |
| 1:06.000 | tap | `fm-home-chip-3` · reveal |
| 1:08.000 | tap | `fm-home-chip-7` · reveal |
| 1:09.800 | checkpoint | **s1-category**, settle 800 ms<br>shows: "Lighting", "Lumen Wall Sconce" |

## S2 — Product

60 s · measured · 38 steps · 8 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | tap | `fm-home-product-17` · reveal |
| 0:05.500 | checkpoint | **s2-product**, settle 800 ms<br>shows: "Cedar Oak Desk Lamp", "Vellowmark", "$104.00", "Add to cart" |
| 0:07.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:08.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:09.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:10.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:10.300 | checkpoint | **s2-gallery-5**, settle 300 ms<br>shows: "5 / 8", "Add to cart" |
| 0:11.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:12.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:13.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 0:14.500 | tap | `fm-product-readmore` · reveal |
| 0:16.300 | checkpoint | **s2-readmore**, settle 400 ms<br>shows: "Show less", "Add to cart" |
| 0:17.300 | tap | `fm-product-size-2` · reveal |
| 0:19.100 | tap | `fm-product-colour-5` · reveal |
| 0:20.900 | tap | `fm-product-qty-plus` · reveal |
| 0:22.700 | tap | `fm-product-qty-plus` |
| 0:23.000 | tap | `fm-product-qty-plus` |
| 0:23.300 | tap | `fm-product-qty-plus` |
| 0:23.600 | tap | `fm-product-qty-plus` |
| 0:24.000 | checkpoint | **s2-variants**, settle 400 ms<br>shows: "Qty 6", "Add to cart" |
| 0:25.000 | tap | `fm-product-helpful-r17-0` · reveal |
| 0:26.800 | tap | `fm-product-helpful-r17-1` · reveal |
| 0:28.600 | tap | `fm-product-helpful-r17-2` · reveal |
| 0:30.400 | checkpoint | **s2-helpful**, settle 400 ms<br>shows: "Lea E.", "Add to cart" |
| 0:31.500 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:33.000 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:34.500 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:36.000 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:37.500 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:39.000 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:40.500 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:42.000 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 0:42.400 | checkpoint | **s2-reviews**, settle 1500 ms<br>shows: "Add to cart" |
| 0:45.000 | tap | `fm-product-add` |
| 0:45.600 | checkpoint | **s2-added** (toast), settle 500 ms<br>shows: "Added to cart" |
| 0:50.000 | tap | `fm-nav-back` |
| 0:51.500 | checkpoint | **s2-back**, settle 800 ms<br>shows: "Fieldmart", "Home" |

## S3 — Markets

90 s · measured · 22 steps · 5 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-markets` |
| 0:05.000 | checkpoint | **s3-chart**, settle 400 ms<br>shows: "HEAM", "1H", "1D", "1W", "Markets" |
| 0:35.000 | tap | `fm-markets-tf-1D` |
| 0:38.000 | tap | `fm-markets-tf-1W` |
| 0:41.000 | tap | `fm-markets-tf-1M` |
| 0:41.700 | checkpoint | **s3-tf-1M**, settle 600 ms<br>shows: "HEAM", "1M", "Markets" |
| 0:44.000 | tap | `fm-markets-tf-1H` |
| 0:47.000 | drag | `fm-markets-chart` · 0.1,0.5 → 0.9,0.5, 4000 ms |
| 0:51.500 | drag | `fm-markets-chart` · 0.1,0.5 → 0.9,0.5, 4000 ms, hold |
| 0:55.500 | checkpoint | **s3-crosshair** (finger held), settle 200 ms<br>shows: "HEAM", "Markets" |
| 0:56.100 | release |  |
| 0:57.500 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms · reveal |
| 0:59.900 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:02.300 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:04.700 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:07.100 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:09.500 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:10.300 | checkpoint | **s3-watchlist**, settle 1000 ms<br>shows: "Markets", "Feed" |
| 1:12.000 | tap | `fm-markets-book-open` · reveal |
| 1:22.000 | checkpoint | **s3-book** (sheet), settle 400 ms<br>shows: "Order book", "Bids", "Asks" |
| 1:23.000 | tap | `fm-markets-book-close` |

## S3-svg — Markets with the SVG chart

90 s · measured · only web · launch {"fmChart":"svg"} · 22 steps · 5 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-markets` |
| 0:05.000 | checkpoint | **s3-chart**, settle 400 ms<br>shows: "HEAM", "1H", "1D", "1W", "Markets" |
| 0:35.000 | tap | `fm-markets-tf-1D` |
| 0:38.000 | tap | `fm-markets-tf-1W` |
| 0:41.000 | tap | `fm-markets-tf-1M` |
| 0:41.700 | checkpoint | **s3-tf-1M**, settle 600 ms<br>shows: "HEAM", "1M", "Markets" |
| 0:44.000 | tap | `fm-markets-tf-1H` |
| 0:47.000 | drag | `fm-markets-chart` · 0.1,0.5 → 0.9,0.5, 4000 ms |
| 0:51.500 | drag | `fm-markets-chart` · 0.1,0.5 → 0.9,0.5, 4000 ms, hold |
| 0:55.500 | checkpoint | **s3-crosshair** (finger held), settle 200 ms<br>shows: "HEAM", "Markets" |
| 0:56.100 | release |  |
| 0:57.500 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms · reveal |
| 0:59.900 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:02.300 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:04.700 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:07.100 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:09.500 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 1:10.300 | checkpoint | **s3-watchlist**, settle 1000 ms<br>shows: "Markets", "Feed" |
| 1:12.000 | tap | `fm-markets-book-open` · reveal |
| 1:22.000 | checkpoint | **s3-book** (sheet), settle 400 ms<br>shows: "Order book", "Bids", "Asks" |
| 1:23.000 | tap | `fm-markets-book-close` |

## S4 — Feed

60 s · measured · 40 steps · 5 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-feed` |
| 0:03.800 | checkpoint | **s4-top**, settle 400 ms<br>shows: "Activity", "Week 1", "HARS moved up 0.18 %", "Payment received for FM-977457" |
| 0:05.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:06.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:08.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:09.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:11.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:14.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:15.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:17.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:18.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:20.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:21.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:23.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:24.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:26.000 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 0:27.500 | tap | `fm-feed-jump-end` |
| 0:28.500 | checkpoint | **s4-end**, settle 800 ms<br>shows: "Activity", "Message from Hanna O." |
| 0:30.000 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:31.300 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:32.600 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:33.900 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:35.200 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:36.500 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:37.800 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:39.100 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:40.400 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:41.700 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 0:43.500 | tap | `fm-feed-goto-field` |
| 0:43.800 | type | "5000" into `fm-feed-goto-field` (4 × 120 ms) |
| 0:44.700 | tap | `fm-feed-goto-go` |
| 0:45.500 | checkpoint | **s4-row-5000**, settle 800 ms<br>shows: "Week 101", "Message from Tomas V." |
| 0:47.000 | tap | `fm-feed-row-5001` · reveal |
| 0:48.800 | tap | `fm-feed-row-5004` · reveal |
| 0:50.600 | tap | `fm-feed-row-5013` · reveal |
| 0:52.800 | checkpoint | **s4-expanded**, settle 400 ms<br>shows: "Message from Matteo J.", "Let me know if you need anything else from me." |
| 0:54.000 | tap | `fm-feed-refresh` |
| 0:55.000 | checkpoint | **s4-refreshed**, settle 1000 ms<br>shows: "Activity", "Jump to end" |

## S5 — Checkout

90 s · measured · 69 steps · 15 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:01.500 | tap | `fm-nav-checkout` · reveal |
| 0:02.950 | checkpoint | **s5-form-empty**, settle 400 ms<br>shows: "Checkout", "Contact", "Full name", "Email" |
| 0:03.850 | tap | `fm-checkout-name` |
| 0:04.300 | type | "Ada Fieldtest" into `fm-checkout-name` (13 × 120 ms) |
| 0:06.060 | checkpoint | **s5-name-typed**, settle 400 ms<br>shows: "Checkout", "Full name" · masked: `fm-checkout-name` · hides: 1 sentinel(s) |
| 0:06.960 | tap | `fm-checkout-email` |
| 0:07.410 | type | "ada.fieldtest@example.test" into `fm-checkout-email` (26 × 120 ms) |
| 0:10.730 | tap | `fm-checkout-phone` |
| 0:11.180 | type | "4155550188" into `fm-checkout-phone` (10 × 120 ms) |
| 0:12.580 | tap | `fm-checkout-account` · reveal |
| 0:13.930 | tap | `fm-checkout-password` · reveal |
| 0:15.280 | type | "Zx9!fieldmart-PW" into `fm-checkout-password` (16 × 120 ms) |
| 0:17.400 | checkpoint | **s5-contact-done**, settle 400 ms<br>shows: "Checkout", "Password" · masked: `fm-checkout-password` · hides: 3 sentinel(s) |
| 0:18.300 | tap | `fm-checkout-address` · reveal |
| 0:19.650 | type | "77 Sentinel Quay, Flat 12" into `fm-checkout-address` (25 × 120 ms) |
| 0:22.850 | tap | `fm-checkout-city` · reveal |
| 0:24.200 | type | "Bergen" into `fm-checkout-city` (6 × 120 ms) |
| 0:25.120 | tap | `fm-checkout-postcode` · reveal |
| 0:26.470 | type | "5003" into `fm-checkout-postcode` (4 × 120 ms) |
| 0:27.150 | tap | `fm-checkout-country` · reveal |
| 0:28.500 | checkpoint | **s5-country-open** (picker), settle 400 ms<br>shows: "Choose country" · hides: 4 sentinel(s) |
| 0:29.400 | pick | `fm-checkout-country` · "Norway" |
| 0:32.600 | tap | `fm-checkout-date` · reveal |
| 0:33.950 | checkpoint | **s5-date-open** (picker), settle 400 ms<br>shows: "Choose delivery date" · hides: 4 sentinel(s) |
| 0:34.850 | pick | `fm-checkout-date` · "+14d" |
| 0:37.550 | tap | `fm-checkout-window-1` · reveal |
| 0:38.900 | tap | `fm-checkout-door` · reveal |
| 0:40.250 | tap | `fm-checkout-gift` · reveal |
| 0:41.600 | tap | `fm-checkout-giftnote` · reveal |
| 0:42.950 | type | "Happy birthday from all of us at the harbour office. Enjoy!!" into `fm-checkout-giftnote` (60 × 120 ms) |
| 0:50.350 | checkpoint | **s5-delivery-done**, settle 400 ms<br>shows: "Checkout", "Gift note" · masked: `fm-checkout-giftnote` · hides: 4 sentinel(s) |
| 0:51.250 | tap | `fm-checkout-card` · reveal |
| 0:52.600 | type | "5105 1051 0510 5100" into `fm-checkout-card` (19 × 120 ms) |
| 0:55.080 | tap | `fm-checkout-expiry` |
| 0:55.530 | type | "12/29" into `fm-checkout-expiry` (5 × 120 ms) |
| 0:56.330 | tap | `fm-checkout-cvv` |
| 0:56.780 | type | "7391" into `fm-checkout-cvv` (4 × 120 ms) |
| 0:57.460 | checkpoint | **s5-payment-typed**, settle 400 ms<br>shows: "Checkout", "CVV" · masked: `fm-checkout-card`, `fm-checkout-cvv` · hides: 6 sentinel(s) |
| 0:58.360 | tap | `fm-checkout-cardname` · reveal |
| 0:59.710 | type | "Ada Fieldtest" into `fm-checkout-cardname` (13 × 120 ms) |
| 1:01.470 | tap | `fm-checkout-savecard` · reveal |
| 1:02.820 | drag | `fm-checkout-tip` · 0.02,0.5 → 0.5,0.5, 800 ms · reveal |
| 1:04.720 | drag | `fm-checkout-tip` · 0.5,0.5 → 0.667,0.5, 500 ms |
| 1:05.420 | checkpoint | **s5-tip**, settle 400 ms<br>shows: "Tip", "Save card" · hides: 6 sentinel(s) |
| 1:06.320 | tap | `fm-checkout-promo` · reveal |
| 1:07.670 | type | "FIELD1" into `fm-checkout-promo` (6 × 120 ms) |
| 1:08.590 | checkpoint | **s5-promo-open** (menu), settle 700 ms<br>shows: "FIELD10", "FIELD15" · hides: 6 sentinel(s) |
| 1:09.790 | tap | `fm-checkout-promo-option-0` |
| 1:10.240 | checkpoint | **s5-payment-done**, settle 400 ms<br>shows: "Checkout", "Promo code" · masked: `fm-checkout-cardname` · hides: 6 sentinel(s) |
| 1:11.140 | tap | `fm-checkout-terms` · reveal |
| 1:12.490 | checkpoint | **s5-terms-open** (dialog), settle 400 ms<br>shows: "Terms and conditions", "I agree" · hides: 6 sentinel(s) |
| 1:13.390 | fling | `fm-checkout-terms-text` · up, 0.6, 250 ms |
| 1:14.240 | fling | `fm-checkout-terms-text` · up, 0.6, 250 ms |
| 1:15.090 | tap | `fm-checkout-terms-agree` · reveal |
| 1:16.440 | tap | `fm-checkout-menu` · reveal |
| 1:17.790 | checkpoint | **s5-menu-open** (menu), settle 400 ms<br>shows: "Ring the bell", "Call on arrival", "Leave with a neighbour", "No instructions" · hides: 6 sentinel(s) |
| 1:18.690 | tap | `fm-checkout-menu-item-2` |
| 1:19.140 | tap | `fm-checkout-edit` · reveal |
| 1:20.490 | checkpoint | **s5-sheet-open** (sheet), settle 400 ms<br>shows: "Edit items", "Done" · hides: 6 sentinel(s) |
| 1:21.390 | tap | `fm-checkout-edit-plus-0` |
| 1:21.840 | tap | `fm-checkout-edit-plus-0` |
| 1:22.290 | tap | `fm-checkout-edit-done` |
| 1:22.740 | tap | `fm-checkout-rating-4` · reveal |
| 1:24.090 | tap | `fm-checkout-notes` · reveal |
| 1:25.440 | paste | 500 characters into `fm-checkout-notes` |
| 1:25.940 | checkpoint | **s5-review**, settle 400 ms<br>shows: "How was checkout?", "Place order" · masked: `fm-checkout-loyalty` · hides: 7 sentinel(s) |
| 1:26.840 | tap | `fm-checkout-place` · reveal |
| 1:28.190 | checkpoint | **s5-success**, settle 1000 ms<br>shows: "Order placed" · hides: 7 sentinel(s) |

## S6 — A shopper's session

300 s · measured · 154 steps · 45 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s6-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:08.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:18.200 | checkpoint | **s6-grid-1**, settle 1300 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:21.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:24.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:28.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:31.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:34.200 | checkpoint | **s6-grid-2**, settle 1300 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:36.500 | tap | `fm-home-logo` |
| 0:37.800 | checkpoint | **s6-home-top**, settle 400 ms<br>shows: "Fieldmart", "Today's deals", "Outdoor" |
| 0:39.500 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 0:41.500 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 0:43.500 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 0:45.000 | checkpoint | **s6-deals**, settle 600 ms<br>shows: "Fieldmart", "Today's deals" |
| 0:48.000 | tap | `fm-home-chip-3` · reveal |
| 0:50.500 | checkpoint | **s6-category**, settle 800 ms<br>shows: "Home Office", "Meadow Canvas Desk Chair" |
| 0:56.000 | tap | `fm-home-product-17` · reveal |
| 0:59.000 | checkpoint | **s6-product**, settle 800 ms<br>shows: "Cedar Oak Desk Lamp", "Vellowmark", "$104.00", "Add to cart" |
| 1:01.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 1:03.500 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 1:06.000 | fling | `fm-product-gallery` · left, 0.6, 200 ms |
| 1:07.500 | checkpoint | **s6-gallery**, settle 400 ms<br>shows: "4 / 8", "Add to cart" |
| 1:09.500 | tap | `fm-product-size-2` · reveal |
| 1:12.000 | tap | `fm-product-colour-5` · reveal |
| 1:14.500 | checkpoint | **s6-variants**, settle 400 ms<br>shows: "Size", "Colour", "Add to cart" |
| 1:16.000 | tap | `fm-product-helpful-r17-0` · reveal |
| 1:18.500 | checkpoint | **s6-reviews-top**, settle 400 ms<br>shows: "Oskar G.", "Add to cart" |
| 1:20.000 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 1:22.500 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 1:25.000 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 1:27.500 | fling | `fm-product-reviews` · up, 0.6, 250 ms |
| 1:29.800 | checkpoint | **s6-reviews**, settle 1200 ms<br>shows: "Add to cart" |
| 1:32.000 | tap | `fm-product-add` |
| 1:32.600 | checkpoint | **s6-added** (toast), settle 500 ms<br>shows: "Added to cart" |
| 1:36.000 | tap | `fm-nav-back` |
| 1:37.300 | checkpoint | **s6-back-home**, settle 800 ms<br>shows: "Fieldmart", "Home" |
| 1:40.000 | tap | `fm-home-search` · reveal |
| 1:42.000 | checkpoint | **s6-search**, settle 600 ms<br>shows: "Search", "Search products" |
| 1:43.000 | tap | `fm-search-field` |
| 1:43.300 | type | "trail" into `fm-search-field` (5 × 120 ms) |
| 1:44.500 | checkpoint | **s6-search-results**, settle 900 ms<br>shows: "Trail Cork Pet Bowl", "Trail Weekender" |
| 1:46.800 | tap | `fm-search-result-1` |
| 1:48.300 | checkpoint | **s6-search-product**, settle 800 ms<br>shows: "Trail Weekender", "$458.49", "Add to cart" |
| 1:52.000 | tap | `fm-nav-back` |
| 1:53.300 | checkpoint | **s6-search-back**, settle 600 ms<br>shows: "Search", "Trail Cork Pet Bowl" |
| 1:56.000 | tap | `fm-nav-back` · reveal |
| 1:58.000 | checkpoint | **s6-home-again**, settle 600 ms<br>shows: "Fieldmart", "Home" |
| 2:02.000 | tap | `fm-nav-markets` |
| 2:03.800 | checkpoint | **s6-markets**, settle 400 ms<br>shows: "HEAM", "1H", "1D", "Markets" |
| 2:11.000 | checkpoint | **s6-markets-watch**, settle 400 ms<br>shows: "HEAM", "Markets" |
| 2:16.000 | tap | `fm-markets-tf-1W` |
| 2:17.200 | checkpoint | **s6-markets-1W**, settle 600 ms<br>shows: "HEAM", "1W", "Markets" |
| 2:19.000 | drag | `fm-markets-chart` · 0.15,0.5 → 0.85,0.5, 3000 ms, hold |
| 2:22.100 | checkpoint | **s6-crosshair** (finger held), settle 200 ms<br>shows: "HEAM", "Markets" |
| 2:22.700 | release |  |
| 2:24.000 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms · reveal |
| 2:26.200 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 2:28.400 | fling | `fm-markets-watchlist` · up, 0.6, 250 ms |
| 2:29.500 | checkpoint | **s6-watchlist**, settle 1000 ms<br>shows: "Markets", "Feed" |
| 2:31.500 | tap | `fm-nav-feed` |
| 2:33.000 | checkpoint | **s6-feed-top**, settle 400 ms<br>shows: "Activity", "Week 1", "HARS moved up 0.18 %" |
| 2:34.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:35.900 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:37.300 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:38.700 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:40.100 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:41.500 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:42.900 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:44.300 | fling | `fm-feed-list` · up, 0.6, 250 ms |
| 2:46.000 | tap | `fm-feed-jump-end` |
| 2:46.800 | checkpoint | **s6-feed-end**, settle 800 ms<br>shows: "Activity", "Message from Hanna O." |
| 2:48.500 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 2:49.900 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 2:51.300 | fling | `fm-feed-list` · down, 0.6, 250 ms |
| 2:52.400 | checkpoint | **s6-feed-back**, settle 1200 ms<br>shows: "Activity", "Jump to end" |
| 2:54.500 | tap | `fm-nav-checkout` · reveal |
| 2:55.950 | checkpoint | **s6-form-empty**, settle 400 ms<br>shows: "Checkout", "Contact", "Full name", "Email" |
| 2:56.850 | tap | `fm-checkout-name` |
| 2:57.300 | type | "Ada Fieldtest" into `fm-checkout-name` (13 × 120 ms) |
| 2:59.060 | checkpoint | **s6-name-typed**, settle 400 ms<br>shows: "Checkout", "Full name" · masked: `fm-checkout-name` · hides: 1 sentinel(s) |
| 2:59.960 | tap | `fm-checkout-email` |
| 3:00.410 | type | "ada.fieldtest@example.test" into `fm-checkout-email` (26 × 120 ms) |
| 3:03.730 | tap | `fm-checkout-phone` |
| 3:04.180 | type | "4155550188" into `fm-checkout-phone` (10 × 120 ms) |
| 3:05.580 | tap | `fm-checkout-account` · reveal |
| 3:06.930 | tap | `fm-checkout-password` · reveal |
| 3:08.280 | type | "Zx9!fieldmart-PW" into `fm-checkout-password` (16 × 120 ms) |
| 3:10.400 | checkpoint | **s6-contact-done**, settle 400 ms<br>shows: "Checkout", "Password" · masked: `fm-checkout-password` · hides: 3 sentinel(s) |
| 3:11.300 | tap | `fm-checkout-address` · reveal |
| 3:12.650 | type | "77 Sentinel Quay, Flat 12" into `fm-checkout-address` (25 × 120 ms) |
| 3:15.850 | tap | `fm-checkout-city` · reveal |
| 3:17.200 | type | "Bergen" into `fm-checkout-city` (6 × 120 ms) |
| 3:18.120 | tap | `fm-checkout-postcode` · reveal |
| 3:19.470 | type | "5003" into `fm-checkout-postcode` (4 × 120 ms) |
| 3:20.150 | tap | `fm-checkout-country` · reveal |
| 3:21.500 | checkpoint | **s6-country-open** (picker), settle 400 ms<br>shows: "Choose country" · hides: 4 sentinel(s) |
| 3:22.400 | pick | `fm-checkout-country` · "Norway" |
| 3:25.600 | tap | `fm-checkout-date` · reveal |
| 3:26.950 | checkpoint | **s6-date-open** (picker), settle 400 ms<br>shows: "Choose delivery date" · hides: 4 sentinel(s) |
| 3:27.850 | pick | `fm-checkout-date` · "+14d" |
| 3:30.550 | tap | `fm-checkout-window-1` · reveal |
| 3:31.900 | tap | `fm-checkout-door` · reveal |
| 3:33.250 | tap | `fm-checkout-gift` · reveal |
| 3:34.600 | tap | `fm-checkout-giftnote` · reveal |
| 3:35.950 | type | "Happy birthday from all of us at the harbour office. Enjoy!!" into `fm-checkout-giftnote` (60 × 120 ms) |
| 3:43.350 | checkpoint | **s6-delivery-done**, settle 400 ms<br>shows: "Checkout", "Gift note" · masked: `fm-checkout-giftnote` · hides: 4 sentinel(s) |
| 3:44.250 | tap | `fm-checkout-card` · reveal |
| 3:45.600 | type | "5105 1051 0510 5100" into `fm-checkout-card` (19 × 120 ms) |
| 3:48.080 | tap | `fm-checkout-expiry` |
| 3:48.530 | type | "12/29" into `fm-checkout-expiry` (5 × 120 ms) |
| 3:49.330 | tap | `fm-checkout-cvv` |
| 3:49.780 | type | "7391" into `fm-checkout-cvv` (4 × 120 ms) |
| 3:50.460 | checkpoint | **s6-payment-typed**, settle 400 ms<br>shows: "Checkout", "CVV" · masked: `fm-checkout-card`, `fm-checkout-cvv` · hides: 6 sentinel(s) |
| 3:51.360 | tap | `fm-nav-more` · reveal |
| 3:52.910 | tap | `fm-more-diag` · reveal |
| 3:54.260 | checkpoint | **s6-diag**, settle 400 ms<br>shows: "Diagnostics", "Report handled error" · hides: 6 sentinel(s) |
| 3:55.160 | tap | `fm-diag-handled` · reveal |
| 3:56.510 | checkpoint | **s6-diag-handled**, settle 600 ms<br>shows: "Diagnostics", "Run" · hides: 6 sentinel(s) |
| 3:57.610 | tap | `fm-nav-checkout` · reveal |
| 3:58.960 | checkpoint | **s6-form-kept**, settle 400 ms<br>shows: "Checkout", "More" · hides: 6 sentinel(s) |
| 3:59.860 | tap | `fm-checkout-cardname` · reveal |
| 4:01.210 | type | "Ada Fieldtest" into `fm-checkout-cardname` (13 × 120 ms) |
| 4:02.970 | tap | `fm-checkout-savecard` · reveal |
| 4:04.320 | drag | `fm-checkout-tip` · 0.02,0.5 → 0.5,0.5, 800 ms · reveal |
| 4:06.220 | drag | `fm-checkout-tip` · 0.5,0.5 → 0.667,0.5, 500 ms |
| 4:06.920 | checkpoint | **s6-tip**, settle 400 ms<br>shows: "Tip", "Save card" · hides: 6 sentinel(s) |
| 4:07.820 | tap | `fm-checkout-promo` · reveal |
| 4:09.170 | type | "FIELD1" into `fm-checkout-promo` (6 × 120 ms) |
| 4:10.090 | checkpoint | **s6-promo-open** (menu), settle 700 ms<br>shows: "FIELD10", "FIELD15" · hides: 6 sentinel(s) |
| 4:11.290 | tap | `fm-checkout-promo-option-0` |
| 4:11.740 | checkpoint | **s6-payment-done**, settle 400 ms<br>shows: "Checkout", "Promo code" · masked: `fm-checkout-cardname` · hides: 6 sentinel(s) |
| 4:12.640 | tap | `fm-checkout-terms` · reveal |
| 4:13.990 | checkpoint | **s6-terms-open** (dialog), settle 400 ms<br>shows: "Terms and conditions", "I agree" · hides: 6 sentinel(s) |
| 4:14.890 | fling | `fm-checkout-terms-text` · up, 0.6, 250 ms |
| 4:15.740 | fling | `fm-checkout-terms-text` · up, 0.6, 250 ms |
| 4:16.590 | tap | `fm-checkout-terms-agree` · reveal |
| 4:17.940 | tap | `fm-checkout-menu` · reveal |
| 4:19.290 | checkpoint | **s6-menu-open** (menu), settle 400 ms<br>shows: "Ring the bell", "Call on arrival", "Leave with a neighbour", "No instructions" · hides: 6 sentinel(s) |
| 4:20.190 | tap | `fm-checkout-menu-item-2` |
| 4:20.640 | tap | `fm-checkout-edit` · reveal |
| 4:21.990 | checkpoint | **s6-sheet-open** (sheet), settle 400 ms<br>shows: "Edit items", "Done" · hides: 6 sentinel(s) |
| 4:22.890 | tap | `fm-checkout-edit-plus-0` |
| 4:23.340 | tap | `fm-checkout-edit-plus-0` |
| 4:23.790 | tap | `fm-checkout-edit-done` |
| 4:24.240 | tap | `fm-checkout-rating-4` · reveal |
| 4:25.590 | checkpoint | **s6-review**, settle 400 ms<br>shows: "How was checkout?", "Place order" · masked: `fm-checkout-loyalty` · hides: 7 sentinel(s) |
| 4:26.490 | tap | `fm-checkout-place` · reveal |
| 4:27.840 | checkpoint | **s6-success**, settle 1000 ms<br>shows: "Order placed" · hides: 7 sentinel(s) |
| 4:36.000 | tap | `fm-nav-home` · reveal |
| 4:38.000 | checkpoint | **s6-home-end**, settle 800 ms<br>shows: "Fieldmart", "Home" · hides: 7 sentinel(s) |

## S7a — Exception clip (buffer)

66 s · functional only · variant buffer · 25 steps · 6 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:22.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:25.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:27.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:32.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:35.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.800 | checkpoint | **s1-grid-deep**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:41.000 | tap | `fm-nav-more` · reveal |
| 0:42.550 | tap | `fm-more-diag` · reveal |
| 0:44.000 | checkpoint | **s7a-open**, settle 400 ms<br>shows: "Diagnostics", "Report handled error" |
| 0:44.900 | tap | `fm-diag-handled` · reveal |
| 0:46.350 | checkpoint | **s7a-handled**, settle 600 ms<br>shows: "Diagnostics" |
| 0:47.500 | tap | `fm-nav-home` · reveal |
| 1:04.000 | checkpoint | **s7a-after**, settle 400 ms<br>shows: "Fieldmart", "Home" |

## S7b — Crash

52 s · functional only · variant stream-img · 16 steps · 4 checkpoints

Mobile: the unhandled error ends the process; the driver relaunches it after 5 s. Browser: the error is thrown in a click handler and the page carries on.

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:21.000 | tap | `fm-nav-more` · reveal |
| 0:22.550 | tap | `fm-more-diag` · reveal |
| 0:24.000 | checkpoint | **s7b-open**, settle 400 ms<br>shows: "Diagnostics", "Throw unhandled error" |
| 0:24.900 | tap | `fm-diag-unhandled` · reveal |
| 0:30.500 | relaunch | only flutter-linux, flutter-android, android, ios |
| 0:31.500 | waitFor | `fm-home-grid` · only flutter-linux, flutter-android, android, ios |
| 0:48.000 | checkpoint | **s7b-after**, settle 400 ms<br>shows: "Fieldmart" |

## S7c — Outage

126 s · functional only · variant stream-img · 49 steps · 7 checkpoints

The gateway refuses SDK connections from 21 s to 66 s; browsing goes on; 60 s more after recovery.

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:21.000 | fault | refuse 45 s |
| 0:22.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:25.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:27.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:32.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:35.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.800 | checkpoint | **s1-grid-deep**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:40.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:42.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:45.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:47.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:50.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:52.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:55.000 | tap | `fm-home-logo` |
| 0:56.500 | checkpoint | **s1-top**, settle 400 ms<br>shows: "Fieldmart", "Today's deals", "Outdoor" |
| 0:58.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 0:59.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:00.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:01.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:02.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:03.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:04.400 | checkpoint | **s1-deals**, settle 400 ms<br>shows: "Fieldmart", "Today's deals" |
| 1:06.000 | tap | `fm-home-chip-3` · reveal |
| 1:06.000 | mark | s7c-recovered |
| 1:08.000 | tap | `fm-home-chip-7` · reveal |
| 1:09.800 | checkpoint | **s1-category**, settle 800 ms<br>shows: "Lighting", "Lumen Wall Sconce" |
| 1:18.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:22.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:26.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 1:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:34.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:38.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 1:42.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:46.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:50.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 1:54.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 2:00.000 | checkpoint | **s7c-end**, settle 1200 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |

## S7d — Background and foreground

80 s · functional only · variant stream-img · 12 steps · 4 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-markets` |
| 0:05.000 | checkpoint | **s3-chart**, settle 400 ms<br>shows: "HEAM", "1H", "1D", "1W", "Markets" |
| 0:15.000 | background |  |
| 0:25.000 | foreground |  |
| 0:26.500 | checkpoint | **s7d-foreground-1**, settle 1000 ms<br>shows: "HEAM", "Markets" |
| 0:35.000 | background |  |
| 0:45.000 | foreground |  |
| 0:46.500 | checkpoint | **s7d-foreground-2**, settle 1000 ms<br>shows: "HEAM", "Markets" |
| 0:55.000 | background |  |
| 1:05.000 | foreground |  |
| 1:06.500 | checkpoint | **s7d-foreground-3**, settle 1000 ms<br>shows: "HEAM", "Markets" |

## S7e — Kill and relaunch

80 s · functional only · variant stream-img · 32 steps · 4 checkpoints

Browser: kill closes the page without an ending, relaunch opens the app again in the same browser context.

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:22.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:25.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:27.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:32.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:35.500 | kill |  |
| 0:37.000 | relaunch |  |
| 0:38.500 | waitFor | `fm-home-grid` |
| 0:45.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:47.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:50.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:52.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:55.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:57.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:57.800 | checkpoint | **s7e-relaunched-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 1:00.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:02.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:16.000 | checkpoint | **s7e-after**, settle 1200 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |

## S7f — Hang

18 s · functional only · variant stream-img · 6 steps · 2 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-more` · reveal |
| 0:03.550 | tap | `fm-more-diag` · reveal |
| 0:05.000 | checkpoint | **s7f-open**, settle 400 ms<br>shows: "Diagnostics", "Block main thread" |
| 0:05.900 | tap | `fm-diag-hang` · reveal |
| 0:09.000 | checkpoint | **s7f-after**, settle 1000 ms<br>shows: "Diagnostics" |

## S7g — Failed and slow requests

16 s · functional only · variant stream-img · 7 steps · 2 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-more` · reveal |
| 0:03.550 | tap | `fm-more-diag` · reveal |
| 0:05.000 | checkpoint | **s7g-open**, settle 400 ms<br>shows: "Diagnostics", "Request returning 500" |
| 0:05.900 | tap | `fm-diag-http500` · reveal |
| 0:07.500 | tap | `fm-diag-slow` · reveal |
| 0:10.000 | checkpoint | **s7g-after**, settle 2000 ms<br>shows: "Diagnostics" |

## S7h — Log burst

43 s · functional only · variant stream-img · 6 steps · 2 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-more` · reveal |
| 0:03.550 | tap | `fm-more-diag` · reveal |
| 0:05.000 | checkpoint | **s7h-open**, settle 400 ms<br>shows: "Diagnostics", "Write 1,000 log lines" |
| 0:05.900 | tap | `fm-diag-logs` · reveal |
| 0:40.000 | checkpoint | **s7h-after**, settle 1000 ms<br>shows: "Diagnostics" |

## S7i — Remote rule

90 s · functional only · variant buffer · launch {"fmRemote":"1"} · 41 steps · 7 checkpoints

Live targets only (the rule must reach the SDK over OpAMP). Create the stream rule before launch, delete it after the run.

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:22.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:25.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:27.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:32.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:35.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.800 | checkpoint | **s1-grid-deep**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:40.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:42.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:45.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:47.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:50.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:52.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:55.000 | tap | `fm-home-logo` |
| 0:56.500 | checkpoint | **s1-top**, settle 400 ms<br>shows: "Fieldmart", "Today's deals", "Outdoor" |
| 0:58.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 0:59.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:00.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:01.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:02.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:03.000 | fling | `fm-home-deals` · left, 0.6, 200 ms |
| 1:04.400 | checkpoint | **s1-deals**, settle 400 ms<br>shows: "Fieldmart", "Today's deals" |
| 1:06.000 | tap | `fm-home-chip-3` · reveal |
| 1:08.000 | tap | `fm-home-chip-7` · reveal |
| 1:09.800 | checkpoint | **s1-category**, settle 800 ms<br>shows: "Lighting", "Lumen Wall Sconce" |
| 1:17.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:23.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:26.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 1:28.000 | checkpoint | **s7i-end**, settle 1200 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |

## S7j — Custom data

15 s · functional only · variant stream-img · 7 steps · 2 checkpoints

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:02.000 | tap | `fm-nav-more` · reveal |
| 0:03.550 | tap | `fm-more-diag` · reveal |
| 0:05.000 | checkpoint | **s7j-open**, settle 400 ms<br>shows: "Diagnostics", "Send custom event" |
| 0:05.900 | tap | `fm-diag-event` · reveal |
| 0:07.500 | tap | `fm-diag-message` · reveal |
| 0:10.000 | checkpoint | **s7j-after**, settle 800 ms<br>shows: "Diagnostics" |

## S7k — Tab close

50 s · functional only · variant stream-img · only web · ending close-now · 22 steps · 3 checkpoints

The standard ending is replaced by closing the page at once, while a segment is in progress.

| t | do | what |
|---|---|---|
| 0:00.000 | waitFor | `fm-home-grid` |
| 0:03.000 | checkpoint | **s1-home**, settle 400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Outdoor", "Today's deals" |
| 0:05.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:07.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:10.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:12.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:15.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:17.800 | checkpoint | **s1-grid-mid**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:20.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:22.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:25.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:27.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:30.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:32.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:35.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:37.800 | checkpoint | **s1-grid-deep**, settle 1400 ms<br>shows: "Fieldmart", "Search Fieldmart", "Home", "Markets" |
| 0:40.000 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:42.500 | fling | `fm-home-grid` · up, 0.6, 250 ms |
| 0:45.000 | fling | `fm-home-grid` · down, 0.6, 250 ms |
| 0:47.500 | fling | `fm-home-grid` · down, 0.6, 250 ms |

## S8 — Soak

1200 s · measured · 589 steps · 4 checkpoints

The S6 steps four times in a row (offsets 0, 300, 600 and 900 s) without the diagnostics detour. The S6 checkpoints become marks named `s8-l<loop>-…`; a checkpoint `s8-loop-<n>` is taken 6 s before the end of each loop.

