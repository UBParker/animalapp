# AnimalTracker: iPhone app for AAC button presses, feed, poop, health check-ins, and an oral AI check-in, for any animal

Date: 2026-09-15
Status: approved design v5, awaiting implementation plan
Supersedes: v1 to v4 (HorseButtons, HorseTracker). Same product, generalised from one horse to any number of animals of any species.

## Purpose

Ash keeps animals (currently a horse) and is teaching them to press recordable sound buttons. She wants one app to log button use, feed, poop, and daily wellbeing check-ins per animal, by hand on her iPhone, or by talking once a day to an AI assistant that fills in the records and asks follow-up questions for anything missing. All records stay on the phone; only check-in transcript text is sent to the AI.

## Constraints

- iPhone only, native SwiftUI, iOS 17 minimum. Built with Xcode 26.6 (iOS 26.5 simulator installed), installed on the phone with personal signing.
- No iCloud sync, no analytics, no third-party dependencies. The only network use is the oral check-in, which sends transcript text to the Anthropic Messages API over HTTPS using the user's own API key.
- Any number of animals of any species. One animal is selected at a time; every screen shows that animal's data.
- Logging a button press must be one tap. Logging a normal poop must be two taps. A Health check-in must reach the camera in one tap.
- Photos and videos are stored as files in the app's Documents folder, which is exposed to the Files app for backup. Videos are capped at 60 seconds.

## Top-level navigation

Tab bar with four tabs: **Buttons**, **Feed**, **Poop**, **Health**. Every tab's navigation bar has, on the left, the selected animal's name and avatar as a menu that switches animals or opens Manage Animals; on the right, a microphone icon that opens the oral check-in and a gear icon that opens Settings.

On first launch with zero animals, the app opens Manage Animals with an Add Animal form.

## Data model (SwiftData, local store, `cloudKitDatabase: .none`)

All entities have `id: UUID`, `createdAt: Date`. Enums are stored as String raw values. Every domain record below the Animal has an `animal` relationship; deleting an animal is blocked in the UI while it has records (archive instead).

### Animal

`Animal`: name, species (free text with suggestions: horse, pony, donkey, dog, cat, goat, sheep, cow, pig, chicken, rabbit, other), colorHex, photoFilename (optional, stored like Health media), tracksOutdoorTime (Bool, default true for horse, pony, donkey, goat, sheep, cow, pig, chicken; false otherwise; editable), sortOrder, isArchived, note (optional).

Selected animal id lives in `@AppStorage("selectedAnimalId")`. If it points at an archived or missing animal, the first non-archived animal is selected.

### Buttons domain

`AACButton`: label (the word on the physical button), colorHex (chosen to match the marker on the physical button), sortOrder, isArchived, animal, presses (relationship, no cascade; archive instead of delete when presses exist).

`Press`: timestamp (editable), button (relationship), kind (`PressKind` = prompted | spontaneous), note (optional), editedAt (optional).

### Feed domain

`FeedDay`: date (calendar day, unique per animal, stored as local start-of-day), outdoorHours (Double?, 0 to 24, shown only when the animal tracksOutdoorTime), outdoorAreaAcres (Double?, >= 0, same visibility), note (optional), animal, feedings (cascade delete).

`Feeding`: time (Date), note (optional), day (relationship), items (cascade delete).

`FeedItem`: category (`FeedCategory` = forage | food | supplement | treat), type (free text, e.g. "hay", "Purina Senior", "kibble", "MSM"), amount (Double), unit (free text, e.g. "flakes", "lb", "scoop", "cup", "g"), sortOrder, feeding (relationship).

Hay is a forage item ("hay, 2 flakes"). There are no hay-specific fields. Suggestions for `type` and `unit` are derived at query time from the selected animal's existing FeedItem values per category, most recent first, falling back to all animals.

### Poop domain

