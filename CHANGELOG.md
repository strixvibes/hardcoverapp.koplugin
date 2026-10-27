# Changelog

## 0.6.0 (2026-10-27)

### Added

- Sign in with Hardcover: the "Sign in to Hardcover" menu item shows a short code and a web address; approve it on your phone or computer and the plugin is connected. No API key or config file is needed.
- The sign-in renews itself automatically. "Signed in to Hardcover (tap to sign out)" signs you out and ends the session on Hardcover.
- The API key still works. If both are present the sign-in is used and the key is kept as a fallback.
- When there is neither a sign-in nor an API key, a box with "Sign in" and "Cancel" buttons appears when KOReader starts and each time the device wakes. It is not hidden by "Suppress all pop-up notifications".
- While not signed in, progress, starts, finishes and ratings are saved in the offline queue, then sent after you sign in (or add a key).

### Changed

- `hardcover_config.lua` is now optional; it is only needed for an API key.
- The sign-in item is the first item in the Hardcover menu. While not signed in, "Sync queued updates now" and "Suggest a book" are greyed out.
- The About page, the version check and the plugin's identification now point to this fork.

## 0.5.0 (2026-10-21)

### Upgrading

- The old per-book "sync" setting is converted automatically to the new "Always sync this book" rules the first time a book is opened. Nothing needs doing.
- The "Wifi on demand" option has been removed. The plugin no longer switches wifi on by itself (KOReader still offers to turn it on for manual actions such as "Sync now").
- Marking a book as finished in KOReader by any other route no longer sends anything to Hardcover. Use the plugin's own "Mark as Read" prompt or automatic updates instead.

### Added

- "Currently Reading" updates: when a book has been read far enough, it is marked Currently Reading on Hardcover and the start date is recorded. Choose Off, Ask first or Automatic.
- "Currently Reading after" setting: choose a percentage of the book (default 5%) or a number of minutes of reading (default 10).
- "Read" updates: when you reach the end of a book, the plugin can ask "Mark this book as Read on Hardcover?" (Ask first) or do it straight away (Automatic). The finish date is recorded, and KOReader's own end-of-book action carries on afterwards.
- Optional star rating: a 0 to 5 star dialog (half-star steps, starting at 2.5, wrapping round at either end, with Skip) shown when a book is marked Read, in Ask first or Automatic mode.
- Offline queue: when Hardcover cannot be reached, starts, progress, finishes and ratings are saved on the device and sent automatically when a connection returns, in the right order and with the correct dates.
- Books that are not linked yet are saved with their title, author and identifiers, and are linked and sent once automatic or manual linking succeeds.
- Menu items for the queue: "Sync N queued updates now", "Pending updates" (tap one to remove it), "Clear queued updates" and "Sync Log" (the last 7 days, newest first).
- Retries: failed updates caused by the network are retried automatically. If Hardcover refuses an update, you are asked after a number of tries (default 3, "Tries before asking") whether to keep or remove it.
- Per-book rules: "Always sync this book" and "Never sync this book", each with Progress, Currently Reading, Read and Rating, plus "Enable all". They override the global settings for that book only.
- Choosing "Never for this book" on the Currently Reading question switches all updates off for that book after confirmation, and clears its queued updates.
- "Reset book data" in KOReader or Bookshelf now also clears a book's Always/Never rules. The Hardcover link is kept.
- Notice when automatic linking finds no match: "No suitable automatic link found; manual linking required".
- "Suppress all pop-up notifications" setting that hides the brief automatic messages (errors and answers to menu actions still show).
- Progress is sent as a page of the edition being read on Hardcover, so the percentage on Hardcover matches the one in KOReader.
- Progress is never moved backwards. If Hardcover already shows a later page, the older update is dropped and a short notice is shown.
- While "Read" updates are on, the last page is not sent as progress, so Hardcover does not mark the book Read by itself.

### Changed

- Settings menu reorganised and reworded into three groups (automatic linking, updates, other), with shorter labels for small screens.
- A book that is already past the Currently Reading threshold when first opened is offered once.
- Switching Currently Reading from Off to Ask first or Automatic offers it again to the book you are reading.
- README rewritten to cover all of the above.

### Fixes

- Fixed duplicate "Marked as Currently Reading" messages and duplicate progress sends.
- Fixed the Currently Reading question not appearing when rules were changed while a book was open.
- Fixed the "no automatic link" state carrying over from one book to the next.

### Chores

- Removed unused code and settings, and moved the setting names into the constants file.


## 0.4.0 (2026-04-26)

### Added

* Added option to show a confirmation when changing a book's currently read status to reduce misclick issues

## 0.3.1 (2026-02-18)

### Added

