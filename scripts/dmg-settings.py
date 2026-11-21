# dmgbuild settings for Ferry's disk image (scripts/make-dmg.sh passes `app` and `background`).
# dmgbuild writes the window's .DS_Store itself, so no Finder or AppleScript is involved.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}

background = defines["background"]  # noqa: F821
# Finder's window bounds are its frame, title bar included: 28 pt above the 640 x 400 background
# (Design/DMG/background.svg). Not yet checked on screen in Finder.
window_rect = ((200, 120), (640, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
# Icon centres, from the window's top left; Design/DMG/background.svg draws the arrow between.
icon_locations = {os.path.basename(app): (170, 180), "Applications": (470, 180)}