`PoopTag`: name, colorHex, isBuiltIn, isHidden, sortOrder. Global across animals. Seeded on first launch with: normal, soft, loose, runny, hard, dry, mucus, blood, green, undigested food, foul smell, small volume, large volume, none today. Built-in tags can be hidden and renamed but not deleted. Custom tags can be deleted only when unused.

`PoopObservation`: timestamp, tags (many-to-many with PoopTag), note (optional), editedAt (optional), animal.

### Health domain

`HealthCheckIn`: timestamp, photoFilename (optional), videoFilename (optional), note (optional), editedAt (optional), animal. At least one of photo, video, or note must be present. Filenames are relative to `Documents/Media/`; files are not stored in SwiftData.

Media files are named `<uuid>-photo.jpg` (JPEG, longest side downscaled to 2048 px, quality 0.85), `<uuid>-video.mov` (as captured, max 60 s), and `<uuid>-thumb.jpg` (300 px). Deleting a check-in deletes its files.

### Oral check-in domain

`OralCheckIn`: startedAt, endedAt (optional), status (`CheckInStatus` = inProgress | reviewed | saved | discarded | failed), model (String), inputTokens, outputTokens, createdRecordIds ([UUID] as JSON string), errorMessage (optional), animal, turns (cascade delete).

`CheckInTurn`: index, role (`user` | `assistant`), text, timestamp, draftJSON (optional, assistant turns only), checkIn (relationship).

### Settings (`@AppStorage`)

| Key | Default | Meaning |
|---|---|---|
| selectedAnimalId | none | current animal |
| sequenceWindowSeconds | 10 | max gap between presses grouped into one sequence |
| defaultPressKind | spontaneous | kind applied on tap unless toggled |
| hasSeededPoopTags | false | one-time seed guard |
| speakQuestions | true | read assistant questions aloud |
| hasAcknowledgedCheckInPrivacy | false | one-time notice guard |
| checkInQuestionCap | 8 | max follow-up questions per session |

The Anthropic API key is stored in the iOS Keychain (service `AnimalTracker`, account `anthropic-api-key`), never in UserDefaults, the store, or exports.

## Manage Animals

List of animals with avatar, name, species. Add (name, species with suggestions, color, optional photo from camera or library, tracksOutdoorTime toggle prefilled by species), edit, reorder, archive/unarchive. Delete allowed only when the animal has no records.

## Buttons tab

Segmented control at the top: Log, History, Stats, Manage. With zero buttons for the selected animal, the tab opens on Manage.

### Log
- Grid of large tiles, one per non-archived button of the selected animal, ordered by sortOrder. Tile background is the button color; label in high-contrast text.
- Segmented toggle above the grid: Spontaneous / Prompted. Starts at the default kind and resets after every logged press.
- Tap a tile: insert a `Press` with `timestamp = now`, the toggle's kind, no note. A 3-second toast reads "Logged Out (spontaneous)" with Undo, which deletes that press.
- Long-press a tile: opens a note sheet for the most recent press of that button if logged within the last 60 seconds; otherwise logs a new press and opens the note sheet.
- Empty state when all buttons are archived: link to Manage.

### History
- List, newest first, sectioned by calendar day.
- Presses grouped into sequences using `sequenceWindowSeconds`. One-press sequence: color dot, label, time, kind badge, note preview. Multi-press sequence: one row with labels joined by arrows ("Out → Treat"), start time, disclosure to the individual presses.
- Swipe to delete a press. Tap to edit timestamp, kind, note.

### Stats
- Range picker: 7 days, 30 days, All.
- Chart 1: presses per button, horizontal bar, stacked prompted vs spontaneous, colored by button.
- Chart 2: presses per day, stacked bar by button.
- Chart 3: time-of-day heatmap, hour by button.
- Sequence table: each distinct ordered sequence of two or more distinct buttons with count, sorted by count. Then per-button repeat counts.
- Empty state when no presses in range.

### Manage
- List of the selected animal's buttons with swatch and label. Add (label + color from a palette of 12 plus custom), rename, recolor, reorder, archive/unarchive. Delete only with zero presses.