* Added support for [Updates Manager Plugin](https://github.com/advokatb/updatesmanager.koplugin) (min: v1.4.0)

### Fixes

* Fix page change gestures causing a refresh (even when there are no pages to navigate to) of the suggest a book, and
  book/edition linking dialogs

## 0.3.0 (2026-01-24)

### Added

* Added "suggest a book" to hardcover menu. Displays 10 books from your to-read list at random.
* Plugin will now consider the `hardcover-slug` ebook identifier in addition to `hardcover` identifier (
  by [@yd4dev](https://github.com/yd4dev))

## Fixes

* Fix page map crash when loading document formats that don't support page maps (like CBR)
* Fix page map crash when document is out of range of the active page map

## 0.2.0 (2025-11-22)

### Added

* Publisher page labels will now be used for reading progress without translation
* Percentage calculation used to determine when to create new journal entries now uses the page
  label divided by edition page count. This is weird but ensures that journal reading percentage is close to the
  selected interval
* Plugin will now ignore page mapping if publisher page labels are disabled in KOReader

### Fixes

* Switch to `socket.http` implementation to better support proxy usage

### Chores

* Fix zip release directory structure

## 0.1.3 (2025-09-10)

### Added

* Register action to immediately update reading
  progress [#19](https://github.com/Billiam/hardcoverapp.koplugin/issues/19)
* Add event to open journal entry dialog [#27](https://github.com/Billiam/hardcoverapp.koplugin/issues/27)

## 0.1.2 (2025-05-13)

### Added

* Hardcover menu now visible in both reading view and file manager view
* Sort ebooks above physical books in edition list
* Support [airplane mode plugin](https://github.com/kodermike/airplanemode.koplugin)

### Fixes

* Remove 50 book limit from edition selection

## 0.1.1 (2025-04-12)

### Added

* Reduce data requested from search API endpoint

### Fixes

* Fix missing invalid API key warning after request failure

### Chores

* Remove dependency on coverbrowser plugin

## 0.1.0 (2025-03-21)

### Added

* Prompt to enable wifi if needed before opening journal dialog

### Chores

* Include user agent in requests to hardcover API

### Fixes

* Always show book format and reader count in list view
* Fix potential crash when document is no longer available when fetching book cache
* Fix crash at some font sizes when using compatibility mode and searching for books with long author names
* Fix compatibility mode not displaying authors at some font sizes
* Fix compatibility mode not displaying edition type at some font sizes

## 0.0.8 (2025-01-16)

### Added

* Display edition language and series in book searches
* Add option to turn on/off wifi automatically for background updates on some devices where possible
* Changed manual page update dialog to allow updating by document page or hardcover page with synchronized display

### Fixes

* Fix crash when navigating to previous page in search menu after images have loaded
* Fix crash related to book settings when active document has been closed
* Fall back to less specific reading format when edition format is unavailable
* Fix ISBN values with hyphens being ignored by automatic book linking
* Fix pages exceeding a document's page map being treated as lower numbers than previous page

### Chores

* Renamed lib directory and config.lua to prevent conflicts with other plugins

### ⚠️ Upgrading

The plugin now looks for `hardcover_config.lua` instead of `config.lua`. Rename this file (which contains your API key)
on your device.

## 0.0.7 (2024-12-30)

### Added

* Added option to update books by percentage completed rather than timed updates
* Display error and disable some functionality when Hardcover API indicates that API key is not valid, in preparation
  for [upcoming API key reset](https://github.com/Billiam/hardcoverapp.koplugin/issues/6)
* Allow linking books, enabling/disabling book tracking from KOReader's gesture manager

### Fixes

* Fix crash when linking book from hardcover menu
* Fix automatic book linking not working unless track progress (or always track progress) already set
* Fix manual and automatic book linking not working for hardcover identifiers
* Fix failure to mark book as read when end of book action displays a dialog
* Fix a crash when searching without an internet connection
* Fix page update tracking not working correctly when using "always track progress" setting
* Fix off-by-one page number issue when document contains a page map
* Fix unable to set edition if that edition already set in hardcover

### Chores

* Update default edition selection in journal dialog to use multiple API calls instead of one due to upcoming Hardcover
  API limits
* Fetch book authors from cached column in Hardcover API

## 0.0.6 (2024-12-10)

### Added

* Added compatibility mode with reduced detail in search dialog for incompatible versions of KOReader

### Fixes

* Fix crash when selecting specific edition in journal dialog

## 0.0.5 (2024-12-04)

### Fixes

* Fix failed identifier parsing by Hardcover slug
* Fix error when searching for books by Hardcover identifiers
* Fix note content not saving depending on last focused field
* Fix note failing to save without tags

## 0.0.4 (2024-12-01)

### Fixes

* Fix error when sorting books in Hardcover search

## 0.0.3 (2024-11-29)

### Fixes

* Fixed autolink failing for Hardcover identifiers and title
* Fixed autolink not displaying success notification

## 0.0.2 (2024-11-27)

### Fixes

* Increased default tracking frequency to every 5 minutes
* Skip book data caching if not currently viewing a document
* Fix syntax error in suspense listener
* Only eager cache book data when book tracking enabled (for page updates)
* Fix errors when device resumed without an active document

## 0.0.1 (2024-11-24)

Initial release
