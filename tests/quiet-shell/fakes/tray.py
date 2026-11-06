#!/usr/bin/env python3
"""A minimal StatusNotifierItem, so the tray can be tested without a real tray app.

Usage: tray.py LOG. Needs dbus-next. Each activation is appended to LOG.
"""

import asyncio
import sys

from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method

log = sys.argv[1]


def note(text):
    with open(log, "a", encoding="utf-8") as out:
        out.write(text + "\n")


class Item(ServiceInterface):
    def __init__(self):
        super().__init__("org.kde.StatusNotifierItem")

    @method()
    def Activate(self, x: "i", y: "i"):
        note("activate")

    @method()
    def SecondaryActivate(self, x: "i", y: "i"):
        note("secondary")

    @method()
    def ContextMenu(self, x: "i", y: "i"):
        note("menu")

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> "s":
        return "quiet-test"

    @dbus_property(access=PropertyAccess.READ)
    def Title(self) -> "s":
        return "Quiet test"

    @dbus_property(access=PropertyAccess.READ)
    def Category(self) -> "s":
        return "ApplicationStatus"

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> "s":
        return "Active"

    @dbus_property(access=PropertyAccess.READ)
    def IconName(self) -> "s":
        return "kitty"

    @dbus_property(access=PropertyAccess.READ)
    def ItemIsMenu(self) -> "b":
        return False


async def main():
    bus = await MessageBus().connect()
    bus.export("/StatusNotifierItem", Item())
    await bus.request_name("org.quiet.TestTray")
    intro = await bus.introspect("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher")
    proxy = bus.get_proxy_object("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", intro)
    await proxy.get_interface("org.kde.StatusNotifierWatcher").call_register_status_notifier_item("org.quiet.TestTray")
    await bus.wait_for_disconnect()


asyncio.run(main())