## Feed tab

- List of the selected animal's `FeedDay` rows, newest first: date, outdoor hours and acres (if tracked), feeding count. A "Today" button opens today's day card, creating it if missing.
- Day card: outdoorHours and outdoorAreaAcres fields (hidden when the animal does not track outdoor time), note, then feedings in time order, "Add Feeding".
- Feeding editor: time picker; four sections (Forage, Food, Supplements, Treats), each a list of `FeedItem` rows (type with suggestions, amount, unit with suggestions) plus an Add row; note. "Copy last feeding" prefills items from the animal's most recent feeding (excluding the one being edited) and can be undone by cancelling the editor.
- Swipe to delete a feeding or item. Deleting a day requires confirmation.

## Poop tab

- Quick-add bar: tag chips (non-hidden tags in sortOrder, multi-select), a note field, Save. Save inserts a `PoopObservation` for the selected animal at the current time, then clears the selection. Save is disabled with zero tags.
- Below: observations grouped by day, newest first. Row: time, tag chips in tag colors, note preview. Swipe to delete, tap to edit.
- Manage tags lives in Settings.

## Health tab

- Top: a large "Check in" button opening the in-app camera in photo mode, with a switch to video (60 s cap). After capture, a sheet shows the media, an optional note with quick-insert chips (acting normally, lying down more, off food, lethargic, limping, vomiting, coughing, scratching, other), and Save. "Note only" skips media. "From library" attaches an existing photo or video, copied into `Documents/Media/`.
- Below: check-ins grouped by day, newest first, with thumbnail or video badge or note icon, time, note preview. Tap to open full screen: zoomable photo, playable video, editable note and timestamp, Add photo / Add video if missing, Delete with confirmation.
- Camera and library permission strings in Info.plist. If camera permission is denied, Check in opens the note-only sheet with an explanation.

## Oral check-in sheet

Opened from the microphone icon. Applies to the selected animal. First use shows a notice: transcript text, the animal's name and species, button labels, poop tag names and recent feed item types are sent to Anthropic; audio, photos and stored records are not. If no API key is set, the sheet explains and links to Settings.

Flow:
1. **Talk.** A large record button. Speech is transcribed live with `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true` when supported). The live transcript is shown and editable as text before sending. Microphone and speech permission strings in Info.plist; denial shows a text-entry fallback.
2. **Extract.** The transcript is sent to Claude (see Claude request). The response is a `CheckInDraft` plus `missing` and `nextQuestion`.
3. **Follow up.** If `nextQuestion` is non-null and the question count is below `checkInQuestionCap`, the question is shown and, if `speakQuestions`, spoken with `AVSpeechSynthesizer`. The user answers by voice or text; the answer is appended and step 2 repeats with the full history. Saying "done", "skip", "that's all" or tapping Finish ends the loop.
4. **Review.** The draft is mapped onto records for the selected animal: today's `FeedDay` (created or updated), zero or more `Feeding`s with `FeedItem`s, at most one `PoopObservation`, at most one `HealthCheckIn` (note only). Each shown with its tab's editor. Token usage shown. Save commits all in one transaction and marks the `OralCheckIn` saved; Cancel marks it discarded but keeps the turns.

Required fields, asked one at a time in this order: outdoor hours and area (only if the animal tracksOutdoorTime); forage fed and how much; food fed, type and amount; supplements given; poop normal or which tags; any wellbeing concern. Declined fields stay blank and are not asked again.

`CheckInDraft` (Codable, mirrors the JSON schema sent to the API):
- `feedDay`: { outdoorHours: Double?, outdoorAreaAcres: Double?, note: String? }
- `feedings`: [{ time: String? (HH:mm local), items: [{ category: "forage"|"food"|"supplement"|"treat", type: String, amount: Double?, unit: String? }], note: String? }]
- `poop`: { tags: [String] (from the provided list), note: String? }?
- `health`: { note: String? }?
- `missing`: [String] from the fixed field-key list
- `nextQuestion`: String?
- `done`: Bool

