/**
 * tcity-atmosphere — Howler.js playback engine
 * Production build. HTML5 Audio mode (no AudioContext dependency).
 */
(function () {
    'use strict';

    var currentHowl = null;
    var currentId = null;
    var BASE_PATH = '../assets/audio/';

    function playScene(data) {
        if (!data || !data.track) {
            stopBGM();
            return;
        }

        var targetVol = data.volume || 0.1;
        var fadeMs = data.fadeInMs || 1500;

        if (currentHowl) {
            var oldHowl = currentHowl;
            var oldId = currentId;
            oldHowl.fade(oldHowl.volume(), 0, 400, oldId);
            setTimeout(function () { oldHowl.stop(); oldHowl.unload(); }, 450);
        }

        currentHowl = new Howl({
            src: [BASE_PATH + data.track + '.mp3'],
            html5: true,
            loop: !!data.loop,
            volume: 0,
            preload: true,
            onloaderror: function (id, err) {
                console.error('[atmosphere] load error: ' + data.track, err);
            },
            onplayerror: function (id, err) {
                console.error('[atmosphere] play error: ' + data.track, err);
                currentHowl.once('unlock', function () { currentHowl.play(); });
            },
        });

        currentId = currentHowl.play();
        currentHowl.fade(0, targetVol, fadeMs, currentId);
    }

    function stopBGM() {
        if (currentHowl) {
            var h = currentHowl;
            var id = currentId;
            h.fade(h.volume(), 0, 400, id);
            setTimeout(function () { h.stop(); h.unload(); }, 450);
            currentHowl = null;
            currentId = null;
        }
    }

    function setVolume(vol) {
        if (typeof vol !== 'number' || vol < 0 || vol > 1) return;
        if (currentHowl && currentId) {
            currentHowl.volume(vol, currentId);
        }
    }

    window.addEventListener('message', function (event) {
        var data = event.data;
        if (!data || !data.type) return;
        switch (data.type) {
            case 'playScene': playScene(data); break;
            case 'stopBGM':   stopBGM();       break;
            case 'setVolume': setVolume(data.volume); break;
        }
    });

    fetch('https://cfx-nui-tcity-atmosphere/atmosphere:ready', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({})
    }).catch(function () {});

})();
