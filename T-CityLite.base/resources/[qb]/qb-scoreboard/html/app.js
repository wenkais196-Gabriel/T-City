window.addEventListener("message", (event) => {
    switch (event.data.action) {
        case "open":
            open(event.data);
            break;
        case "close":
            close();
            break;
        case "setup":
            setup(event.data);
            break;
    }
});

const open = (data) => {
    const scoreboard = document.querySelector(".scoreboard-block");
    scoreboard.style.display = "block";
    const totalPlayers = document.getElementById("total-players");
    if (totalPlayers) {
        // H-4：0 人的时候不要只显示 "0 of 64" —— 那看起来像加载失败
        if (!data.players) {
            totalPlayers.innerHTML = `<p>暂无在线玩家</p>`;
        } else {
            totalPlayers.innerHTML = `<p>${data.players} / ${data.maxPlayers}</p>`;
        }
    }
    renderLegend(data);
    Object.entries(data.requiredCops).forEach(([category, info]) => {
        const beam = document.querySelector(`.scoreboard-info [data-type="${category}"]`);
        if (!beam) return;
        const status = beam.querySelector(".info-beam-status");
        if (!status) return;
        if (info.busy) {
            status.innerHTML = "⏳";
        } else if (data.currentCops >= info.minimumPolice) {
            status.innerHTML = "✅";
        } else {
            status.innerHTML = "❌";
        }
    });
};

// H-4：图例。分数板原来只有三个符号（✅/❌/⏳）和一个人数，玩家不知道那是什么意思。
// 这里补一行说明 + 一处"去哪看详情"。放在 open() 调用的地方，避免重复创建。
const renderLegend = (data) => {
    const block = document.querySelector(".scoreboard-block");
    if (!block) return;
    let legend = document.getElementById("scoreboard-legend");
    if (!legend) {
        legend = document.createElement("div");
        legend.id = "scoreboard-legend";
        legend.className = "scoreboard-legend";
        block.appendChild(legend);
    }
    legend.innerHTML =
        '<p class="legend-line">✅ 已满足所需警察　❌ 警察不足　⏳ 正在进行</p>' +
        '<p class="legend-line legend-hint">详细名单与工单：手机 MDT</p>';
};

const close = () => {
    const scoreboard = document.querySelector(".scoreboard-block");
    scoreboard.style.display = "none";
};

const setup = (data) => {
    const scoreboardInfo = document.querySelector(".scoreboard-info");
    if (!scoreboardInfo) return;
    scoreboardInfo.innerHTML = "";
    Object.entries(data.items).forEach(([index, value]) => {
        const beamElement = document.createElement("div");
        beamElement.className = "scoreboard-info-beam";
        beamElement.setAttribute("data-type", index);
        const titleElement = document.createElement("div");
        titleElement.className = "info-beam-title";
        titleElement.innerHTML = `<p>${value}</p>`;
        const statusElement = document.createElement("div");
        statusElement.className = "info-beam-status";
        beamElement.appendChild(titleElement);
        beamElement.appendChild(statusElement);
        scoreboardInfo.appendChild(beamElement);
    });
    const playersBeam = document.createElement("div");
    playersBeam.className = "scoreboard-info-beam";
    const playersTitle = document.createElement("div");
    playersTitle.className = "info-beam-title";
    playersTitle.innerHTML = "<p>Total Players</p>";
    const playersStatus = document.createElement("div");
    playersStatus.className = "info-beam-status";
    playersStatus.id = "total-players";
    playersBeam.appendChild(playersTitle);
    playersBeam.appendChild(playersStatus);
    scoreboardInfo.appendChild(playersBeam);
};
