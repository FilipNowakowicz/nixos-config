"""The tray's registry (org.kde.StatusNotifierWatcher), kept apart from the shell.

Apps put their tray icons here and the shell reads them. When the shell owned the
registry, every shell restart took it away, and Spotify (Chromium) aborted each time
it vanished. Run on its own, it outlives the shell; the shell finds it and only acts
as the tray's host.
"""

import asyncio

from dbus_next import BusType, Message, MessageType
from dbus_next.aio import MessageBus
from dbus_next.service import PropertyAccess, ServiceInterface, dbus_property, method, signal

NAME = "org.kde.StatusNotifierWatcher"
PATH = "/StatusNotifierWatcher"


class Watcher(ServiceInterface):
    def __init__(self):
        super().__init__(NAME)
        self.items = []  # "bus name/object path" of each icon
        self.hosts = set()

    # Declared so callers see them; main() answers them, as they need the caller.
    @method()
    def RegisterStatusNotifierItem(self, service: "s"):
        pass

    @method()
    def RegisterStatusNotifierHost(self, service: "s"):
        pass

    @dbus_property(access=PropertyAccess.READ)
    def RegisteredStatusNotifierItems(self) -> "as":
        return self.items

    @dbus_property(access=PropertyAccess.READ)
    def IsStatusNotifierHostRegistered(self) -> "b":
        return bool(self.hosts)

    @dbus_property(access=PropertyAccess.READ)
    def ProtocolVersion(self) -> "i":
        return 0

    @signal()
    def StatusNotifierItemRegistered(self, item: "s") -> "s":
        return item

    @signal()
    def StatusNotifierItemUnregistered(self, item: "s") -> "s":
        return item

    @signal()
    def StatusNotifierHostRegistered(self):
        pass

    @signal()
    def StatusNotifierHostUnregistered(self):
        pass

    def add_item(self, item):
        if item not in self.items:
            self.items.append(item)
            self.StatusNotifierItemRegistered(item)
            self.emit_properties_changed({"RegisteredStatusNotifierItems": self.items})

    def add_host(self, name):
        if name not in self.hosts:
            self.hosts.add(name)
            self.StatusNotifierHostRegistered()
            self.emit_properties_changed({"IsStatusNotifierHostRegistered": True})

    def gone(self, name):
        """A bus name lost its owner: forget its icons, or it as a host."""
        for item in [i for i in self.items if i.split("/", 1)[0] == name]:
            self.items.remove(item)
            self.StatusNotifierItemUnregistered(item)
            self.emit_properties_changed({"RegisteredStatusNotifierItems": self.items})
        if name in self.hosts:
            self.hosts.discard(name)
            self.StatusNotifierHostUnregistered()
            self.emit_properties_changed({"IsStatusNotifierHostRegistered": bool(self.hosts)})


async def main():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()
    watcher = Watcher()
    bus.export(PATH, watcher)

    # The register calls need the caller's bus name, which dbus-next's methods don't
    # see, so they are answered here before it would handle them.
    def handle(msg):
        if msg.message_type != MessageType.METHOD_CALL or msg.interface != NAME:
            return None
        if msg.member == "RegisterStatusNotifierItem":
            service = msg.body[0]
            # Apps pass either their object path or a bus name.
            if service.startswith("/"):
                watcher.add_item(msg.sender + service)
            else:
                watcher.add_item(service + "/StatusNotifierItem")
        elif msg.member == "RegisterStatusNotifierHost":
            watcher.add_host(msg.body[0] if msg.body and msg.body[0] else msg.sender)
        else:
            return None
        return Message.new_method_return(msg)

    bus.add_message_handler(handle)

    def owner_changed(msg):
        if msg.member == "NameOwnerChanged" and msg.body[2] == "":
            watcher.gone(msg.body[0])

    bus.add_message_handler(owner_changed)
    await bus.call(Message(
        destination="org.freedesktop.DBus", path="/org/freedesktop/DBus", interface="org.freedesktop.DBus",
        member="AddMatch", signature="s",
        body=["type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'"]))
    await bus.request_name(NAME)
    await bus.wait_for_disconnect()


asyncio.run(main())
