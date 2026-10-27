# Hardcover.app for KOReader

A KOReader plugin to update your [Hardcover.app](https://hardcover.app) reading status, progress and ratings.

This is a fork of [Billiam's hardcoverapp.koplugin](https://github.com/Billiam/hardcoverapp.koplugin). On top of the
original it adds an offline queue, "Currently Reading" and "Read" prompts, an optional star rating prompt, and
per-book "Always sync" / "Never sync" rules.

## Installation

1. Download and extract the plugin.
2. Install the plugin by copying the `hardcoverapp.koplugin` folder to the KOReader plugins folder on your device.
3. Restart KOReader and [sign in to Hardcover](#signing-in), or use an API key (see below).

### Connecting to Hardcover

There are two ways to connect to Hardcover, and both are fully supported. You only need one. Signing in with Hardcover (OAuth) is the preferred option and is listed first; an API key is the alternative.

**Option 1: Sign in with Hardcover (OAuth, preferred)**

1. Open the Hardcover menu in a book and choose `Sign in to Hardcover` (turn wifi on first).
2. The screen shows a web address and a short code. On your phone or computer, go to that address and enter the code.
3. Approve the sign-in on Hardcover. The Kobo shows "Signed in to Hardcover".

The sign-in renews itself, so you should not need to repeat this. `Signed in to Hardcover (tap to sign out)` signs you out: the sign-in is removed from the device and its session is ended on Hardcover. Hardcover may still list the app under Authorized apps; that only records that you once approved it (use `Revoke Access` there to remove it).

**Option 2: API key**

1. Rename `hardcover_config.example.lua` to `hardcover_config.lua`
2. Fetch your API key from https://hardcover.app/account/api (just the part after `Bearer `)
3. Add your API key to the `token` field in `hardcover_config.lua`, between the `''` quotes. For example:
   `token = 'abcde...fghij'`

An API key may only contain letters, digits and the characters `- . _ ~ + / = :` (spaces at either end are ignored). A blank key, or one containing anything else, is reported as invalid straight away. API keys expire after a year.

**Using both**

If you are signed in, the sign-in is used and the API key is kept as a fallback, in case the sign-in stops working (for example if it is revoked on Hardcover). While you are signed in, problems with the API key are not reported. If the sign-in stops working, a short notice says the key is being used instead. Sign out to use the key on its own.

**When nothing is connected**

- No `hardcover_config.lua` file and not signed in: a box offers `Sign in` or `Cancel` when KOReader starts and every time the device wakes.
- `hardcover_config.lua` exists (even with a blank key) and you are not signed in: the plugin reports "Hardcover API key invalid" in the same way, with the same `Sign in` button, so you know the key needs fixing.
- These boxes are never hidden by "Suppress all pop-up notifications". Meanwhile progress, start and finish updates are kept in the offline queue and sent once a connection works.

## Usage

The Hardcover plugin's menu can be found in the Bookmark top menu when a document is active.

Main menu items, in order: the linked book (and its edition), `Always sync this book`, `Never sync this book`,
`Update status`, the offline queue items (see [Offline queue](#offline-queue)), `Suggest a book`, `Settings` and
`About`.

### Linking a book

Before updates can be sent to Hardcover, the plugin needs to know which Hardcover book and/or edition your current
document represents.

You can search for a book by selecting `Link book` from the Hardcover menu. If any books can be found based
on your book's metadata, these will be displayed.

![A dismissable window titled "Select book" with a search button displayed as a magnifying glass in the upper left corner, and a close button on the right. A list of 14 possible books is displayed below this, with buttons to change result pages. The book title ande author are displayed if available, as well as the number of reads by hardcover users and the number of pages if available. Some books display cover images](https://github.com/user-attachments/assets/99d16ef0-6dda-41d8-bfdc-32c97ae09d87)

If you cannot find the book you're looking for, you can tap the magnifying glass icon in the upper left corner and
begin a manual search.

![An input dialog titled "New Search" with the text "Frankenstein Mary Shelley". Behind the dialog, a recent book search result dialog appears with two books](https://github.com/user-attachments/assets/73619448-9821-410a-901f-d8fc61185dd3)

Selecting a Hardcover book or edition will link it to your current document, but will not by itself update your
reading status on Hardcover. That is done manually from the [update status](#updating-reading-status) menu, or
automatically (see [Automatic updates](#automatic-updates)).

Linking only stores the link on your device. It never changes anything on Hardcover.

To clear the currently linked book, tap and hold the `Linked book` menu item for a moment.

After selecting a book, you can set a specific edition using the `Change edition` menu item. This will present a list
of available editions for the currently linked book. No manual edition search is available.

### Updating reading status

![A menu to update book status containing: a set of radio buttons for the current book status (Want to read, currently reading, read and did not finish), an item to unset the current status. The following section has an item to update the current page (displaying page 154 of 353), add a note, update rating (displaying the current rating of 4.5 stars), and an item to update the status privacy settings which open in a submenu](https://github.com/user-attachments/assets/55b33a0a-bda8-4ec9-918d-0409266abe3b)

To change your book status (Want To Read, Currently Reading, Read, Did Not Finish) on Hardcover, you open the
`Update status` menu after [linking your book](#linking-a-book). You can also remove the book from your Hardcover
library using the `Remove` menu item.

From this menu you can also update your current page and book rating, and add a new journal entry.

Tap and hold the book rating menu item to clear your current rating.

Actions in this menu are always manual and are not affected by the automatic settings or the per-book rules below. They
need a connection to Hardcover (KOReader will offer to turn wifi on).

### Add a journal entry quote

Selecting text to quote:

![Book text with two sentences highlighted. KOReader's highlight menu popup is displayed in the center with an option at the end for Hardcover quote](https://github.com/user-attachments/assets/5dba19a4-f72a-4894-820c-0cfdcc55bf68)

![A form window titled "Create journal entry". The previously selected text appears in an input field at the top. Below that is a toggle for whether the journal entry should be a note or a quote. A button to change the journal edition follows, and one to change the current page. Below those, a toggle to change the journal entry privay with the options Public, Follows and Private. Lastly are two input fields to set journal entry tags and spoiler tags respectively, and then buttons to save the entry or close the window](https://github.com/user-attachments/assets/c386f153-330f-4e1f-afa1-12fdf48a1216)

After selecting document text in a linked document, choose `Hardcover quote` from the highlight menu to display the
journal entry form, prefilled with the selected text and page. Journal entries are sent straight away and need a
connection; they are not kept in the offline queue.

## Automatic updates

Everything in this section is optional. Four kinds of update can happen automatically, each with its own setting under
`Settings`:

| Update | Setting | Choices |
|---|---|---|
| Reading progress | `Reading progress updates by default` | on / off |
| Book marked Currently Reading | `'Currently Reading' updates by default` | Off / Ask first / Automatic |
| Book marked Read | `'Read' status updates by default` | Off / Ask first / Automatic |
| Star rating when marked Read | `Rating prompt when marked 'Read' by default` | on / off |

Any of these can be overridden for a single book, see [Per-book rules](#per-book-rules). A book must be linked
(manually or [automatically](#automatic-linking)) for anything to be sent. Books that are not linked yet are
handled through the [offline queue](#offline-queue).

The Currently Reading and Read settings only apply to books that are tracked by default (`Always track progress by
default`), or that have been given their own rule with `Always sync this book`.

### Progress

While reading, your current read on Hardcover is updated at the interval chosen under `Progress updates after`:

* **Update periodically**: at the number of minutes you choose (at most once a minute).
* **Update by progress**: whenever you cross a percentage step (for example every 10%).

For all documents, but in particular for reflowable documents (like epubs), the current page in your reader may not
match that of the original published book. Documents that contain page information are mapped to the published page;
for other documents your position is stored as a percentage of the book and converted to a page of the edition
Hardcover is tracking (`round(percentage * edition_pages)`), so the percentage shown on Hardcover matches the one in
KOReader even when the linked edition has a different number of pages.

Progress is never moved backwards: if Hardcover already shows a later page than an update that was waiting, the older
value is dropped and a short notice is shown.

### Mark as Currently Reading

When you have read far enough (5% of the book by default, or a number of minutes of reading; change it under
`Settings` > `Currently Reading after`), the plugin
marks the book Currently Reading and dates the start of the read: `Ask first` shows a Yes/No question, `Automatic`
does it straight away. Minutes count only time spent turning pages (a pause of over five minutes counts as five). A book that is already past the threshold when you first open it is offered once.

The question also has a `Never for this book` button, which asks for confirmation and then switches all updates off for
that book (see [Per-book rules](#per-book-rules)).

Switching Currently Reading from Off to Ask first or Automatic (globally, or for a book) offers it again to the book
you are reading, whatever percentage it has reached.

### Mark as Read at end of book

When you reach the end of the document, `Ask first` asks "Mark this book as Read on Hardcover?" and `Automatic` does it
without asking. Either way the book is also marked finished in KOReader, and KOReader's own end of book action
(pop-up, next file, ...) carries on afterwards.

While this is switched on, the last page is never sent as progress (Hardcover would otherwise mark the book Read by
itself). Nothing is sent to Hardcover when you mark a book finished in KOReader by any other route.

### Star rating

With `Rating prompt when marked 'Read' by default` on (whether `'Read' status updates by default` is `Ask first` or `Automatic`), a rating dialog opens once the book is marked Read (after answering Yes, or straight away when automatic): 0 to 5 stars in half-star steps (starting at 2.5; pressing past either end wraps round), `Skip` to leave the book unrated. A
book can override this with `Always sync this book` > `Rating` or `Never sync this book` > `Rating`.

## Per-book rules

Each book can follow the global settings, or have its own rules:

* **Always sync this book**: switches things on for this book even when they are off globally.
  * `Progress`: track progress.
  * `Currently Reading` and `Read`: choose `Automatic` or `Ask first` (or `Follow global setting`).
  * `Rating`: ask for a star rating after the book is marked Read.
  * `Enable all` ticks everything.
* **Never sync this book**: switches things off for this book even when they are on globally.
  * The same four items. Ticking one asks for confirmation if updates of that kind are waiting in the offline
    queue, and throws those away.
  * `Enable all` asks "Are you sure you want to disable all updates to Hardcover for this book?" and clears all of its
    waiting updates. Untick it again to return to the global settings.

A setting for a book that is neither Always nor Never follows the global setting. Linking is not affected by these
rules.

Using KOReader's `Reset book data` (document settings, progress, bookmarks, highlights and notes) on a book also clears
its Always/Never rules, so it follows the global settings again and may be offered Currently Reading afresh. The link to
the Hardcover book is kept.

## Offline queue

When Hardcover cannot be reached (wifi off, no internet), the plugin keeps what happens in a small file on your device
and sends it later, without you reopening the books:

* that a book was started, how far you got (as a percentage), and that you finished it, with the correct dates
* the star rating given when finishing
* books that are not linked yet: their title, author and identifiers are kept, and when a connection is available the
  plugin links them using the enabled [automatic linking](#automatic-linking) options before sending. If it cannot, the
  update stays in the queue and the Sync Log says why; linking the book by hand from the Hardcover menu sends it within
  about a minute.

The queue is sent in the background whenever a connection appears, about one request a second, with a short
"Synced to Hardcover" notice at the end. Failed attempts caused by the network are retried automatically; if Hardcover
refuses an update, you are asked after a number of tries (default 3, `Tries before asking` in the menu, 0 = never ask)
whether to keep it or remove it.

Menu items:

* `Sync N queued updates now`: send now (KOReader offers to turn wifi on if needed)
* `Pending updates`: every waiting update, what it contains and why it has not been sent; tap one to remove it
* `Clear queued updates`: remove everything
* `Sync Log`: what was sent or refused in the last 7 days, newest first

The plugin never switches wifi on by itself. When automatic linking finds no match for a book, a short notice says manual linking is needed.

## Suggest a book

The suggest a book menu item will display up to 10 books from your Want To Read list in random order. Selecting one of
the books in the dialog will start a file search for that book on your device, based on the title. The plugin does not
know which books you have or do not have on your device.

The selected books/order are preserved when reopening the dialog (until KOReader is restarted), but you can use the
refresh button in the upper left corner to get a new list of 10 books.

![Suggest a book dialog displaying several books. There is a refresh icon in the upper left corner](https://github.com/user-attachments/assets/2564e0f1-2c62-4463-957f-421a47d792d6)

## Settings

### Automatic linking

With automatic linking enabled, the plugin will attempt to find the matching book and/or edition on Hardcover
when a new document is opened, if no book has been linked already. These options are off by default.

* **Automatically link by ISBN**: If the document contains ISBN or ISBN13 metadata, try to find a matching edition for
  that ISBN
* **Automatically link by Hardcover identifiers**: If the document metadata contains a `hardcover` identifier (with a
  URL slug for the book) or a `hardcover-edition` with an edition ID, try to find the matching book or edition.
  (see: [RobBrazier/calibre-plugins](https://github.com/RobBrazier/calibre-plugins/tree/main/plugins/hardcover))
* **Automatically link by title and author**: If the document metadata contains a title, choose the first book
  returned from Hardcover search results for that title and document author (if available).

### Currently Reading after

Choose a percentage of the book (default 5%) or minutes of reading (default 10). See [Mark as Currently Reading](#mark-as-currently-reading).

### Progress updates after

By default, (when enabled) updates will be sent to Hardcover at a frequency you can select, no more often than once per
minute. If you don't need updates this frequently, and to preserve battery, you can decrease this frequency further.

You can also choose to update based on your percentage progress through a book. With this option, an update will be
sent when you cross a percentage threshold (for example, every 10% completed).

### Reading progress updates by default

When this is enabled, new documents track progress automatically (see [Automatic updates](#automatic-updates)).
You can still turn progress off for a single book with `Never sync this book`.

Books still must be linked (manually or automatically) to send updates to Hardcover.

### Mark as Currently Reading, Mark as Read at end of book, Star rating

See [Automatic updates](#automatic-updates).

### Confirm changes to book read status

By default, changes to a book's read status (Want to Read, Did Not Finish, etc) will immediately update in Hardcover as
soon as you press them. Enable this setting to display a confirmation prompt before those changes are sent.

### Suppress all pop-up notifications

Hides the brief automatic messages (including "Linked to…", Marked as Currently Reading, Marked as Read, Synced to Hardcover, Saved for later, and so on). Error messages and the answers to things you tap in the menu still appear. Off by default.

### Compatibility mode

When enabled, book and edition searches will be displayed in a simplified list with minimal data. This mode is the
default for KOReader versions prior to v2024.07
