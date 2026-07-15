pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Avatar holográfico do agente: máscara facial de malha fina de pontos
// (wireframe de partículas), com anatomia 3D — sobrancelhas em arco,
// órbitas fundas, nariz com ponta/asas, lábios, bochechas escavadas —
// e humor visual por cor + expressão:
//   neutral  → azul    | calmo
//   thinking → laranja | sobrancelha ergue, boca de lado, olhar alto
//   happy    → verde   | olhos em meia-lua + sorriso
//   serious  → vermelho| olhos estreitos + cenho fechado + boca reta
//
// Tudo é ponto — nenhum traço. Canvas 2D com projeção em perspectiva
// própria (three.js/WebGL exigiria WebEngineView, que crasha o
// Quickshell — issue #298).
Item {
    id: root

    property var agent: null
    property bool speaking: false
    property bool listening: false
    // Humor visual: neutral | thinking | happy | serious
    property string mood: "neutral"
    // Modo "descanso de tela": olhar vagando pros lados devagar,
    // como se observasse o ambiente.
    property bool idleShow: false

    readonly property var _moodColors: ({
        "neutral":  "#6db8ff",
        "thinking": "#ffa95e",
        "happy":    "#7fe08a",
        "serious":  "#ff5f6e"
    })
    property color baseColor: root._moodColors[root.mood] ?? "#6db8ff"
    Behavior on baseColor { ColorAnimation { duration: 650 } }

    // Pesos de expressão (0..1) animados — o paint mistura as feições.
    property real _wThink: 0
    property real _wHappy: 0
    property real _wSerious: 0
    Behavior on _wThink   { NumberAnimation { duration: 550; easing.type: Easing.InOutCubic } }
    Behavior on _wHappy   { NumberAnimation { duration: 550; easing.type: Easing.InOutCubic } }
    Behavior on _wSerious { NumberAnimation { duration: 550; easing.type: Easing.InOutCubic } }

    // Peso de fala animado: enquanto fala, a boca volta ao centro (os
    // trejeitos de humor saem de cena) e articula como uma boca normal.
    property real _wSpeak: root.speaking ? 1 : 0
    Behavior on _wSpeak { NumberAnimation { duration: 300; easing.type: Easing.InOutCubic } }

    onMoodChanged: _applyMood()

    function _applyMood() {
        _wThink = root.mood === "thinking" ? 1 : 0;
        _wHappy = root.mood === "happy" ? 1 : 0;
        _wSerious = root.mood === "serious" ? 1 : 0;
    }

    // EXPERIMENTO: desmonta e remonta as partículas a cada 15 s.
    // Pra reverter, basta trocar pra false.
    property bool cycleAssemble: true

    // --- estado interno da simulação ---
    property real _t: 0
    property real _assemble: 0
    property bool _dissolving: false
    property var _points: []
    property var _orbits: []
    property var _stars: []
    property var _featScatter: []        // dispersão dos pontos de olhos/boca
    property real _eyeZ: 0.4
    property real _mouthZ: 0.4

    onVisibleChanged: if (visible) _assemble = 0

    Component.onCompleted: {
        _applyMood();
        _buildScene();
    }

    Timer {
        interval: 33
        running: root.visible
        repeat: true
        onTriggered: {
            root._t += 0.033;
            if (root._dissolving) {
                root._assemble = Math.max(0, root._assemble - 0.033 / 1.0);
                if (root._assemble === 0)
                    root._dissolving = false;    // chegou na massa: remonta
            } else if (root._assemble < 1) {
                root._assemble = Math.min(1, root._assemble + 0.033 / 2.4);
            }
            canvas.requestPaint();
        }
    }

    Timer {
        interval: 15000
        running: root.visible && root.cycleAssemble
        repeat: true
        onTriggered: root._dissolving = true
    }

    function _gauss(x, s) {
        return Math.exp(-(x * x) / (2 * s * s));
    }

    // Silhueta da máscara por altura (v: -1 topo → +1 queixo): larga nas
    // têmporas/maçãs, afunila liso até um queixo fino — o formato exato
    // vem desta tabela de meia-larguras.
    readonly property var _hwTable: [
        [-1.00, 0.50], [-0.72, 0.62], [-0.40, 0.67], [-0.05, 0.68],
        [0.30, 0.60], [0.60, 0.50], [0.85, 0.38], [1.00, 0.28]
    ]

    function _halfWidth(v) {
        const tb = _hwTable;
        if (v <= tb[0][0])
            return tb[0][1];
        for (let i = 1; i < tb.length; i++) {
            if (v <= tb[i][0]) {
                let k = (v - tb[i - 1][0]) / (tb[i][0] - tb[i - 1][0]);
                k = k * k * (3 - 2 * k);        // suaviza entre os nós
                return tb[i - 1][1] + (tb[i][1] - tb[i - 1][1]) * k;
            }
        }
        return tb[tb.length - 1][1];
    }

    // Campo de profundidade + brilho de feição. Retorna:
    // [profundidade, borda 0..1, brilho-extra 0..1] ou null fora da máscara.
    function _depth(u, v) {
        const hw = _halfWidth(v);
        const ex = (u / hw) * (u / hw);
        // Corte vertical: topo elíptico (crânio arredondado), base mais
        // reta (queixo vem da tabela de larguras).
        const e = ex + Math.pow(Math.abs(v) / 0.97, v < 0 ? 4 : 8);
        if (e > 1)
            return null;

        // Volume arredondado da máscara.
        const ee = Math.min(1, ex + (v / 0.99) * (v / 0.99));
        let d = Math.sqrt(1 - ee) * 0.50;

        d += 0.22 * _gauss(u, 0.055) * _gauss(v - 0.25, 0.24);    // dorso do nariz
        d += 0.16 * _gauss(u, 0.08) * _gauss(v - 0.42, 0.05);     // ponta do nariz
        d += 0.07 * (_gauss(u - 0.11, 0.045) + _gauss(u + 0.11, 0.045))
                  * _gauss(v - 0.45, 0.04);                       // asas do nariz
        d += 0.10 * (_gauss(u - 0.30, 0.15) + _gauss(u + 0.30, 0.15))
                  * _gauss(v + 0.17, 0.05);                       // arcada das sobrancelhas
        d -= 0.12 * (_gauss(u - 0.26, 0.11) + _gauss(u + 0.26, 0.11))
                  * _gauss(v + 0.05, 0.07);                       // órbitas fundas
        d += 0.08 * (_gauss(u - 0.42, 0.12) + _gauss(u + 0.42, 0.12))
                  * _gauss(v - 0.10, 0.10);                       // maçãs do rosto
        d -= 0.07 * (_gauss(u - 0.24, 0.10) + _gauss(u + 0.24, 0.10))
                  * _gauss(v - 0.32, 0.12);                       // bochechas escavadas
        d += 0.08 * _gauss(u, 0.14) * _gauss(v - 0.58, 0.045);    // lábio superior
        d += 0.06 * _gauss(u, 0.10) * _gauss(v - 0.68, 0.04);     // lábio inferior
        d += 0.10 * _gauss(u, 0.12) * _gauss(v - 0.85, 0.08);     // queixo
        d += 0.07 * _gauss(u, 0.36) * _gauss(v + 0.55, 0.26);     // testa

        // Brilho extra das feições (como na referência): sobrancelhas em
        // arco acesas, ponta/asas do nariz e lábios sutis.
        const browCurve = -0.21 - 0.05 * Math.pow((Math.abs(u) - 0.30) / 0.20, 2);
        let boost = 0;
        if (Math.abs(u) > 0.10 && Math.abs(u) < 0.50)
            boost += 0.9 * _gauss(v - browCurve, 0.028);          // sobrancelhas
        boost += 0.7 * _gauss(u, 0.09) * _gauss(v - 0.43, 0.045); // ponta do nariz
        boost += 0.5 * (_gauss(u - 0.11, 0.04) + _gauss(u + 0.11, 0.04))
                     * _gauss(v - 0.455, 0.035);                  // asas
        boost += 0.30 * _gauss(u, 0.13) * _gauss(v - 0.615, 0.035); // lábios
        return [d, e, Math.min(1, boost)];
    }

    function _buildScene() {
        // Malha fina e estruturada (sem jitter): a projeção 3D da grade
        // cria as linhas de contorno que envolvem as feições.
        const pts = [];
        const cols = 112, rows = 154;
        for (let iy = 0; iy < rows; iy++) {
            for (let ix = 0; ix < cols; ix++) {
                const u = -1 + 2 * (ix + 0.5) / cols;
                const v = -1 + 2 * (iy + 0.5) / rows;
                const dd = _depth(u, v);
                if (dd === null)
                    continue;
                pts.push({
                    x: u, y: v, z: dd[0], e: dd[1], boost: dd[2],
                    seed: Math.random() * 6.283,
                    sx: (Math.random() - 0.5) * 3.6,
                    sy: (Math.random() - 0.5) * 3.6,
                    sz: (Math.random() - 0.5) * 1.8,
                    brow: dd[2] > 0.35 && v < -0.05
                          && Math.abs(u) > 0.10 && Math.abs(u) < 0.50,
                    cheek: Math.abs(u) > 0.28 && Math.abs(u) < 0.58
                           && v > 0.05 && v < 0.35
                });
            }
        }
        _points = pts;
        _eyeZ = _depth(0.26, -0.05)[0];
        _mouthZ = _depth(0, 0.63)[0];

        // Anéis orbitais + linha horizontal de pontos (como na referência).
        const orbits = [];
        const radii = [1.22, 1.44, 1.66];
        for (let i = 0; i < 54; i++) {
            orbits.push({
                r: radii[i % 3],
                ang: Math.random() * 6.283,
                spd: (i % 3 === 0 ? 1 : -1) * (0.02 + 0.015 * (i % 3)),
                size: Math.random() < 0.15 ? 2.2 : 1.1,
                a: Math.random() < 0.15 ? 0.75 : 0.30,
                seed: Math.random() * 6.283
            });
        }
        for (let s = 0; s < 8; s++) {
            orbits.push({
                r: 1.05 + 0.13 * s,
                ang: s % 2 === 0 ? 0 : Math.PI,
                spd: 0,
                size: s % 3 === 0 ? 1.8 : 1.0,
                a: 0.5 - 0.04 * s,
                seed: s
            });
        }
        _orbits = orbits;

        const stars = [];
        for (let i = 0; i < 26; i++) {
            stars.push({
                x: (Math.random() - 0.5) * 3.8,
                y: (Math.random() - 0.5) * 3.0,
                seed: Math.random() * 6.283
            });
        }
        _stars = stars;

        // Olhos e boca também são partículas: cada ponto ganha sua posição
        // dispersa e some/reaparece na montagem igual à malha.
        const fs = [];
        for (let i = 0; i < 200; i++) {
            fs.push({
                seed: Math.random() * 6.283,
                sx: (Math.random() - 0.5) * 3.6,
                sy: (Math.random() - 0.5) * 3.6,
                sz: (Math.random() - 0.5) * 1.8
            });
        }
        _featScatter = fs;
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        contextType: "2d"

        onPaint: {
            const ctx = getContext("2d");
            const W = width, H = height;
            ctx.clearRect(0, 0, W, H);
            if (W <= 0 || H <= 0 || root._points.length === 0)
                return;

            const t = root._t;
            const speaking = root.speaking;
            const th = root._wThink, hp = root._wHappy, sr = root._wSerious;
            const energy = speaking ? 1.0 : (root.listening ? 0.7 : 0.45);
            const cx = W / 2, cy = H * 0.52;
            const scale = Math.min(W, H) * 0.365;
            // Em telas grandes (descanso de tela) os pontos crescem junto,
            // mantendo a densidade visual da malha.
            const sizeK = Math.max(1, scale / 110);

            const talk = speaking
                ? Math.max(0, 0.5 * Math.sin(t * 9.0) + 0.35 * Math.sin(t * 5.3)
                              + 0.25 * Math.sin(t * 13.7))
                : 0;
            const flicker = 0.93 + 0.07 * Math.sin(t * 9.3) * (0.5 + 0.5 * Math.sin(t * 3.7));
            const listenPulse = root.listening ? 0.5 + 0.5 * Math.sin(t * 2.4) : 0;

            const c = root.baseColor;
            const br = Math.round(c.r * 255), bg = Math.round(c.g * 255), bb = Math.round(c.b * 255);
            const rgba = function (a) {
                return "rgba(" + br + "," + bg + "," + bb + "," + a.toFixed(3) + ")";
            };

            // Glow difuso atrás do rosto.
            const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, scale * 1.5);
            glow.addColorStop(0, rgba(0.10 + 0.08 * energy * flicker + 0.10 * listenPulse));
            glow.addColorStop(1, rgba(0));
            ctx.fillStyle = glow;
            ctx.fillRect(0, 0, W, H);

            // ---------------- anéis orbitais + estrelas ----------------
            ctx.lineWidth = 1;
            const ringR = [1.22, 1.44, 1.66];
            const ringA = [0.11, 0.07, 0.05];
            for (let i = 0; i < 3; i++) {
                ctx.strokeStyle = rgba(ringA[i] * flicker);
                ctx.beginPath();
                ctx.arc(cx, cy, scale * ringR[i], 0, 6.2832);
                ctx.stroke();
            }
            for (let i = 0; i < root._orbits.length; i++) {
                const o = root._orbits[i];
                const a = o.ang + o.spd * t;
                const px = cx + Math.cos(a) * scale * o.r;
                const py = cy + Math.sin(a) * scale * o.r * 0.996;
                const tw = 0.75 + 0.25 * Math.sin(t * 1.7 + o.seed);
                ctx.fillStyle = rgba(o.a * tw);
                ctx.fillRect(px, py, o.size * sizeK, o.size * sizeK);
            }
            for (let i = 0; i < root._stars.length; i++) {
                const s = root._stars[i];
                const tw = 0.5 + 0.5 * Math.sin(t * 1.1 + s.seed);
                ctx.fillStyle = rgba(0.08 + 0.14 * tw);
                ctx.fillRect(cx + s.x * scale, cy + s.y * scale,
                             1.2 * sizeK, 1.2 * sizeK);
            }

            // ---------------- máscara (malha de pontos) ----------------
            // No descanso de tela o olhar vaga: camadas de senos lentos em
            // frequências não múltiplas parecem "olhar pros lados" natural.
            const wander = root.idleShow ? 1 : 0;
            const rotY = 0.20 * Math.sin(t * 0.32)
                       + wander * (0.28 * Math.sin(t * 0.11)
                                   + 0.15 * Math.sin(t * 0.047 + 1.7))
                       + (speaking ? 0.045 * Math.sin(t * 1.9) : 0);
            const rotX = 0.05 * Math.sin(t * 0.21)
                       + wander * 0.08 * Math.sin(t * 0.083 + 0.5)
                       - 0.05 * th + 0.01 * hp
                       + (speaking ? 0.04 * Math.sin(t * 2.6) : 0);
            const cosY = Math.cos(rotY), sinY = Math.sin(rotY);
            const cosX = Math.cos(rotX), sinX = Math.sin(rotX);
            const wobble = 0.003 + 0.005 * energy;
            const zCenter = 0.28;

            const buckets = [[], [], [], [], [], [], [], []];
            const pts = root._points;

            for (let i = 0; i < pts.length; i++) {
                const p = pts[i];

                let a = root._assemble * 1.2 - (p.seed / 6.283) * 0.2;
                a = Math.min(1, Math.max(0, a));
                a = 1 - Math.pow(1 - a, 3);

                let x = p.sx + (p.x - p.sx) * a;
                let y = p.sy + (p.y - p.sy) * a;
                let z = p.sz + (p.z - p.sz) * a;

                // Expressão: as sobrancelhas acesas se movem com o humor.
                if (p.brow) {
                    const inner = 1 - Math.min(1, Math.abs(p.x) / 0.5);
                    // Sorriso de repouso: leve arqueada amistosa mesmo no
                    // neutro (acentua o arco externo) pra não parecer triste;
                    // some quando sério.
                    y -= 0.011 * (0.5 + 0.5 * (1 - inner)) * (1 - sr);
                    if (p.x < 0)
                        y -= 0.05 * th;
                    else
                        y += 0.008 * th;
                    y += 0.045 * sr * inner;
                    y -= 0.05 * hp;      // feliz: ergue junto com a meia-lua
                }
                if (p.cheek)
                    y -= 0.018 * hp;

                x += wobble * Math.sin(t * 1.6 + p.seed);
                y += wobble * Math.cos(t * 1.3 + p.seed * 1.7);

                const dz = z - zCenter;
                const xr = x * cosY + dz * sinY;
                const zr = -x * sinY + dz * cosY;
                const yr = y * cosX - zr * sinX;
                const zr2 = y * sinX + zr * cosX;

                const persp = 1.7 / (1.7 - zr2 * 0.55);
                const px = cx + xr * scale * persp;
                const py = cy + yr * scale * persp;

                // Malha fina e discreta; contorno da máscara e feições
                // (sobrancelha/nariz/lábios) acendem como na referência.
                let bright = (0.07 + p.z * 0.34
                              + Math.pow(p.e, 8) * 0.70
                              + p.boost * 0.70
                              + zr2 * 0.20)
                             * flicker * (0.25 + 0.75 * a);
                bright = Math.min(1, Math.max(0, bright));
                const size = (0.36 + p.z * 0.46
                              + Math.pow(p.e, 8) * 0.42
                              + p.boost * 0.46) * persp * sizeK;
                buckets[Math.min(7, Math.floor(bright * 8))].push(px, py, size);
            }

            for (let b = 0; b < 8; b++) {
                const list = buckets[b];
                if (list.length === 0)
                    continue;
                const lum = (b + 1) / 8;
                const mix = lum * lum * 0.65;
                const rr = Math.round(br + (255 - br) * mix);
                const gg = Math.round(bg + (255 - bg) * mix);
                const bb2 = Math.round(bb + (255 - bb) * mix);
                ctx.fillStyle = "rgba(" + rr + "," + gg + "," + bb2 + ","
                                + (0.20 + 0.80 * lum).toFixed(3) + ")";
                for (let j = 0; j < list.length; j += 3)
                    ctx.fillRect(list[j], list[j + 1], list[j + 2], list[j + 2]);
            }

            // Projeção de um ponto do rosto pra tela (olhos/boca).
            const proj = function (u, v, z) {
                const dz = z - zCenter;
                const xr = u * cosY + dz * sinY;
                const zr = -u * sinY + dz * cosY;
                const yr = v * cosX - zr * sinX;
                const zr2 = v * sinX + zr * cosX;
                const pp = 1.7 / (1.7 - zr2 * 0.55);
                return [cx + xr * scale * pp, cy + yr * scale * pp];
            };

            const featA = (0.25 + 0.75 * root._assemble) * flicker;
            const cr = Math.round(br + (255 - br) * 0.92);
            const cg = Math.round(bg + (255 - bg) * 0.92);
            const cb = Math.round(bb + (255 - bb) * 0.92);

            // Cada ponto de olho/boca dispersa e remonta como a malha:
            // interpola da posição espalhada pro alvo com atraso individual.
            let fi = 0;
            const featDot = function (tu, tv, tz) {
                const sc = root._featScatter[fi++ % root._featScatter.length];
                let af = root._assemble * 1.2 - (sc.seed / 6.283) * 0.2;
                af = Math.min(1, Math.max(0, af));
                af = 1 - Math.pow(1 - af, 3);
                return proj(sc.sx + (tu - sc.sx) * af,
                            sc.sy + (tv - sc.sy) * af,
                            sc.sz + (tz - sc.sz) * af);
            };

            // ---------------- olhos (nuvem de pontos) ----------------
            // Fendas amendoadas finas e MUITO acesas, como na referência;
            // feliz vira arco ^, sério estreita e inclina, pensativo sobe.
            const openness = Math.max(0.25, 1 - 0.30 * th - 0.55 * sr);
            const eyeW = 0.115, eyeH = 0.075 * openness;

            for (let side = -1; side <= 1; side += 2) {
                const ecx = side * 0.26;
                const ecy = -0.05 - 0.05 * th;
                const tilt = side * sr * -0.14;
                const ct = Math.cos(tilt), st = Math.sin(tilt);

                const gpos = proj(ecx, ecy, root._eyeZ);
                const gr = scale * 0.17;
                const eg = ctx.createRadialGradient(gpos[0], gpos[1], 0, gpos[0], gpos[1], gr);
                // O halo só existe com o rosto montado (some na dissolução).
                eg.addColorStop(0, rgba(0.40 * featA * root._assemble));
                eg.addColorStop(1, rgba(0));
                ctx.fillStyle = eg;
                ctx.fillRect(gpos[0] - gr, gpos[1] - gr, gr * 2, gr * 2);

                ctx.fillStyle = "rgba(" + cr + "," + cg + "," + cb + ","
                                + (0.95 * featA).toFixed(3) + ")";
                const eCols = 15;
                for (let r = -1; r <= 1; r++) {
                    for (let i = 0; i < eCols; i++) {
                        const hx = -1 + 2 * i / (eCols - 1);
                        const almond = Math.pow(Math.max(0, 1 - hx * hx), 0.6);
                        let ey0 = r * 0.5 * almond * eyeH;
                        const bend = -almond * eyeH * 1.9 + r * 0.15 * eyeH;
                        ey0 = ey0 * (1 - hp) + bend * hp;
                        const ex0 = hx * eyeW;
                        const rx = ex0 * ct - ey0 * st;
                        const ry = ex0 * st + ey0 * ct;
                        // Profundidade da SUPERFÍCIE do rosto neste ponto —
                        // os cantos do olho recuam com a curvatura da máscara.
                        const esd = root._depth(ecx + rx, ecy + ry);
                        const ez = (esd !== null ? esd[0] : root._eyeZ) + 0.03;
                        const pp = featDot(ecx + rx, ecy + ry, ez);
                        const sz = (0.85 + 0.85 * almond) * sizeK;
                        ctx.fillRect(pp[0], pp[1], sz, sz);
                    }
                }
            }

            // ---------------- boca (patch de lábios em pontos) ----------------
            // Lábios de verdade: superior com arco do cupido, inferior mais
            // cheio, preenchidos por fileiras de pontos — e cada ponto tem a
            // própria profundidade (os lábios saltam da máscara e ganham
            // paralaxe ao girar). Cantos sobem (feliz) / caem (sério),
            // desloca no pensativo e abre com o envelope de fala.
            // Falando, os trejeitos de humor da boca (de lado, inclinada,
            // estreita) são suavemente zerados — a articulação é neutra.
            const thM = th * (1 - root._wSpeak);
            const srM = sr * (1 - 0.6 * root._wSpeak);
            const hpM = hp * (1 - 0.5 * root._wSpeak);
            const mW = 0.185 * (1 - 0.22 * thM) * (1 - 0.15 * srM)
                       * (1 + 0.10 * hpM) * (1 - 0.12 * talk);
            const mShift = -0.045 * thM;
            // Sorriso de repouso: um leve upturn dos cantos já no neutro (pra
            // não parecer triste), que some quando sério e soma com o feliz.
            const restSmile = 0.015 * (1 - srM);
            const cornerYv = -restSmile - 0.05 * hpM + 0.018 * srM;
            const centerYv = 0.018 * hpM;
            const tiltY = 0.014 * thM;
            const mv = 0.63;
            const openAmt = talk * 0.055;

            const lipSoft = [];      // corpo dos lábios (tênue)
            const lipCore = [];      // linha da boca / bordas / cristas (aceso)
            const mCols = 25;
            for (let i = 0; i < mCols; i++) {
                const s = -1 + 2 * i / (mCols - 1);
                const as2 = s * s;
                const bell = 1 - as2;
                const expY = centerYv + (cornerYv - centerYv) * as2 + tiltY * s;
                const xs = mShift + s * mW;
                const yMid = mv + expY + 0.004 * bell;

                // Borda superior do lábio com ARCO DO CUPIDO anatômico: duas
                // cristas (em |s|≈0.30) e o entalhe do filtro no centro (s=0),
                // afunilando liso até os cantos.
                const crest = Math.exp(-Math.pow((Math.abs(s) - 0.30) / 0.20, 2));
                const philtrum = 0.60 * Math.exp(-as2 / 0.014);
                const cupid = Math.max(0, bell * (0.50 + 0.62 * crest - philtrum));
                const upH = 0.050 * cupid;                        // altura do lábio superior
                const loH = 0.052 * Math.pow(bell, 0.55);         // inferior mais cheio/redondo

                // Articulação de mandíbula: o lábio inferior desce bem mais
                // do que o superior sobe (como uma boca humana falando).
                // Cada ponto do lábio assenta na SUPERFÍCIE do rosto (a boca
                // acompanha o contorno quando a cabeça gira) + relevo leve.
                // Lábio superior: 4 fileiras (borda do cupido → linha da boca).
                // r=0 é a borda externa (a crista do cupido) e r=3 a linha da
                // boca — ambas ACESAS pra riscar o contorno em "M"; o miolo
                // (r=1,2) é corpo tênue.
                for (let r = 0; r < 4; r++) {
                    const k = r / 3;                              // 0 borda cupido → 1 linha da boca
                    const y = yMid - openAmt * 0.30 * bell - upH * (1 - k);
                    const sd = root._depth(xs, y);
                    const zL = (sd !== null ? sd[0] : root._mouthZ)
                               + 0.016 * bell * (0.4 + 0.6 * k);
                    const pp = featDot(xs, y, zL);
                    (r === 0 || r === 3 ? lipCore : lipSoft)
                        .push(pp[0], pp[1], (0.62 + 0.42 * bell) * sizeK);
                }
                // Lábio inferior: 4 fileiras (linha da boca → borda de baixo).
                // r=0 é a linha da boca e r=3 a borda inferior arredondada —
                // as duas acesas contornam o volume; as do meio são o corpo.
                for (let r = 0; r < 4; r++) {
                    const k = r / 3;                              // 0 linha da boca → 1 borda
                    const y = yMid + openAmt * 1.0 * bell + loH * k;
                    const sd = root._depth(xs, y);
                    const zL = (sd !== null ? sd[0] : root._mouthZ)
                               + 0.024 * bell * (1 - 0.45 * k);
                    const pp = featDot(xs, y, zL);
                    (r === 0 || r === 3 ? lipCore : lipSoft)
                        .push(pp[0], pp[1], (0.62 + 0.42 * bell) * (1 - 0.15 * k) * sizeK);
                }
            }
            ctx.fillStyle = "rgba(" + cr + "," + cg + "," + cb + ","
                            + (0.70 * featA).toFixed(3) + ")";
            for (let j = 0; j < lipCore.length; j += 3)
                ctx.fillRect(lipCore[j], lipCore[j + 1], lipCore[j + 2], lipCore[j + 2]);
            ctx.fillStyle = "rgba(" + cr + "," + cg + "," + cb + ","
                            + (0.32 * featA).toFixed(3) + ")";
            for (let j = 0; j < lipSoft.length; j += 3)
                ctx.fillRect(lipSoft[j], lipSoft[j + 1], lipSoft[j + 2], lipSoft[j + 2]);
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
