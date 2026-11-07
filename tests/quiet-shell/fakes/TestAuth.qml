import QtQuick

// Stands in for polkit's AuthFlow, since the private session has no system bus.
Item {
    property string message: "Authentication is required to change system settings."
    property string inputPrompt: "Password: "
    property string supplementaryMessage: ""
    property bool isResponseRequired: true
    property bool responseVisible: false
    property bool failed: false
    signal closed

    function submit(value) {
        if (value === "correct horse") {
            closed();
            return;
        }
        failed = true;
        isResponseRequired = false;
        isResponseRequired = true;
    }
    function cancelAuthenticationRequest() { closed(); }
}