Mapping rules: a feeding with null `time` gets the check-in start time. Unknown tags are dropped and listed on Review as "unrecognized: ...". Out-of-range numbers are clamped and flagged. If today's `FeedDay` exists, non-null draft fields overwrite it and Review says so.

### Claude request

- `POST https://api.anthropic.com/v1/messages` with `x-api-key`, `anthropic-version: 2023-06-01`, and the server-side fallback beta header. Body: `model: "claude-opus-5"`, `max_tokens: 4096`, `thinking: {type: "adaptive"}`, `fallbacks: "default"`, `output_config.format` = the `CheckInDraft` JSON schema (strict), `system` = fixed prompt, `messages` = conversation so far. Exact header names and body shape are taken from the bundled API reference at implementation time, not from memory.
- System prompt: role (assistant filling an animal care log), the animal's name and species, whether outdoor time is tracked, today's date and local time, button labels, the poop tag list, up to 20 recent feed item types and 10 units as vocabulary hints, the required-field list and question order, instructions to ask exactly one short question at a time (under 20 words), never invent values, set `done` when nothing required is missing or the user declines.
- Response handling: check `stop_reason` first. `end_turn` with parseable JSON proceeds. `refusal` or unparseable JSON opens Review with an empty draft and the raw transcript; the `OralCheckIn` is marked failed with the reason. `max_tokens` retries once asking for brevity.
- `URLSession`, 60 s timeout, one automatic retry on connection failure or HTTP 429/5xx. No streaming.
- `ClaudeClient` is a protocol with a live `URLSession` implementation and a scripted test double.

## Logic (pure, testable, no SwiftData imports)

Snapshot structs (`PressSnapshot`, `FeedingSnapshot`, `PoopSnapshot`, `HealthSnapshot`, `AnimalSnapshot`) mirror the models so logic and IO tests never touch the container.

`Sequencer.group(presses, window) -> [Sequence]`: input sorted ascending; consecutive presses with gap <= window join a sequence.

`StatsAggregator`: `countsPerButton`, `countsPerDay`, `hourHeatmap`, `sequenceCounts` (>= 2 distinct labels), `repeatCounts` (1 distinct label, >= 2 presses).

`FeedSuggestions.types(items, category)` and `.units(items)`: distinct, most recent first, case-insensitive dedupe keeping most recent casing.

`SpeciesDefaults.tracksOutdoorTime(species) -> Bool`.

`CheckInSession` (`@Observable` state machine): idle -> recording -> extracting -> asking -> recording ... -> reviewing -> saved | discarded | failed. Depends only on `ClaudeClient` and `Transcriber` protocols.

`DraftMapper.map(draft, animal, today, existingDay, tags, now) -> MappedRecords` with `warnings`.

`ClaudeRequestBuilder.build(system, messages, schema) -> URLRequest` and `ClaudeResponseParser.parse(data) -> ClaudeResponse` (stop reason, JSON text, usage), tested against recorded fixtures.

`MediaStore` protocol (file-backed implementation plus in-memory test double): `savePhoto`, `saveVideo`, `thumbnail`, `delete`. Downscaling and thumbnail generation are pure functions over image data.

## Data handling

- Export via share sheet from Settings, all animals, with an `animal` column on every CSV row:
  - `presses.csv`: `animal,timestamp_iso8601,button,kind,note`
  - `feedings.csv`: one row per FeedItem: `animal,date,outdoor_hours,outdoor_area_acres,feeding_time_iso8601,category,type,amount,unit,feeding_note`. A feeding with no items produces one row with empty item columns.
  - `poop.csv`: `animal,timestamp_iso8601,tags (pipe-separated),note`
  - `health.csv`: `animal,timestamp_iso8601,photo_filename,video_filename,note`
  - `animal-tracker.json`: `{ "version": 3, "animals", "buttons", "presses", "feedDays", "feedings", "feedItems", "poopTags", "poopObservations", "healthCheckIns", "oralCheckIns", "checkInTurns" }`. Media files are not embedded; they live in `Documents/Media/`, visible in the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).
