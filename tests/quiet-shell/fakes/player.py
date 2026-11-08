#!/usr/bin/env python3
"""A minimal Spotify on MPRIS, so the player controls can be tested without Spotify.

Usage: player.py LOG. Needs dbus-next. Each command it gets is appended to LOG.
"""

import asyncio
import sys

from dbus_next import Variant
from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method

log = sys.argv[1]


def note(text):
    with open(log, "a", encoding="utf-8") as out:
        out.write(text + "\n")


class Root(ServiceInterface):
    def __init__(self):
        super().__init__("org.mpris.MediaPlayer2")

    @dbus_property(access=PropertyAccess.READ)
    def Identity(self) -> "s":
        return "Spotify"

    @dbus_property(access=PropertyAccess.READ)
    def CanQuit(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def CanRaise(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def HasTrackList(self) -> "b":
        return False

    @dbus_property(access=PropertyAccess.READ)
    def SupportedUriSchemes(self) -> "as":
        return []

    @dbus_property(access=PropertyAccess.READ)
    def SupportedMimeTypes(self) -> "as":
        return []


class Player(ServiceInterface):
    def __init__(self):
        super().__init__("org.mpris.MediaPlayer2.Player")
        self.status = "Playing"

    def set_status(self, status):
        self.status = status
        self.emit_properties_changed({"PlaybackStatus": status})

    @method()
    def PlayPause(self):
        note("play-pause")
        self.set_status("Paused" if self.status == "Playing" else "Playing")

    @method()
    def Play(self):
        note("play")
        self.set_status("Playing")

    @method()
    def Pause(self):
        note("pause")
        self.set_status("Paused")

    @method()
    def Next(self):
        note("next")

    @method()
    def Previous(self):
        note("previous")

    @dbus_property(access=PropertyAccess.READ)
    def PlaybackStatus(self) -> "s":
        return self.status

    @dbus_property(access=PropertyAccess.READ)
    def Metadata(self) -> "a{sv}":
        return {
            "mpris:trackid": Variant("o", "/org/mpris/MediaPlayer2/Track/1"),
            "xesam:title": Variant("s", "Test Song"),
            "xesam:artist": Variant("as", ["Test Artist"]),
        }

    @dbus_property(access=PropertyAccess.READ)
    def CanControl(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanPlay(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanPause(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanGoNext(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanGoPrevious(self) -> "b":
        return True

    @dbus_property(access=PropertyAccess.READ)
    def CanSeek(self) -> "b":
        return False


async def main():
    bus = await MessageBus().connect()
    bus.export("/org/mpris/MediaPlayer2", Root())
    bus.export("/org/mpris/MediaPlayer2", Player())
    await bus.request_name("org.mpris.MediaPlayer2.spotify")
    await asyncio.Future()


asyncio.run(main())
