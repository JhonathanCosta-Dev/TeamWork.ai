import QtQuick
import "../theme"

// Avatar holográfico v3: nuvem de pontos da CABEÇA REAL do modelo facecap
// (three.js), "assada" em widget/assets/face-data.json — 4600 pontos com
// posição, normal, oclusão ambiente (AO) e 10 canais de morph (expressões
// ARKit). Renderizado em Canvas 2D com projeção/iluminação próprias — nada de
// WebGL (que crasha o Quickshell). Porte do renderer do repositório
// Alfinet-Shopify/agente-face.
//
// Expressões por humor (canais de morph):
//   neutral  → azul    | quase neutro, leve sobrancelha
//   thinking → laranja | sobrancelha erguida + olhos atentos (curioso)
//   happy    → verde   | sorriso + bochecha + olhos em meia-lua
//   serious  → vermelho| sobrancelha baixa + boca firme (intenso)
// Fala anima a mandíbula (jawOpen); pisca e move o olhar sozinho.
Item {
    id: root

    property var agent: null
    property bool speaking: false
    property bool listening: false
    // Humor visual: neutral | thinking | happy | serious
    property string mood: "neutral"
    // Modo "descanso de tela": olhar vaga mais amplo.
    property bool idleShow: false
    // Aceito por compatibilidade com chamadas antigas; sem efeito na v3.
    property bool cycleAssemble: true

    // Humor → cor + pesos dos canais de expressão (0..1).
    readonly property var _moods: ({
        "neutral":  { color: "#6db8ff", ch: { "browUp": 0.06 } },
        "thinking": { color: "#ffa95e", ch: { "browUp": 0.55, "browOuterUp": 0.45, "eyeWide": 0.4, "smile": 0.14 } },
        "happy":    { color: "#7fe08a", ch: { "smile": 0.95, "cheek": 0.55, "eyeSquint": 0.4, "jawOpen": 0.06, "browUp": 0.1 } },
        "serious":  { color: "#ff5f6e", ch: { "browDown": 0.85, "frown": 0.5, "eyeSquint": 0.35, "jawOpen": 0.04 } }
    })

    // --- dados decodificados ---
    property var _pos: null       // Float32Array (count*3), normalizado [-1,1]
    property var _nor: null       // Float32Array (count*3)
    property var _ao: null        // Float32Array (count)
    property var _morphNames: []
    property var _morphs: ({})    // name -> { idx: Uint16Array, del: Float32Array }
    property int _count: 0
    property bool _ready: false

    // --- estado de expressão (por canal: cur/tgt eased) ---
    property var _cur: ({})

    // --- buffers reaproveitados ---
    property var _work: null
    property var _twinkle: null
    property var _bx: null        // 16 Float32Array
    property var _by: null
    property var _bsz: null       // tamanho do ponto por bucket
    property var _bcount: null    // Int32Array(16)

    // --- paleta (16 níveis) a partir da cor do humor ---
    property string _colorHex: "#6db8ff"
    property var _palette: []

    // --- comportamento (segundos) ---
    property real _t: 0
    property real _blinkT: 10
    property real _nextBlink: 3
    property real _gazeX: 0
    property real _gazeY: 0
    property real _gazeTX: 0
    property real _gazeTY: 0
    property real _nextSaccade: 1.5
    property real _talkPhase: 0

    readonly property int _levels: 16

    onMoodChanged: _applyMood()
    onVisibleChanged: if (visible) _last = 0

    property real _last: 0

    Component.onCompleted: {
        _buildPalette();
        _load();
    }

    // ------------------------------------------------------------------
    // Carga + decodificação dos dados assados
    // ------------------------------------------------------------------
    // Lê o face-data.json via XHR (requer QML_XHR_ALLOW_FILE_READ=1 no
    // ambiente — o launcher e o start.sh já definem isso). O Quickshell
    // resolve o caminho relativo pro arquivo real via seu interceptor de VFS.
    function _load() {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            const txt = xhr.responseText ?? "";
            if (txt.length === 0) {
                console.log("GideonAvatar v3: face-data vazio (QML_XHR_ALLOW_FILE_READ=1?)");
                return;
            }
            try {
                root._decode(JSON.parse(txt));
            } catch (e) {
                console.log("GideonAvatar v3: erro ao decodificar face-data:", e);
            }
        };
        xhr.open("GET", Qt.resolvedUrl("../assets/face-data.json"));
        xhr.send();
    }

    // base64 → Uint8Array (sem depender de atob).
    function _b64(s) {
        const lut = new Int16Array(128);
        const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (let i = 0; i < chars.length; i++)
            lut[chars.charCodeAt(i)] = i;
        let len = s.length;
        let pad = 0;
        if (len > 0 && s.charCodeAt(len - 1) === 61)
            pad++;
        if (len > 1 && s.charCodeAt(len - 2) === 61)
            pad++;
        const outLen = (len >> 2) * 3 - pad;
        const bytes = new Uint8Array(outLen);
        let p = 0;
        for (let i = 0; i < len; i += 4) {
            const n = (lut[s.charCodeAt(i)] << 18) | (lut[s.charCodeAt(i + 1)] << 12)
                    | (lut[s.charCodeAt(i + 2)] << 6) | lut[s.charCodeAt(i + 3)];
            if (p < outLen) bytes[p++] = (n >> 16) & 0xff;
            if (p < outLen) bytes[p++] = (n >> 8) & 0xff;
            if (p < outLen) bytes[p++] = n & 0xff;
        }
        return bytes;
    }

    function _decode(d) {
        root._count = d.count;
        const N = d.count;

        const posI16 = new Int16Array(_b64(d.pos).buffer);
        root._pos = new Float32Array(N * 3);
        for (let i = 0; i < N * 3; i++)
            root._pos[i] = posI16[i] / 32000;

        const norI8 = new Int8Array(_b64(d.nor).buffer);
        root._nor = new Float32Array(N * 3);
        for (let i = 0; i < N * 3; i++)
            root._nor[i] = norI8[i] / 120;

        const aoU8 = _b64(d.ao);
        root._ao = new Float32Array(N);
        for (let i = 0; i < N; i++)
            root._ao[i] = aoU8[i] / 255;

        root._morphNames = Object.keys(d.morphs);
        const morphs = {};
        const cur = {};
        for (const name of root._morphNames) {
            const m = d.morphs[name];
            const idx = new Uint16Array(_b64(m.idx).buffer);
            const delI16 = new Int16Array(_b64(m.del).buffer);
            const del = new Float32Array(delI16.length);
            for (let i = 0; i < delI16.length; i++)
                del[i] = delI16[i] / 32000;
            morphs[name] = { idx: idx, del: del };
            cur[name] = { cur: 0, tgt: 0 };
        }
        root._morphs = morphs;
        root._cur = cur;

        root._work = new Float32Array(N * 3);
        root._twinkle = new Float32Array(N);
        for (let i = 0; i < N; i++)
            root._twinkle[i] = Math.random() * 6.283;

        const bx = [], by = [];
        for (let i = 0; i < root._levels; i++) {
            bx.push(new Float32Array(N));
            by.push(new Float32Array(N));
        }
        root._bx = bx;
        root._by = by;
        root._bcount = new Int32Array(root._levels);

        root._ready = true;
        _applyMood();
        canvas.requestPaint();
    }

    // ------------------------------------------------------------------
    // Humor / paleta
    // ------------------------------------------------------------------
    function _applyMood() {
        const m = root._moods[root.mood] || root._moods["neutral"];
        root._colorHex = m.color;
        _buildPalette();
        if (!root._ready)
            return;
        for (const name of root._morphNames)
            root._cur[name].tgt = (m.ch[name] !== undefined ? m.ch[name] : 0);
    }

    function _buildPalette() {
        const hex = root._colorHex.replace("#", "");
        const r = parseInt(hex.slice(0, 2), 16);
        const g = parseInt(hex.slice(2, 4), 16);
        const b = parseInt(hex.slice(4, 6), 16);
        const pal = [];
        for (let i = 0; i < root._levels; i++) {
            const t = i / (root._levels - 1);
            const lift = Math.max(0, t - 0.85) * 1.6;
            const rr = Math.min(255, Math.round(r * t + 255 * lift * t));
            const gg = Math.min(255, Math.round(g * t + 255 * lift * t));
            const bb = Math.min(255, Math.round(b * t + 255 * lift * t));
            pal.push("rgba(" + rr + "," + gg + "," + bb + ","
                     + (0.25 + 0.75 * t).toFixed(3) + ")");
        }
        root._palette = pal;
    }

    function _damp(cur, tgt, lambda, dt) {
        return cur + (tgt - cur) * (1 - Math.exp(-lambda * dt));
    }

    // dt do frame atual (varia com o framerate adaptativo abaixo).
    property real _frameDt: 0.033

    // Framerate adaptativo: 30fps quando ativo (fala/escuta/descanso de tela),
    // ~22fps ocioso — segura a CPU com a malha densa (9000 pontos) sem perder
    // fluidez quando importa.
    Timer {
        interval: (root.speaking || root.listening || root.idleShow) ? 33 : 45
        running: root.visible && root._ready
        repeat: true
        onTriggered: {
            root._frameDt = interval / 1000;
            root._t += root._frameDt;
            canvas.requestPaint();
        }
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        contextType: "2d"

        onPaint: {
            if (!root._ready)
                return;
            const ctx = getContext("2d");
            const W = width, H = height;
            if (W <= 0 || H <= 0)
                return;

            const dt = root._frameDt;
            const t = root._t;
            const N = root._count;
            const LV = root._levels;
            const R = Math.min(W, H) * 0.36;
            // Pontos menores com a malha densa (9000) → definição mais fina.
            const dotSize = Math.max(1, Math.round(R * 0.011));

            // -- comportamento: piscar, olhar (saccades), fala --
            root._blinkT += dt;
            if (root._blinkT > root._nextBlink) {
                root._blinkT = 0;
                root._nextBlink = 2 + Math.random() * 4;
            }
            const blinkEnv = Math.max(0, 1 - Math.abs(root._blinkT - 0.07) / 0.07);

            root._nextSaccade -= dt;
            if (root._nextSaccade < 0) {
                const amp = root.idleShow ? 1.0 : 0.6;
                root._nextSaccade = 1.5 + Math.random() * 4;
                root._gazeTX = (Math.random() - 0.5) * 0.5 * amp;
                root._gazeTY = (Math.random() - 0.5) * 0.24 * amp;
            }
            root._gazeX = root._damp(root._gazeX, root._gazeTX, 3, dt);
            root._gazeY = root._damp(root._gazeY, root._gazeTY, 3, dt);

            let jawTalk = 0;
            if (root.speaking) {
                root._talkPhase += dt * 11;
                jawTalk = 0.1 + 0.16 * Math.abs(Math.sin(root._talkPhase)
                                                * Math.sin(root._talkPhase * 0.37 + 1.7));
            }

            // -- suaviza canais e aplica morphs sobre a base --
            const work = root._work;
            work.set(root._pos);
            for (const name of root._morphNames) {
                const ch = root._cur[name];
                let target = ch.tgt;
                if (name === "blink")
                    target = Math.min(1, ch.tgt + blinkEnv);
                if (name === "jawOpen")
                    target = Math.min(1, ch.tgt + jawTalk);
                if (name === "eyeWide" && root.listening)
                    target = Math.min(1, target + 0.3);
                ch.cur = root._damp(ch.cur, target, name === "blink" ? 26 : 7, dt);
                if (ch.cur < 0.004)
                    continue;
                const idx = root._morphs[name].idx;
                const del = root._morphs[name].del;
                const v = ch.cur;
                for (let j = 0; j < idx.length; j++) {
                    const pi = idx[j] * 3, di = j * 3;
                    work[pi] += del[di] * v;
                    work[pi + 1] += del[di + 1] * v;
                    work[pi + 2] += del[di + 2] * v;
                }
            }

            // -- pose da cabeça: leve balanço + olhar --
            const yaw = root._gazeX * 0.5 + Math.sin(t * 0.31) * 0.06;
            const pitch = -root._gazeY * 0.4 + Math.sin(t * 0.23 + 1.3) * 0.04;
            const cyw = Math.cos(yaw), syw = Math.sin(yaw);
            const cpi = Math.cos(pitch), spi = Math.sin(pitch);
            const breathe = 1 + Math.sin(t * 0.7) * 0.006;

            const lx = 0.3, ly = 0.34, lz = 0.89;   // luz frontal + canto sup-esq
            const cx = W / 2, cy = H / 2;

            const bx = root._bx, by = root._by, bcount = root._bcount;
            bcount.fill(0);
            const nor = root._nor, ao = root._ao, tw = root._twinkle;

            for (let i = 0; i < N; i++) {
                const i3 = i * 3;
                const x = work[i3], y = work[i3 + 1], z = work[i3 + 2];
                let X = x * cyw + z * syw;
                let Z = -x * syw + z * cyw;
                let Y = y * cpi - Z * spi;
                Z = y * spi + Z * cpi;

                const nx0 = nor[i3], ny0 = nor[i3 + 1], nz0 = nor[i3 + 2];
                let nX = nx0 * cyw + nz0 * syw;
                let nZ = -nx0 * syw + nz0 * cyw;
                const nY = ny0 * cpi - nZ * spi;
                nZ = ny0 * spi + nZ * cpi;
                if (nZ < 0.02)
                    continue;   // back-face cull → silhueta limpa

                const persp = 1 / (1 - Z * 0.34);
                const sx = cx + X * R * persp * breathe;
                const sy = cy - Y * R * persp * breathe;

                const facing = nZ > 0 ? nZ : 0;
                const diffuse = Math.max(0, nX * lx + nY * ly + nZ * lz);
                const a = ao[i];
                let bright = (0.08 + 1.05 * (0.55 * facing * facing + 0.45 * diffuse)) * a * a * a;
                bright *= 0.94 + 0.06 * Math.sin(t * 1.7 + tw[i]);
                bright *= 0.62 + persp * 0.38;
                if (bright > 1)
                    bright = 1;

                let lvl = (bright * LV) | 0;
                if (lvl >= LV)
                    lvl = LV - 1;
                if (lvl < 0)
                    lvl = 0;
                const k = bcount[lvl]++;
                bx[lvl][k] = sx;
                by[lvl][k] = sy;
            }

            // -- desenha --
            ctx.clearRect(0, 0, W, H);
            ctx.globalCompositeOperation = "lighter";
            for (let lvl = 0; lvl < LV; lvl++) {
                const count = bcount[lvl];
                if (!count)
                    continue;
                ctx.fillStyle = root._palette[lvl];
                const xs = bx[lvl], ys = by[lvl];
                const s = lvl >= LV - 2 ? dotSize + 1 : dotSize;
                for (let k = 0; k < count; k++)
                    ctx.fillRect(xs[k], ys[k], s, s);
            }
            ctx.globalCompositeOperation = "source-over";
        }
    }

    // Legenda discreta sob o holograma.
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        text: root.agent !== null
              ? (root.agent.name ?? "") + (root.agent.role ? " · " + root.agent.role : "")
              : ""
        color: Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        opacity: 0.8
    }
}