- Import JSON: merges by id (update existing, insert new). Shows counts and asks for confirmation. Check-ins with missing media show a placeholder.
- Undo covers only the last logged press. All other changes go through edit screens.

## Error handling

- SwiftData save failures surface as an alert; the change is not shown as saved.
- Import rejects unknown `version` or dangling references (record to missing animal, press to missing button, item to missing feeding, observation to missing tag), naming the problem.
- Deleting an animal with records, a button with presses, or a tag in use is blocked with an explanation to archive or hide instead.
- Numeric clamps: outdoor hours 0 to 24, acres and amounts >= 0.
- Oral check-in: missing API key, denied microphone or speech permission, no network, HTTP errors (401, 429, 5xx), refusal, unparseable output each show a specific message; the transcript is never lost; Review is always reachable.
- Media write failures surface as an alert and the check-in is not saved. Missing files on disk show a placeholder.

## Project layout

```
AnimalTracker/
  AnimalTrackerApp.swift, RootTabView.swift, AnimalSwitcher.swift
  Models/Animal.swift, AACButton.swift, Press.swift, FeedDay.swift, Feeding.swift, FeedItem.swift, PoopTag.swift, PoopObservation.swift, HealthCheckIn.swift, OralCheckIn.swift, CheckInTurn.swift, Enums.swift
  Logic/Snapshots.swift, Sequencer.swift, StatsAggregator.swift, FeedSuggestions.swift, SpeciesDefaults.swift, PoopTagSeed.swift, ImageProcessing.swift
  Media/MediaStore.swift, FileMediaStore.swift, CameraCaptureView.swift
  CheckIn/CheckInDraft.swift, CheckInSchema.swift, CheckInSession.swift, DraftMapper.swift, ClaudeClient.swift, ClaudeRequestBuilder.swift, ClaudeResponseParser.swift, Transcriber.swift, SpeechTranscriber.swift, QuestionSpeaker.swift, KeychainStore.swift
  Views/Animals/, Buttons/ (Log, History, Stats, Manage), Feed/, Poop/, Health/, CheckIn/ (sheet, review), Settings/, Shared/
  IO/CSVExporter.swift, JSONExporter.swift, JSONImporter.swift
AnimalTrackerTests/
  SequencerTests, StatsAggregatorTests, FeedSuggestionsTests, SpeciesDefaultsTests, ImageProcessingTests, MediaStoreTests, CSVExporterTests, JSONRoundTripTests,
  CheckInSessionTests, DraftMapperTests, ClaudeRequestBuilderTests, ClaudeResponseParserTests (fixtures incl. refusal and malformed JSON)
```

## Testing

- XCTest unit tests for every file under Logic/, IO/, and CheckIn/ (except the live URLSession, speech and TTS wrappers), written test-first.
- Manual smoke test on the iOS 26.5 simulator: add two animals (a horse with outdoor tracking, a dog without); for the horse create three buttons, log presses, verify undo, sequence grouping, charts; create today's feed day with two feedings using Copy Last Feeding; log two poop observations; take a note-only health check-in and a library-photo check-in; switch to the dog and confirm every tab is empty and the outdoor fields are hidden; export all files and re-import the JSON into a fresh install; run an oral check-in with the text-entry fallback.
- On the phone: camera capture, video capture, and one real oral check-in by voice with a real API key.

## Out of scope

Automatic press detection by microphone, cloud sync, cross-animal or cross-domain correlation views, reminders, widgets, watch app, photo editing, media compression settings, extracting button presses from speech, sending audio or photos to the AI, streaming responses, species-specific feed templates beyond the outdoor-time toggle.
