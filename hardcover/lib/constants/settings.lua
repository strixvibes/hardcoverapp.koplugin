local Settings = {
  ALWAYS_SYNC = "always_sync",
  ASK_RATING = "ask_rating_on_finish",
  AUTO_READING = "auto_reading",
  AUTO_FINISHING = "auto_finishing",
  AUTO_MODE = {
    OFF = "off",
    ASK = "ask",
    AUTO = "auto",
  },
  BOOKS = "books",
  COMPATIBILITY_MODE = "compatibility_mode",
  LINK_BY_HARDCOVER = "link_by_hardcover",
  LINK_BY_ISBN = "link_by_isbn",
  LINK_BY_TITLE = "link_by_title",
  MENU_CONFIRMATION = "menu_confirmation",
  READING_AFTER = "reading_after_type",
  READING_AFTER_MINUTES = "reading_after_minutes",
  READING_AFTER_PERCENT = "reading_after_percent",
  READING_AFTER_TYPE = {
    PERCENT = "percent",
    MINUTES = "minutes",
  },
  SUPPRESS_NOTIFICATIONS = "suppress_notifications",
  TRACK_FREQUENCY = "track_frequency",
  TRACK_METHOD = "track_method",
  TRACK_PERCENTAGE = "track_percentage",
  TRACK = {
    FREQUENCY = "frequency",
    PROGRESS = "progress",
  },
  USER_ID = "user_id",
}

Settings.AUTOLINK_OPTIONS = { Settings.LINK_BY_HARDCOVER, Settings.LINK_BY_ISBN, Settings.LINK_BY_TITLE }

return Settings
