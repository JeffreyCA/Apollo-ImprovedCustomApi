window.addEventListener("DOMContentLoaded", function () {
    "use strict";

    var automaticToggle = document.getElementById("automatic-toggle");

    function applyStoredValue(item) {
        var automaticObj = item && item.automaticObj;
        automaticToggle.checked = !automaticObj || automaticObj.isAutomatic !== false;
    }

    try {
        var pending = browser.storage.local.get("automaticObj");
        if (pending && typeof pending.then === "function") {
            pending.then(applyStoredValue, function () { automaticToggle.checked = true; });
        } else {
            browser.storage.local.get(applyStoredValue);
        }
    } catch (error) {
        automaticToggle.checked = true;
    }

    automaticToggle.addEventListener("change", function () {
        browser.storage.local.set({
            automaticObj: { isAutomatic: automaticToggle.checked }
        });
    });
});
