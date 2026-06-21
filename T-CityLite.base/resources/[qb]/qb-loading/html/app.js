const { ref } = Vue

// Customize language for dialog menus and carousels here

const load = Vue.createApp({
  setup () {
    return {
      CarouselText1: 'You can add/remove items, vehicles, jobs & gangs through the shared folder.',
      CarouselSubText1: 'Photo captured by: Markyoo#8068',
      CarouselText2: 'Adding additional player data can be achieved by modifying the qb-core player.lua file.',
      CarouselSubText2: 'Photo captured by: ihyajb#9723',
      CarouselText3: 'All server-specific adjustments can be made in the config.lua files throughout the build.',
      CarouselSubText3: 'Photo captured by: FLAPZ[INACTIV]#9925',
      CarouselText4: 'For additional support please join our community at discord.gg/qbcore',
      CarouselSubText4: 'Photo captured by: Robinerino#1312',

      DownloadTitle: 'Downloading QBCore Server',
      DownloadDesc: "Hold tight while we begin downloading all the resources/assets required to play on QBCore Server. \n\nAfter download has been finished successfully, you'll be placed into the server and this screen will disappear. Please don't leave or turn off your PC. ",

      SettingsTitle: 'Settings',
      AudioTrackDesc1: 'When disabled the current audio-track playing will be stopped.',
      AutoPlayDesc2: 'When disabled carousel images will stop cycling and remain on the last shown.',
      PlayVideoDesc3: 'When disabled video will stop playing and remain paused.',

      KeybindTitle: 'Default Keybinds',
      Keybind1: 'Open Inventory',
      Keybind2: 'Cycle Proximity',
      Keybind3: 'Open Phone',
      Keybind4: 'Toggle Seat Belt',
      Keybind5: 'Open Target Menu',
      Keybind6: 'Radial Menu',
      Keybind7: 'Open Hud Menu',
      Keybind8: 'Talk Over Radio',
      Keybind9: 'Open Scoreboard',
      Keybind10: 'Vehicle Locks',
      Keybind11: 'Toggle Engine',
      Keybind12: 'Pointer Emote',
      Keybind13: 'Keybind Slots',
      Keybind14: 'Hands Up Emote',
      Keybind15: 'Use Item Slots',
      Keybind16: 'Cruise Control',

      firstap: ref(true),
      secondap: ref(true),
      thirdap: ref(true),
      firstslide: ref(1),
      secondslide: ref('1'),
      thirdslide: ref('5'),
      audioplay: ref(true),
      playvideo: ref(true),
      download: ref(true),
      settings: ref(false),
    }
  }
})

load.use(Quasar, { config: {} })
load.mount('#loading-main')

// ─── Playlist Engine ───────────────────────────────────────
// Track 1 (Dusk Prelude) → Track 2 (City Lights Pulse) → Track 3 (Last Call Reprise)
// Cross-fade: last 5s of current track fades out while next fades in

var playlist = [
    { src: '/assets/audio/Dusk_Prelude.mp3',        duration: 120 },
    { src: '/assets/audio/City_Lights_Pulse.mp3',    duration: 120 },
    { src: '/assets/audio/Last_Call_Reprise.mp3',    duration: 120 },
];
var currentTrack = 0;
var audioA = new Audio();  // primary player
var audioB = new Audio();  // cross-fade player
var baseVolume = 0.10;
var playlistActive = true;
var crossFadeActive = false;

audioA.volume = baseVolume;
audioB.volume = 0;

// Start playlist
function playlistStart() {
    if (currentTrack >= playlist.length) return;
    audioA.src = playlist[currentTrack].src;
    audioA.play().catch(function() { /* autoplay blocked — retry on user gesture */ });
    audioA.onended = playlistNext;
}

// Cross-fade to next track
function playlistNext() {
    if (crossFadeActive) return;
    if (!playlistActive) return;
    currentTrack++;
    if (currentTrack >= playlist.length) {
        // All tracks done — loop back to Track 2 (city pulse) for long loads
        currentTrack = 1;
    }

    crossFadeActive = true;
    var next = playlist[currentTrack];
    audioB.src = next.src;
    audioB.volume = 0;
    audioB.play().catch(function() {});
    audioB.onended = playlistNext;

    // Cross-fade: 5-second overlap
    var steps = 25;
    var stepMs = 200;  // 25 * 200 = 5000ms
    var volStep = baseVolume / steps;
    var step = 0;

    var fadeInterval = setInterval(function() {
        step++;
        audioA.volume = Math.max(0, baseVolume - volStep * step);
        audioB.volume = Math.min(baseVolume, volStep * step);

        if (step >= steps) {
            clearInterval(fadeInterval);
            audioA.pause();
            audioA.volume = baseVolume;
            audioB.volume = baseVolume;
            // Swap: B becomes the new primary
            var tmp = audioA;
            audioA = audioB;
            audioB = tmp;
            audioB.volume = 0;
            crossFadeActive = false;
        }
    }, stepMs);
}

// Toggle audio (wired to settings dialog)
function audiotoggle() {
    playlistActive = !playlistActive;
    if (playlistActive) {
        if (audioA.paused && audioA.src) {
            audioA.play().catch(function() {});
        } else if (!audioA.src) {
            playlistStart();
        }
    } else {
        audioA.pause();
        audioB.pause();
    }
}

// Kick off
playlistStart();

function videotoggle() {
    var video = document.getElementById("video");
    if (video.paused) {
        video.play();
    } else {
        video.pause();
    }
}

let count = 0;
let thisCount = 0;

const handlers = {
    startInitFunctionOrder(data) {
        count = data.count;
    },

    initFunctionInvoking(data) {
        document.querySelector(".thingy").style.left = "0%";
        document.querySelector(".thingy").style.width = (data.idx / count) * 100 + "%";
    },

    startDataFileEntries(data) {
        count = data.count;
    },

    performMapLoadFunction(data) {
        ++thisCount;

        document.querySelector(".thingy").style.left = "0%";
        document.querySelector(".thingy").style.width = (thisCount / count) * 100 + "%";
    },
};

window.addEventListener("message", function (e) {
    (handlers[e.data.eventName] || function () {})(e.data);
});
