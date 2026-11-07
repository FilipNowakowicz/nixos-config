import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    width: 340
    spacing: 8
    property bool compact: false

    // Read on opening, because the shell stays up across midnight.
    property date now: new Date()
    // A day of this month, or 0 while the agenda shows what's next.
    property int picked: 0
    onVisibleChanged: if (visible) { now = new Date(); picked = 0; Sys.refreshWeather(); Sys.refreshAgenda(); }
    function weatherIcon(condition) {
        const c = condition.toLowerCase();
        if (c.includes("thunder")) return "cloud-lightning";
        if (c.includes("snow") || c.includes("sleet") || c.includes("ice")) return "cloud-snow";
        if (c.includes("rain") || c.includes("drizzle") || c.includes("shower")) return "cloud-rain";
        if (c.includes("fog") || c.includes("mist") || c.includes("haze")) return "cloud-fog";
        if (c.includes("cloud") || c.includes("overcast")) return "cloud";
        // wttr.in says Sunny by day and Clear by night.
        if (c.includes("clear")) return "moon";
        return "sun";
    }
    function dateOf(day) { return new Date(now.getFullYear(), now.getMonth(), day); }
    function stamp(date) { return Qt.formatDate(date, "yyyy-MM-dd"); }
    function eventsOn(day) {
        const at = stamp(dateOf(day));
        return Sys.agenda.filter(e => e.day <= at && at <= e.until);
    }
    // Something that began earlier stays on its days, but leaves this list so a
    // week-long event can't hold the top of it all week.
    function upcoming() {
        const today = stamp(now), clock = Qt.formatTime(now, "HH:mm");
        return Sys.agenda.filter(e => e.day > today || e.day === today && (!e.end || e.until > today || e.end > clock)).slice(0, 3);
    }
    function details(event) {
        const time = event.start ? event.start + "–" + event.end : "All day";
        if (picked)
            return [time, event.location].filter(Boolean).join(" · ");
        const relative = { [stamp(now)]: "Today", [stamp(dateOf(now.getDate() + 1))]: "Tomorrow" };
        const day = relative[event.day] || Qt.formatDate(new Date(event.day + "T00:00:00"), "ddd d MMM");
        return [day, event.start, event.location].filter(Boolean).join(" · ");
    }
    function days() {
        const y = now.getFullYear(), m = now.getMonth();
        const first = (new Date(y, m, 1).getDay() + 6) % 7;
        const count = new Date(y, m + 1, 0).getDate();
        const out = [];
        for (let i = 0; i < first; i++) out.push(0);
        for (let d = 1; d <= count; d++) out.push(d);
        return out;
    }

    Item {
        visible: Sys.weather !== null
        Layout.fillWidth: true
        implicitHeight: forecast.implicitHeight + 24
        Glass { anchors.fill: parent; radius: 22 }
        ColumnLayout {
            id: forecast
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Icon { name: Sys.weather ? root.weatherIcon(Sys.weather.condition) : "sun"; size: 24 }
                Column {
                    Layout.fillWidth: true
                    Label { width: parent.width; text: Sys.weather ? Sys.weather.place : ""; font.weight: Font.Medium }
                    Label { width: parent.width; text: Sys.weather ? Sys.weather.condition : ""; font.pixelSize: 12; color: Theme.dim }
                }
                Label { text: Sys.weather ? Sys.weather.temperature : ""; font.pixelSize: 22; font.features: { "tnum": 1 } }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                Repeater {
                    model: Sys.weather ? Sys.weather.hours : []
                    Column {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        spacing: 4
                        Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.time; font.pixelSize: 11; color: Theme.dim; font.features: { "tnum": 1 } }
                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: root.weatherIcon(modelData.condition); size: 16 }
                        Label { anchors.horizontalCenter: parent.horizontalCenter; text: modelData.temperature; font.pixelSize: 12; font.features: { "tnum": 1 } }
                    }
                }
            }
        }
    }
    Item {
        visible: !root.compact
        Layout.fillWidth: true
        implicitHeight: calendar.implicitHeight + 24
        Glass { anchors.fill: parent; radius: 22 }
        Column {
            id: calendar
            x: 14
            y: 12
            width: parent.width - 28
            spacing: 6
            Label { text: Qt.formatDate(root.picked ? root.dateOf(root.picked) : root.now, "dddd d MMMM"); font.weight: Font.DemiBold; font.pixelSize: 15 }
            Grid {
                columns: 7
                width: parent.width
                Repeater {
                    model: ["M", "T", "W", "T", "F", "S", "S"]
                    Label { required property string modelData; width: parent.width / 7; height: 20; horizontalAlignment: Text.AlignHCenter; text: modelData; font.pixelSize: 11; color: Theme.dim }
                }
                Repeater {
                    model: root.days()
                    Press {
                        required property int modelData
                        readonly property bool today: modelData === root.now.getDate()
                        readonly property bool chosen: modelData > 0 && modelData === root.picked
                        width: parent.width / 7
                        height: 24
                        enabled: modelData > 0
                        name: modelData > 0 ? Qt.formatDate(root.dateOf(modelData), "d MMMM") : ""
                        onClicked: root.picked = chosen ? 0 : modelData
                        Rectangle { anchors.centerIn: parent; visible: parent.today || parent.chosen; width: 22; height: 22; radius: 11; color: parent.today ? Theme.on : Theme.fillHover }
                        Label { anchors.centerIn: parent; visible: parent.modelData > 0; text: parent.modelData; font.pixelSize: 12; color: parent.today ? Theme.onText : Theme.text; font.weight: parent.today ? Font.DemiBold : Font.Normal }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 2
                            visible: parent.modelData > 0 && root.eventsOn(parent.modelData).length > 0
                            width: 3
                            height: 3
                            radius: 1.5
                            color: parent.today ? Theme.onText : Theme.dim
                        }
                    }
                }
            }
            Column {
                visible: !root.compact && Sys.agenda.length > 0
                width: parent.width
                topPadding: 4
                spacing: 8
                Label { visible: !root.picked; text: "Up next"; font.pixelSize: 11; color: Theme.dim }
                Label { visible: root.picked && root.eventsOn(root.picked).length === 0; text: "Nothing on"; font.pixelSize: 12; color: Theme.dim }
                Repeater {
                    model: root.picked ? root.eventsOn(root.picked).slice(0, 6) : root.upcoming()
                    Column {
                        required property var modelData
                        width: parent.width
                        Label { width: parent.width; text: parent.modelData.title; font.pixelSize: 13 }
                        Label { width: parent.width; text: root.details(parent.modelData); font.pixelSize: 11; color: Theme.dim; font.features: { "tnum": 1 } }
                    }
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 8
        Layout.rightMargin: 4
        Layout.preferredHeight: 22
        Label { Layout.fillWidth: true; text: "Notifications"; font.pixelSize: 12; font.weight: Font.Medium }
        Press {
            visible: Notify.items.length > 0
            implicitWidth: 62
            implicitHeight: 22
            radius: 11
            name: "Clear all"
            onClicked: Notify.clear()
            Label { anchors.centerIn: parent; text: "Clear all"; font.pixelSize: 11 }
        }
    }
    Repeater {
        model: Notify.groups.slice(0, root.compact ? 3 : 6)
        NoticeCard {
            required property var modelData
            entry: modelData.entry
            more: modelData.more
            Layout.fillWidth: true
            onShowMore: Notify.toggleApp(modelData.entry.app)
        }
    }
    Item {
        visible: Notify.items.length === 0
        Layout.fillWidth: true
        implicitHeight: 44
        Glass { anchors.fill: parent; radius: 22 }
        Label { anchors.centerIn: parent; text: "Nothing new"; color: Theme.dim }
    }
}
