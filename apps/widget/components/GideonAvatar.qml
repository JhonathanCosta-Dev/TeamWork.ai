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
    // Rindo: a mandíbula ganha a rajada do riso ("ha-ha-ha") em vez da
    // articulação de fala, e a cabeça sacode junto. Independente de `speaking`
    // porque rir tem ritmo próprio — mais rápido, mais aberto e pulsado.
    property bool laughing: false
    // Emoção atual (persistente). Uma das chaves de _emotions abaixo.
    property string mood: "neutral"
    // Modo "descanso de tela": olhar vaga mais amplo.
    property bool idleShow: false
    // Instância que fica na tela o dia inteiro (modo copiloto): menos quadros
    // por segundo quando ocioso. Um overlay permanente não pode custar o mesmo
    // que o holograma de tela cheia, que é efêmero.
    // A economia é em QUADROS, não em pontos: no repouso o rosto quase não se
    // move (piscar e olhar são lentos), então cair pra ~14 fps não se percebe —
    // já ralear a malha desmancha a silhueta e vira ruído em vez de rosto.
    property bool lowPower: false
    // Aceito por compatibilidade com chamadas antigas; sem efeito na v3.
    property bool cycleAssemble: true

    // Olhar externo (rastreamento facial): com lookActive, o avatar OLHA pra
    // lookAtX/Y [-1..1] em vez de vaguear sozinho (segue quem está na câmera).
    property bool lookActive: false
    property real lookAtX: 0
    property real lookAtY: 0
    // Modo fantoche: com puppet, os canais são dirigidos por puppetBlend
    // (blendshapes do rosto real) em vez do catálogo de emoções.
    property bool puppet: false
    property var puppetBlend: ({})

    // Catálogo de emoções (spec Jorginho v3). Cada emoção define:
    //   color: cor do holograma
    //   g:     olhar de repouso [x, y]  (+x direita, +y baixo; -y = pra cima)
    //   w:     amplitude do vaguear do olhar (0 fixo … 1 amplo)
    //   bl:    intervalo de piscar [min, max] em segundos
    //   hold:  duração ao ser usada como FLASH transiente (s); 0 = persistente
    //   ret:   emoção pra qual voltar após o flash ("" = volta pro mood atual)
    //   ch:    pesos dos canais de morph 0..1 (canais assados: blink, browUp,
    //          browOuterUpL/R, browDown, eyeWide, eyeSquint, smile, cheek,
    //          frown, jawOpen, lipPress, mouthLeft, mouthRight). blink como
    //          base = pálpebras caídas; jawOpen é somado pela fala.
    readonly property var _emotions: ({
        "neutral":    { color: "#6db8ff", g: [0, 0],       w: 0.5, bl: [2.5, 5.0], hold: 0,   ret: "",          ch: { smile: 0.06, browUp: 0.03 } },
        "idle":       { color: "#6db8ff", g: [0, 0],       w: 1.0, bl: [3.5, 6.5], hold: 0,   ret: "",          ch: { smile: 0.12, browUp: 0.04 } },
        "activated":  { color: "#8fd0ff", g: [0, 0],       w: 0.2, bl: [1.4, 3.0], hold: 0.7, ret: "listening", ch: { eyeWide: 0.45, browUp: 0.2, browOuterUpL: 0.5, browOuterUpR: 0.5, smile: 0.25, jawOpen: 0.1 } },
        "listening":  { color: "#6fd0e0", g: [0, 0],       w: 0.2, bl: [4.0, 7.0], hold: 0,   ret: "",          ch: { browOuterUpL: 0.2, browOuterUpR: 0.2, smile: 0.1 } },
        "understood": { color: "#8fe0a0", g: [0, 0],       w: 0.3, bl: [2.0, 4.0], hold: 0.8, ret: "listening", ch: { smile: 0.4, browUp: 0.15, browOuterUpL: 0.3, browOuterUpR: 0.3, eyeSquint: 0.3, blink: 0.18 } },
        "thinking":   { color: "#ffb85e", g: [0.35, -0.32],w: 0.6, bl: [2.8, 5.2], hold: 0,   ret: "",          ch: { browDown: 0.25, eyeSquint: 0.2, lipPress: 0.28, mouthRight: 0.14, cheek: 0.05 } },
        "searching":  { color: "#ffcf7a", g: [0.5, 0.05],  w: 1.0, bl: [2.5, 4.5], hold: 0,   ret: "",          ch: { browOuterUpL: 0.3, browOuterUpR: 0.3, eyeWide: 0.1 } },
        "speaking":   { color: "#7fc8ff", g: [0, 0],       w: 0.35,bl: [2.5, 4.5], hold: 0,   ret: "",          ch: { smile: 0.12, browOuterUpL: 0.1, browOuterUpR: 0.1 } },
        "asking":     { color: "#7fd0e8", g: [0, 0],       w: 0.15,bl: [2.5, 4.5], hold: 0,   ret: "",          ch: { browUp: 0.15, browOuterUpL: 0.4, browOuterUpR: 0.4, eyeWide: 0.25, smile: 0.15 } },
        "uncertain":  { color: "#e0c060", g: [0.15, 0.05], w: 0.5, bl: [2.5, 4.5], hold: 0,   ret: "",          ch: { browOuterUpR: 0.55, browDown: 0.12, lipPress: 0.3, mouthRight: 0.18, eyeSquint: 0.1 } },
        "confused":   { color: "#e0a860", g: [0.2, 0.1],   w: 0.7, bl: [2.0, 4.0], hold: 0,   ret: "",          ch: { browDown: 0.4, browOuterUpR: 0.4, eyeSquint: 0.2, jawOpen: 0.07, frown: 0.14, lipPress: 0.12 } },
        "happy":      { color: "#7fe08a", g: [0, 0],       w: 0.4, bl: [3.0, 5.5], hold: 0,   ret: "",          ch: { smile: 0.7, cheek: 0.5, eyeSquint: 0.35, browUp: 0.05 } },
        "excited":    { color: "#6fe870", g: [0, 0],       w: 0.4, bl: [1.5, 3.0], hold: 0,   ret: "",          ch: { smile: 0.9, cheek: 0.6, eyeWide: 0.4, browUp: 0.2, browOuterUpL: 0.4, browOuterUpR: 0.4, jawOpen: 0.1 } },
        // Rir: sorriso no máximo, bochecha estufada e olhos APERTADOS (blink de
        // base fecha a pálpebra — quem ri de verdade não ri com o olho arregalado).
        // jawOpen fica baixo aqui de propósito: a abertura vem pulsada do ritmo
        // do riso, senão a boca ficaria escancarada e parada.
        "laughing":   { color: "#86efa0", g: [0, -0.06],   w: 0.3, bl: [2.0, 4.0], hold: 2.2, ret: "",          ch: { smile: 0.95, cheek: 0.75, eyeSquint: 0.7, blink: 0.3, browUp: 0.25, browOuterUpL: 0.35, browOuterUpR: 0.35, jawOpen: 0.08 } },
        "concerned":  { color: "#ffa860", g: [0, 0.05],    w: 0.4, bl: [3.5, 6.5], hold: 0,   ret: "",          ch: { browUp: 0.6, browDown: 0.14, frown: 0.35, lipPress: 0.2 } },
        "empathetic": { color: "#9fb0e8", g: [0, 0.05],    w: 0.3, bl: [4.0, 7.0], hold: 0,   ret: "",          ch: { browUp: 0.4, eyeSquint: 0.15, smile: 0.08, blink: 0.12 } },
        "serious":    { color: "#ff8a6e", g: [0, 0],       w: 0.2, bl: [4.0, 7.0], hold: 0,   ret: "",          ch: { browDown: 0.3, eyeSquint: 0.1 } },
        "alert":      { color: "#ff6f5e", g: [0, 0],       w: 0.15,bl: [4.5, 7.5], hold: 0,   ret: "",          ch: { eyeWide: 0.5, browDown: 0.2, browUp: 0.15, lipPress: 0.1 } },
        "apologizing":{ color: "#b0a0e0", g: [0, 0.12],    w: 0.3, bl: [3.5, 6.0], hold: 2.0, ret: "neutral",   ch: { browUp: 0.55, frown: 0.2, blink: 0.15, smile: 0.05 } },
        "success":    { color: "#7fe090", g: [0, 0],       w: 0.4, bl: [2.0, 4.0], hold: 1.4, ret: "idle",      ch: { smile: 0.75, cheek: 0.55, browUp: 0.2, browOuterUpL: 0.4, browOuterUpR: 0.4, eyeSquint: 0.3 } },
        "error":      { color: "#ff5f6e", g: [0, 0.05],    w: 0.3, bl: [3.5, 6.5], hold: 2.5, ret: "neutral",   ch: { browDown: 0.4, browUp: 0.2, eyeSquint: 0.25, frown: 0.3, lipPress: 0.25 } }
    })

    // Estado do flash transiente (reação momentânea que volta pro mood).
    property string _flash: ""
    property real _flashHold: 0
    // Olhar de repouso + amplitude do vaguear (definidos pela emoção atual).
    property real _baseGazeX: 0
    property real _baseGazeY: 0
    property real _wander: 0.5
    property real _blinkMin: 2.5
    property real _blinkMax: 5.0

    // Mostra uma emoção por um instante (a duração `hold` dela) e depois volta
    // sozinho pro mood atual. Usado pra reações momentâneas (ativação,
    // "entendi", tarefa concluída, erro).
    function flash(name) {
        if (!root._emotions[name])
            return;
        root._flash = name;
        root._flashHold = root._emotions[name].hold > 0 ? root._emotions[name].hold : 1.0;
        _applyEmotion();
    }

    // --- dados decodificados ---
    property var _pos: null       // Float32Array (count*3), normalizado [-1,1]
    property var _nor: null       // Float32Array (count*3)
    property var _ao: null        // Float32Array (count)
    // Máscara dos olhos (Uint8Array count): 1 nos índices do morph "blink",
    // que já delimita exatamente o anel das pálpebras — vira o ponto focal
    // do olhar sem precisar de coordenada de tela fixa (o real gira com a
    // pose). Ver _decode().
    property var _eyeMask: null
    // Centro de cada olho em espaço de modelo: [[x,y,z] esquerdo, [x,y,z] direito].
    property var _eyeCtr: null
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

    // --- globo ocular, feito de MILHARES de pontinhos digitais (mesmo
    // padrão do resto da malha) --- layout gerado UMA vez e reaproveitado
    // nos dois olhos. Coordenadas em unidades de RAIO DA ÍRIS (isotrópicas,
    // não esticadas), com a íris centrada na origem: assim a íris continua
    // um círculo de verdade e o formato de amêndoa vem do recorte no render.
    // Estrutura da íris: 0 fibras · 1 limbo · 2 reflexo.
    property var _eyeDotX: null
    property var _eyeDotY: null
    property var _eyeDotSize: null
    // Geometria crua + célula da tabela polar, guardadas porque a cor só pode
    // ser resolvida depois que a LUT da íris chega (XHR assíncrono).
    property var _rawX: null
    property var _rawY: null
    property var _rawSize: null
    property var _rawCell: null      // índice na LUT; 0xFFFF = reflexo (branco)
    // Tabela polar de cores tirada de uma FOTO de íris real
    // (assets/iris-lut.json, gerada de iris-source.png): paleta de 48 cores +
    // uma célula por (ângulo × raio). Cada pontinho da íris pega a cor real da
    // foto na sua posição — cor e estrutura de íris de verdade, mas desenhada
    // em quadradinhos, não pintada.
    property var _irisPal: null      // 48 strings rgba
    property var _irisCells: null    // Uint8Array (na*nr) → índice na paleta
    property int _irisNA: 0
    property int _irisNR: 0
    property real _irisPupil: 0.361  // razão pupila/íris medida na foto
    // Chave (zona × faixa de brilho) pré-ordenada: deixa o laço de desenho
    // trocar de cor umas 20 vezes em vez de uma vez por ponto.
    property var _eyeDotKey: null
    property var _eyeKeyColor: []
    property int _eyeDotCount: 0

    // Esclera, em arrays próprios: ela é uma GRADE COM JITTER, não um
    // espalhamento aleatório. A grade é o que permite os pontos LADRILHAREM
    // (encostarem um no outro) em qualquer tamanho de tela — espalhamento
    // puro deixa buracos e aglomerados, e era isso que fazia o branco virar
    // chuvisco em vez de globo ocular.
    // 5 níveis de grade (passo crescente). O render escolhe o nível conforme o
    // tamanho do olho na tela e desenha TODOS os pontos dele.
    property var _sclLevels: []
    property var _sclColor: []

    // PÁLPEBRAS. A malha escaneada não tem geometria na órbita: medido no
    // face-data.json, a densidade de vértices cai a ⅓–½ da pele normal num
    // raio de ~0.09 em volta do centro do olho. Como a minha abertura tem só
    // 0.043 de meia-altura, sobrava órbita vazia acima e abaixo do olho — o
    // "buraco preto". Estes pontos preenchem essa órbita na cor do rosto.
    property var _lidX: null
    property var _lidY: null
    property var _lidLvl: null
    property int _lidCount: 0

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

    // Mudou o mood: reaplica só se não houver flash no ar (o flash reaplica
    // sozinho quando termina).
    onMoodChanged: if (root._flash.length === 0) _applyEmotion()

    Component.onCompleted: {
        _buildPalette();
        _buildEyeDots();
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

        // Tabela de cores da íris (foto real). Independente do face-data:
        // qualquer das duas cargas pode chegar primeiro, e quem chegar por
        // último resolve as cores (ver _applyIrisLut).
        const lx = new XMLHttpRequest();
        lx.onreadystatechange = function () {
            if (lx.readyState !== XMLHttpRequest.DONE)
                return;
            const t = lx.responseText ?? "";
            if (t.length === 0) {
                console.log("GideonAvatar: iris-lut vazia — íris fica na cor de reserva");
                return;
            }
            try {
                const d = JSON.parse(t);
                root._irisNA = d.na;
                root._irisNR = d.nr;
                root._irisPupil = d.pupilRatio;
                root._irisCells = new Uint8Array(d.cells);
                const pal = [];
                for (const h of d.palette)
                    pal.push("rgba(" + parseInt(h.slice(0, 2), 16) + ","
                             + parseInt(h.slice(2, 4), 16) + ","
                             + parseInt(h.slice(4, 6), 16) + ",0.97)");
                pal.push("rgba(255,253,247,0.95)");   // último = reflexo
                root._irisPal = pal;
                root._applyIrisLut();
                canvas.requestPaint();
            } catch (e) {
                console.log("GideonAvatar: erro na iris-lut:", e);
            }
        };
        lx.open("GET", Qt.resolvedUrl("../assets/iris-lut.json"));
        lx.send();
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

        const bx = [], by = [], bsz = [];
        for (let i = 0; i < root._levels; i++) {
            bx.push(new Float32Array(N));
            by.push(new Float32Array(N));
            bsz.push(new Float32Array(N));
        }
        root._bx = bx;
        root._by = by;
        root._bsz = bsz;
        root._bcount = new Int32Array(root._levels);

        const eyeMask = new Uint8Array(N);
        const blinkIdx = morphs["blink"] ? morphs["blink"].idx : [];
        for (let i = 0; i < blinkIdx.length; i++)
            eyeMask[blinkIdx[i]] = 1;
        root._eyeMask = eyeMask;

        // Centro de cada olho = CENTROIDE do anel da pálpebra (os vértices do
        // morph "blink"), separado por lado. Antes era UM vértice escolhido à
        // mão (530 / 14517), que estava fora do centro: medido, 1.9% da
        // meia-largura da cabeça — em tela cheia retrato dava o olho esquerdo
        // 11.5 px baixo e o direito 10.7 px pra dentro, o que desloca o par e
        // deixa o vão entre os olhos assimétrico.
        // Usa a posição BASE (_pos), não a deformada: com a deformada, piscar
        // arrastava o centroide 1.2–1.35% (~7 px em tela cheia) e o olho
        // escorregava a cada piscada. Globo ocular não se move quando se pisca.
        const cl = [0, 0, 0], cr = [0, 0, 0];
        let nl = 0, nr = 0;
        for (let i = 0; i < blinkIdx.length; i++) {
            const v3 = blinkIdx[i] * 3;
            const t = root._pos[v3] < 0 ? cl : cr;
            t[0] += root._pos[v3];
            t[1] += root._pos[v3 + 1];
            t[2] += root._pos[v3 + 2];
            if (root._pos[v3] < 0) nl++; else nr++;
        }
        if (nl > 0) for (let k = 0; k < 3; k++) cl[k] /= nl;
        if (nr > 0) for (let k = 0; k < 3; k++) cr[k] /= nr;

        // ESPELHA os dois centros. A malha é um escaneamento de rosto real e
        // tem os olhos em alturas diferentes de fato (y = +0.0181 no esquerdo
        // contra -0.0025 no direito): medido no render em tela cheia, isso dava
        // ~9 px de desnível entre as íris, que lê como erro de posicionamento.
        // Assimetria de rosto real é natural numa foto, mas num avatar
        // estilizado ela só parece defeito.
        const ay = (cl[1] + cr[1]) * 0.5;
        const az = (cl[2] + cr[2]) * 0.5;
        const ax = (Math.abs(cl[0]) + Math.abs(cr[0])) * 0.5;
        root._eyeCtr = [[-ax, ay, az], [ax, ay, az]];

        root._ready = true;
        _applyEmotion();
        canvas.requestPaint();
    }

    // ------------------------------------------------------------------
    // Emoção / paleta
    // ------------------------------------------------------------------
    // Aplica a emoção exibida (flash se houver, senão o mood): cor, olhar de
    // repouso, amplitude do vaguear, taxa de piscar e alvos dos canais.
    function _applyEmotion() {
        const name = root._flash.length > 0 ? root._flash : root.mood;
        const e = root._emotions[name] || root._emotions["neutral"];
        root._colorHex = e.color;
        _buildPalette();
        root._baseGazeX = e.g[0];
        root._baseGazeY = e.g[1];
        root._wander = e.w;
        root._blinkMin = e.bl[0];
        root._blinkMax = e.bl[1];
        if (!root._ready)
            return;
        for (const ch of root._morphNames)
            root._cur[ch].tgt = (e.ch[ch] !== undefined ? e.ch[ch] : 0);
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


    // Gera a nuvem de partículas de UM olho (reaproveitada nos dois lados).
    // ~3000 pontos, não 100: a leitura de "íris de verdade" vem de FIBRAS
    // RADIAIS (o estriamento que todo íris tem) — um espalhamento aleatório,
    // por mais denso que seja, lê como ruído dourado, não como íris.
    // Unidades: raio da íris = 1, íris centrada na origem, y+ pra baixo.
    function _buildEyeDots() {
        const dots = [];
        function push(x, y, zone, size, shade) {
            dots.push({ x: x, y: y, z: zone, s: size, sh: shade });
        }

        // --- íris: fibras radiais da borda da pupila até o limbo (zona 0) ---
        // 64 fibras, não 104: com 104 o espaçamento angular no meio do raio
        // (~1,2 px) ficava MENOR que o próprio ponto (~2,4 px), as fibras se
        // fundiam e a íris voltava a parecer pintada. 64 deixa folga entre
        // elas — os pontinhos aparecem, que é o ponto.
        const FIBERS = 64, FSTEP = 15;
        for (let f = 0; f < FIBERS; f++) {
            const a0 = (f / FIBERS) * Math.PI * 2;
            const fib = 0.5 + Math.random() * 0.5;      // brilho da fibra
            const wob = (Math.random() - 0.5) * 0.06;   // fibra não é reta
            for (let s = 0; s < FSTEP; s++) {
                const u = s / (FSTEP - 1);
                const a = a0 + wob * u + (Math.random() - 0.5) * 0.018;
                const r = 0.36 + u * 0.60;
                // clareia junto à pupila (colarete), escurece pro limbo
                push(Math.cos(a) * r, Math.sin(a) * r, 0,
                     0.55 + Math.random() * 0.35,
                     Math.max(0.05, fib * (1.05 - 0.45 * u)));
            }
        }

        // --- anel limbal: borda dourada escura que fecha a íris (zona 1) ---
        for (let i = 0; i < 120; i++) {
            const a = (i / 120) * Math.PI * 2;
            const r = 0.975 + (Math.random() - 0.5) * 0.045;
            push(Math.cos(a) * r, Math.sin(a) * r, 1,
                 0.6 + Math.random() * 0.3, 0.35 + Math.random() * 0.25);
        }

        // --- reflexo da córnea (zona 2) ---
        for (let i = 0; i < 26; i++) {
            const a = Math.random() * Math.PI * 2;
            const r = Math.sqrt(Math.random()) * 0.19;
            push(-0.34 + Math.cos(a) * r, -0.36 + Math.sin(a) * r, 2,
                 0.6 + Math.random() * 0.4, 0.85 + Math.random() * 0.15);
        }
        // segundo reflexo, menor e oposto (luz de preenchimento)
        for (let i = 0; i < 10; i++) {
            const a = Math.random() * Math.PI * 2;
            const r = Math.sqrt(Math.random()) * 0.10;
            push(0.40 + Math.cos(a) * r, 0.30 + Math.sin(a) * r, 2,
                 0.5 + Math.random() * 0.3, 0.5 + Math.random() * 0.2);
        }

        // Guarda a geometria crua. A COR não sai daqui: ela vem da foto de
        // íris (LUT), que chega por XHR e pode chegar depois disto.
        const n = dots.length;
        const rx = new Float32Array(n), ry = new Float32Array(n);
        const rs = new Float32Array(n), rc = new Uint16Array(n);
        for (let i = 0; i < n; i++) {
            const d = dots[i];
            rx[i] = d.x; ry[i] = d.y; rs[i] = d.s;
            rc[i] = d.z === 2 ? 0xFFFF : 0;   // reflexo não consulta a foto
        }
        root._rawX = rx;
        root._rawY = ry;
        root._rawSize = rs;
        root._rawCell = rc;
        root._applyIrisLut();

        // ------------------------------------------------------------------
        // Esclera: grade com jitter. O jitter tira a cara de varredura
        // regular; a GRADE garante espaçamento uniforme, que é o que deixa os
        // pontos ladrilharem em vez de deixar buracos (chuvisco).
        // ------------------------------------------------------------------
        // NÍVEIS de grade (tipo mipmap), não uma grade fina que o render
        // subamostra. Motivo medido: pegar "um a cada N" de uma grade fina não
        // dá um subconjunto uniforme — em ordem de varredura vira LISTRAS, e
        // embaralhado vira aglomerado aleatório (Poisson) com buracos. Nos dois
        // casos a esclera fica manchada. Cada nível aqui já é uma grade
        // completa e uniforme no seu próprio passo; o render escolhe o nível
        // pelo tamanho na tela e desenha TODOS os pontos dele. Aí ladrilha.
        const levels = [];
        for (let lv = 0; lv < 5; lv++) {
            const G = 0.028 * Math.pow(1.8, lv);
            const sxs = [], sys = [], sks = [];
            for (let gx = -2.6; gx <= 2.6; gx += G) {
                for (let gy = -1.35; gy <= 1.15; gy += G) {
                    const x = gx + (Math.random() - 0.5) * G * 0.55;
                    const y = gy + (Math.random() - 0.5) * G * 0.55;
                    // Buraco central pequeno: a íris passeia com o olhar (até
                    // 0.42 raios), e com buraco grande a borda dela descobria
                    // uma meia-lua de fundo escuro do lado oposto. 0.40 deixa
                    // margem: a íris alcança 1.00-0.42 = 0.58 no pior caso.
                    if (x * x + y * y < 0.40 * 0.40)
                        continue;
                    // Sombra da órbita embutida no ponto (sem degradê pintado):
                    // escurece nos cantos e sob a pálpebra de cima.
                    const corner = Math.max(0, Math.abs(x) - 1.25) * 0.55;
                    const upper = Math.max(0, -y - 0.55) * 0.55;
                    const sh = Math.max(0, Math.min(1,
                        1.0 - corner - upper - Math.random() * 0.08));
                    sxs.push(x);
                    sys.push(y);
                    sks.push(Math.max(0, Math.min(5, Math.floor(sh * 6))));
                }
            }
            // Ordena por faixa de brilho só pra agrupar as trocas de fillStyle.
            const order = [];
            for (let i = 0; i < sxs.length; i++)
                order.push(i);
            order.sort((a, b) => sks[a] - sks[b]);
            const m = order.length;
            const sX = new Float32Array(m), sY = new Float32Array(m), sK = new Uint8Array(m);
            for (let i = 0; i < m; i++) {
                const o = order[i];
                sX[i] = sxs[o]; sY[i] = sys[o]; sK[i] = sks[o];
            }
            levels.push({ x: sX, y: sY, k: sK, g: G, n: m });
        }

        // Branco do globo ocular, escurecido nas faixas de sombra.
        const stab = [];
        for (let k = 0; k < 6; k++) {
            const mm = 0.34 + 0.66 * ((k + 0.5) / 6);
            stab.push("rgba("
                + Math.round(230 * mm) + ","
                + Math.round(227 * mm) + ","
                + Math.round(219 * mm) + ",0.97)");
        }

        root._sclLevels = levels;
        root._sclColor = stab;

        // ------------------------------------------------------------------
        // Pálpebras: grade com jitter cobrindo a órbita (o vazio do scan).
        // Passo casado com o espaçamento de vértice do rosto (~0.018 em
        // unidades de modelo = 0.42 em raios de íris), pra a textura ficar
        // igual à do resto da malha em vez de virar remendo.
        // ------------------------------------------------------------------
        const LW = 2.44, LH = 2.28, LG = 0.42;
        const lx = [], ly = [], ll = [];
        for (let gx = -LW; gx <= LW; gx += LG) {
            for (let gy = -LH; gy <= LH; gy += LG) {
                const x = gx + (Math.random() - 0.5) * LG * 0.7;
                const y = gy + (Math.random() - 0.5) * LG * 0.7;
                const e2 = (x / LW) * (x / LW) + (y / LH) * (y / LH);
                if (e2 > 1)
                    continue;
                // Sombra da dobra em cima, luz na pálpebra de baixo — e o miolo
                // (onde o olho vai) fica escuro, que é o recuo da órbita.
                const up = Math.max(0, -y - 0.6) * 0.30;
                const lo = Math.max(0, y - 0.4) * 0.16;
                const t = Math.max(0.18, Math.min(1, 0.62 + lo - up
                        + (Math.random() - 0.5) * 0.16));
                lx.push(x);
                ly.push(y);
                ll.push(Math.max(0, Math.min(root._levels - 1,
                        Math.round(t * (root._levels - 1)))));
            }
        }
        // Agrupa por nível pra reduzir troca de fillStyle.
        const lord = [];
        for (let i = 0; i < lx.length; i++)
            lord.push(i);
        lord.sort((a, b) => ll[a] - ll[b]);
        const nL = lord.length;
        const LX = new Float32Array(nL), LY = new Float32Array(nL), LL = new Uint8Array(nL);
        for (let i = 0; i < nL; i++) {
            const o = lord[i];
            LX[i] = lx[o]; LY[i] = ly[o]; LL[i] = ll[o];
        }
        root._lidX = LX;
        root._lidY = LY;
        root._lidLvl = LL;
        root._lidCount = nL;
    }

    // Resolve a cor de cada pontinho da íris consultando a tabela tirada da
    // FOTO na posição polar do ponto, e agrupa os pontos por cor.
    // O agrupamento é por desempenho: são 48 cores, então o laço de desenho
    // troca fillStyle ~48 vezes por olho em vez de uma vez por ponto (com as
    // 2160 cores cruas da foto seriam ~1000 trocas por olho por quadro).
    // Chamada nas duas pontas (fim de _buildEyeDots e fim da carga da LUT):
    // quem chegar por último é que faz o trabalho.
    function _applyIrisLut() {
        if (root._rawX === null || root._irisPal === null || root._irisCells === null)
            return;

        const n = root._rawX.length;
        const NA = root._irisNA, NR = root._irisNR, P0 = root._irisPupil;
        const NP = root._irisPal.length;          // 48 cores + reflexo no fim
        const GLINT = NP - 1;
        const TAU = Math.PI * 2;

        // Índice de cor por ponto.
        const pi = new Uint8Array(n);
        for (let i = 0; i < n; i++) {
            if (root._rawCell[i] === 0xFFFF) {
                pi[i] = GLINT;
                continue;
            }
            const x = root._rawX[i], y = root._rawY[i];
            const r = Math.sqrt(x * x + y * y);
            // A foto vai da borda da pupila (P0) ao limbo (1.0).
            let t = (r - P0) / (1 - P0);
            t = t < 0 ? 0 : (t > 0.999 ? 0.999 : t);
            let a = Math.atan2(y, x);
            if (a < 0)
                a += TAU;
            const ia = Math.min(NA - 1, Math.floor(a / TAU * NA));
            const ir2 = Math.min(NR - 1, Math.floor(t * NR));
            pi[i] = root._irisCells[ia * NR + ir2];
        }

        // Ordenação por contagem (agrupa por cor sem sort comparativo).
        const cnt = new Int32Array(NP + 1);
        for (let i = 0; i < n; i++)
            cnt[pi[i]]++;
        const start = new Int32Array(NP + 1);
        let acc = 0;
        for (let k = 0; k < NP; k++) {
            start[k] = acc;
            acc += cnt[k];
        }
        const xs = new Float32Array(n), ys = new Float32Array(n);
        const ss = new Float32Array(n), ks = new Uint8Array(n);
        const cur = Int32Array.from(start);
        for (let i = 0; i < n; i++) {
            const k = pi[i], j = cur[k]++;
            xs[j] = root._rawX[i];
            ys[j] = root._rawY[i];
            ss[j] = root._rawSize[i];
            ks[j] = k;
        }

        root._eyeDotX = xs;
        root._eyeDotY = ys;
        root._eyeDotSize = ss;
        root._eyeDotKey = ks;
        root._eyeKeyColor = root._irisPal;
        root._eyeDotCount = n;
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
        interval: (root.speaking || root.listening || root.laughing)
                  ? 33 : (root.lowPower ? 70 : 45)
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
            // Enquadramento: medido direto em face-data.json (pontos
            // visíveis de frente, percentis 1–99) — a cabeça é mais alta
            // (Y) que larga (X), 1.881 contra 1.453, então o eixo que aperta
            // o zoom depende do formato do contêiner (quadrado, retrato ou
            // paisagem), não de um fator único como antes. FILL mira o meio
            // da faixa de 70–80% pedida, com folga pra sobrancelha erguida/
            // riso/leve giro de cabeça não cortar ponta de nariz ou queixo.
            const FACE_X_SPAN = 1.453, FACE_Y_SPAN = 1.881, FILL = 0.78;
            const R = Math.min(W / FACE_X_SPAN, H / FACE_Y_SPAN) * FILL;
            // Ponto do meio da testa (ancoragem da marca de identidade, mais
            // abaixo): medido offline em face-data.json — o índice com maior
            // Y entre os quase no eixo central (|X|<0.05, 0.45<Y<0.75, AO=1).
            // Específico deste face-data.json; se o modelo for regerado,
            // recalcular.
            const FOREHEAD_IDX = 12598;
            // Pontos menores com a malha densa (9000) → definição mais fina.
            const dotSize = Math.max(1, Math.round(R * 0.011));

            // -- flash transiente: conta o tempo e volta pro mood ao expirar --
            if (root._flash.length > 0) {
                root._flashHold -= dt;
                if (root._flashHold <= 0) {
                    root._flash = "";
                    root._applyEmotion();
                }
            }

            // -- comportamento: piscar (taxa da emoção), olhar (repouso da
            //    emoção + vaguear), fala --
            root._blinkT += dt;
            if (root._blinkT > root._nextBlink) {
                root._blinkT = 0;
                root._nextBlink = root._blinkMin
                                + Math.random() * (root._blinkMax - root._blinkMin);
            }
            const blinkEnv = Math.max(0, 1 - Math.abs(root._blinkT - 0.07) / 0.07);

            if (root.lookActive) {
                // Segue quem está na webcam. A imagem da câmera é crua (não
                // espelhada), então inverte o X pra SEGUIR o usuário (olhar
                // pra onde ele está), não espelhar. Y (cima/baixo) fica igual.
                root._gazeTX = -root.lookAtX * 0.9;
                root._gazeTY = root.lookAtY * 0.6;
            } else {
                root._nextSaccade -= dt;
                if (root._nextSaccade < 0) {
                    // Vaguear em torno do olhar de repouso; idleShow amplia.
                    const amp = root._wander * (root.idleShow ? 1.5 : 1.0);
                    root._nextSaccade = 1.5 + Math.random() * 4;
                    root._gazeTX = root._baseGazeX + (Math.random() - 0.5) * 0.5 * amp;
                    root._gazeTY = root._baseGazeY + (Math.random() - 0.5) * 0.24 * amp;
                }
            }
            // Segue rápido quando rastreando um rosto; suave no repouso.
            const gazeLambda = root.lookActive ? 6 : 3;
            root._gazeX = root._damp(root._gazeX, root._gazeTX, gazeLambda, dt);
            root._gazeY = root._damp(root._gazeY, root._gazeTY, gazeLambda, dt);

            let jawTalk = 0;
            let laughBob = 0;
            if (root.laughing) {
                // Rajada do riso: sílabas mais rápidas e mais abertas que a fala,
                // moduladas por um envelope lento — o riso vem em ondas, não num
                // ritmo de metrônomo. O expoente < 1 encurta o fechamento, o que
                // dá o "ha!" seco em vez de um bocejo senoidal.
                root._talkPhase += dt * 17;
                const syl = Math.pow(Math.abs(Math.sin(root._talkPhase)), 0.65);
                const wave = 0.62 + 0.38 * Math.abs(Math.sin(root._talkPhase * 0.17));
                jawTalk = 0.1 + 0.34 * syl * wave;
                laughBob = syl * wave;
            } else if (root.speaking) {
                root._talkPhase += dt * 11;
                jawTalk = 0.1 + 0.16 * Math.abs(Math.sin(root._talkPhase)
                                                * Math.sin(root._talkPhase * 0.37 + 1.7));
            }

            // Modo fantoche: os alvos dos canais vêm do rosto real (puppetBlend)
            // em vez da emoção. Serve pra você calibrar como cada expressão mexe.
            const pup = root.puppet;
            const pb = root.puppetBlend;

            // -- suaviza canais e aplica morphs sobre a base --
            const work = root._work;
            work.set(root._pos);
            for (const name of root._morphNames) {
                const ch = root._cur[name];
                let target = pup ? (pb[name] !== undefined ? pb[name] : 0) : ch.tgt;
                if (name === "blink")
                    target = Math.min(1, target + blinkEnv);
                if (name === "jawOpen" && !pup)
                    target = Math.min(1, target + jawTalk);
                if (name === "eyeWide" && root.listening && !pup)
                    target = Math.min(1, target + 0.3);
                // No fantoche a resposta é mais direta (menos suavização).
                ch.cur = root._damp(ch.cur, target, name === "blink" ? 26 : (pup ? 14 : 7), dt);
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
            // Rindo, a cabeça joga pra trás (pitch positivo = olhando pra cima)
            // e sacode no ritmo das sílabas — é o que separa "boca abrindo" de
            // "rindo de verdade".
            const yaw = root._gazeX * 0.5 + Math.sin(t * 0.31) * 0.06
                      + laughBob * 0.03;
            const pitch = -root._gazeY * 0.4 + Math.sin(t * 0.23 + 1.3) * 0.04
                        + (root.laughing ? 0.05 + laughBob * 0.06 : 0);
            const cyw = Math.cos(yaw), syw = Math.sin(yaw);
            const cpi = Math.cos(pitch), spi = Math.sin(pitch);
            const breathe = 1 + Math.sin(t * 0.7) * 0.006;

            const lx = 0.3, ly = 0.34, lz = 0.89;   // luz frontal + canto sup-esq
            // Quicada vertical do riso (o corpo inteiro sacode, não só a boca).
            const cx = W / 2, cy = H / 2 + laughBob * R * 0.022;

            const bx = root._bx, by = root._by, bsz = root._bsz, bcount = root._bcount;
            bcount.fill(0);
            const nor = root._nor, ao = root._ao, tw = root._twinkle, eyeMask = root._eyeMask;

            // Densidade adaptativa ao tamanho: o holograma pequeno usa ~9000
            // (leve); em tela cheia / descanso de tela cresce até usar TODOS os
            // pontos (definição máxima). Amostragem por passo uniforme.
            const renderN = Math.min(N, Math.max(9000, Math.round(R * 42)));
            const stepN = N / renderN;

            for (let kk = 0; kk < renderN; kk++) {
                const i = (kk * stepN) | 0;
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
                // AO com piso linear (0.35+0.65·a), não cúbico: o cubo
                // (a³) crushava justo a faixa onde a AO é mais baixa por
                // natureza — olho/nariz/boca (medido: AO média ~0.61–0.86
                // ali, contra ~0.85–1.0 no resto da cabeça) — e era exatamente
                // ali que a expressão se perdia.
                let bright = (0.08 + 1.05 * (0.55 * facing * facing + 0.45 * diffuse))
                           * (0.35 + 0.65 * a);
                bright *= 0.94 + 0.06 * Math.sin(t * 1.7 + tw[i]);
                bright *= 0.62 + persp * 0.38;
                if (bright > 1)
                    bright = 1;

                let lvl = (bright * LV) | 0;
                if (lvl >= LV)
                    lvl = LV - 1;
                if (lvl < 0)
                    lvl = 0;

                // Profundidade: pontos mais perto da câmera (nariz, lábios)
                // ficam maiores; laterais/têmporas (mais longe) ficam
                // menores — evita a aparência de "grade uniforme" e reforça
                // as áreas importantes.
                const perspT = Math.max(0, Math.min(1, (persp - 0.90) / 0.65));
                let ptSize = dotSize * (0.75 + 0.55 * perspT);
                if (lvl >= LV - 2)
                    ptSize += 1;
                // O anel natural da pálpebra (scan real) fica por baixo do
                // globo ocular digital (esclera/íris/pupila abaixo) — SEM
                // reforço de brilho aqui, senão a crista clara do scan bruto
                // compete com os pontinhos do olho e afoga esclera/íris numa
                // amêndoa lisa (era exatamente o defeito reportado).
                if (eyeMask[i] === 1)
                    ptSize *= 0.85;

                const k = bcount[lvl]++;
                bx[lvl][k] = sx;
                by[lvl][k] = sy;
                bsz[lvl][k] = ptSize;
            }

            // -- desenha --
            ctx.clearRect(0, 0, W, H);

            // Halo: escurece o fundo ATRÁS da cabeça em fusão normal (não
            // aditiva) — separa a silhueta de qualquer coisa por trás dela,
            // do painel escuro do app a uma janela clara no modo copiloto,
            // que fica sobreposto à área de trabalho.
            ctx.globalCompositeOperation = "source-over";
            const halo = ctx.createRadialGradient(cx, cy, R * 0.15, cx, cy, R * 1.3);
            halo.addColorStop(0, "rgba(6,8,12,0.05)");
            halo.addColorStop(0.6, "rgba(6,8,12,0.42)");
            halo.addColorStop(1, "rgba(6,8,12,0)");
            ctx.fillStyle = halo;
            ctx.beginPath();
            ctx.arc(cx, cy, R * 1.3, 0, Math.PI * 2);
            ctx.fill();

            ctx.globalCompositeOperation = "lighter";
            for (let lvl = 0; lvl < LV; lvl++) {
                const count = bcount[lvl];
                if (!count)
                    continue;
                ctx.fillStyle = root._palette[lvl];
                const xs = bx[lvl], ys = by[lvl], szs = bsz[lvl];
                for (let k = 0; k < count; k++) {
                    const s = szs[k];
                    ctx.fillRect(xs[k], ys[k], s, s);
                }
            }

            // Olhos digitais, construídos em 3D SOBRE UMA ESFERA (globo
            // ocular) e projetados pela MESMA rotação da malha. Antes o olho
            // era montado em espaço de TELA (retângulo alinhado aos eixos):
            // ao virar a cabeça ele não encurtava nem inclinava, ficava um
            // decalque plano colado no rosto. Agora cada pontinho tem posição
            // 3D real na esfera, então o olho encurta, inclina e a íris vira
            // elipse sozinha — a curvatura sai da geometria, não de truque 2D.
            //
            // Proporções em unidades de modelo (meia-largura da cabeça ≈ 0.73),
            // frouxamente calibradas em anatomia humana: fenda palpebral com
            // largura ≈ 1,8× o raio do globo, íris ≈ 43% da largura da fenda e
            // mais ALTA que a abertura (fica aparada em cima e embaixo, é o que
            // dá o olhar humano em vez de olho arregalado de boneco).
            {
                const blinkClose = root._cur["blink"] ? root._cur["blink"].cur : 0;
                const eyeOpen = Math.max(0, 1 - blinkClose * 1.18);
                if (eyeOpen > 0.03 && root._eyeDotCount > 0) {
                    ctx.globalCompositeOperation = "source-over";

                    const Rb = 0.103;              // raio do globo ocular
                    const AW = 0.094, AH = 0.043;  // meia-abertura da fenda
                    const IR = 0.043;              // raio da íris
                    const Rb2 = Rb * Rb, Rb95 = Rb * 0.95;
                    const lid = 0.14 + 0.86 * eyeOpen;

                    const gaU = Math.max(-1, Math.min(1, root._gazeX)) * IR * 0.42;
                    const gaV = Math.max(-1, Math.min(1, -root._gazeY)) * IR * 0.42;
                    const eyeAlpha = Math.min(1, eyeOpen * 1.3);
                    const eDot = Math.max(1, dotSize * 0.6);
                    const eyeN = Math.max(140,
                        Math.min(root._eyeDotCount, Math.round(R * 13)));
                    const eyeStep = root._eyeDotCount / eyeN;

                    // Contorno da fenda em coordenadas locais normalizadas
                    // (x em ±1 = canto a canto, y em unidades de AH). Pontos de
                    // controle mais afastados dos cantos que antes: puxados pra
                    // dentro, a curva corria pro canto e fechava em BICO, o que
                    // dava o olho "puxadinho" de gato.
                    const OUT = [-1.0, 0.02], INN = [1.0, -0.03];
                    const UC1 = [-0.75, -1.30], UC2 = [0.70, -1.24];
                    const LC1 = [0.72, 0.95], LC2 = [-0.75, 0.98];
                    const NSEG = 15;

                    if (root._eyeCtr === null)
                        return;
                    for (let e = 0; e < 2; e++) {
                        const ctr = root._eyeCtr[e];
                        const ex = ctr[0], ey = ctr[1], ez = ctr[2];

                        // Base local do olho. A normal é SINTÉTICA (pra frente,
                        // inclinada pro lado de fora), não a do vértice-âncora:
                        // medido no face-data.json, o âncora do olho direito
                        // (14517) cai numa superfície virada pra CIMA — normal
                        // (0.07, 0.98, 0.16) contra (-0.08, 0.10, 0.99) do
                        // esquerdo — e isso dava opacidade 0.35 num olho e 1.00
                        // no outro (um lado do rosto saía mais claro).
                        const eSign = ex >= 0 ? 1 : -1;
                        const mirror = e === 0 ? 1 : -1;

                        // Visibilidade: usa uma normal inclinada pra fora SÓ
                        // pra decidir quando o olho desaparece ao virar a
                        // cabeça. Ela NÃO entra na geometria (ver abaixo).
                        const vnx = eSign * 0.35, vnz = 0.937;
                        const rnZ0 = -vnx * syw + vnz * cyw;
                        const rnZ = rnZ0 * cpi;
                        const sideAlpha = Math.max(0, Math.min(1, (rnZ - 0.01) / 0.42));
                        if (sideAlpha <= 0.01)
                            continue;

                        // Base local da GEOMETRIA: reta pra frente (0,0,1), sem
                        // inclinação lateral. Olho humano tem os globos
                        // PARALELOS; com a normal inclinada pra fora o polo da
                        // esfera — onde a íris centra — avançava mais nessa
                        // direção que os cantos da fenda e saía do meio da
                        // abertura: medido, a íris ficava ~11% pra fora nos dois
                        // olhos, o que lê como VESGO (divergente).
                        // Centro do globo, recuado sob a superfície do rosto.
                        const Cx0 = ex, Cy0 = ey, Cz0 = ez - Rb95;

                        // Projeta um ponto (a,b) da SUPERFÍCIE DA ESFERA.
                        // Escreve em _sx/_sy pra não alocar array por ponto
                        // (são milhares por quadro).
                        let _sx = 0, _sy = 0;
                        const pt = function (a, b, zFix) {
                            let zz;
                            if (zFix !== undefined) {
                                zz = zFix;
                            } else {
                                zz = Rb2 - a * a - b * b;
                                zz = zz > 0 ? Math.sqrt(zz) : 0;
                            }
                            const mx = Cx0 + a;
                            const my = Cy0 + b;
                            const mz = Cz0 + zz;
                            const X = mx * cyw + mz * syw;
                            const Z0 = -mx * syw + mz * cyw;
                            const Y = my * cpi - Z0 * spi;
                            const Zf = my * spi + Z0 * cpi;
                            const pp = 1 / (1 - Zf * 0.34);
                            _sx = cx + X * R * pp * breathe;
                            _sy = cy - Y * R * pp * breathe;
                        };

                        // Escala de tela: quantos pixels vale 1 raio de íris.
                        // Medida no eixo VERTICAL, que o giro da cabeça não
                        // encurta — no horizontal ela mudaria com o yaw e faria
                        // o nível da grade da esclera oscilar.
                        pt(0, 0);
                        const c0x = _sx, c0y = _sy;
                        pt(0, IR);
                        const irPx = Math.max(1, Math.abs(_sy - c0y));

                        // Contorno: amostra as duas bezier em espaço LOCAL e
                        // projeta cada amostra, então o recorte também segue a
                        // curvatura e o giro da cabeça.
                        const ox = [], oy = [];
                        const bez = function (P0, C1, C2, P1, t) {
                            const mt = 1 - t;
                            const w0 = mt * mt * mt, w1 = 3 * mt * mt * t;
                            const w2 = 3 * mt * t * t, w3 = t * t * t;
                            const a = (w0 * P0[0] + w1 * C1[0] + w2 * C2[0] + w3 * P1[0])
                                    * mirror * AW;
                            const b = (w0 * P0[1] + w1 * C1[1] + w2 * C2[1] + w3 * P1[1])
                                    * AH * lid;
                            // zz = Rb: o contorno fica no PLANO tangente ao
                            // polo, não na esfera. Na esfera os cantos recuam
                            // (z 0.599 contra 0.660 do polo), ganham menos
                            // ampliação em perspectiva, e o MEIO da abertura
                            // deixava de coincidir com a íris — calculado,
                            // -8.2%, que é o olhar vesgo. No plano os cantos e
                            // o polo têm a mesma profundidade e a íris fica
                            // exatamente no centro. Os PONTINHOS seguem na
                            // esfera, então a curvatura continua ali.
                            pt(a, b, Rb);
                            ox.push(_sx);
                            oy.push(_sy);
                        };
                        for (let s = 0; s <= NSEG; s++)
                            bez(OUT, UC1, UC2, INN, s / NSEG);
                        const upperEnd = ox.length;      // cílios usam só esta parte
                        for (let s = 1; s < NSEG; s++)
                            bez(INN, LC1, LC2, OUT, s / NSEG);

                        // Pálpebras primeiro, FORA de qualquer recorte: elas
                        // fecham a órbita vazia do scan. Ficam no plano tangente
                        // (a órbita é mais larga que o raio do globo, então a
                        // esfera não serve aqui) e usam a paleta do humor, pra
                        // ler como pele e não como remendo.
                        if (root._lidCount > 0) {
                            ctx.globalAlpha = sideAlpha;
                            let lastL = -1;
                            for (let q = 0; q < root._lidCount; q++) {
                                const lv2 = root._lidLvl[q];
                                if (lv2 !== lastL) {
                                    ctx.fillStyle = root._palette[lv2];
                                    lastL = lv2;
                                }
                                pt(root._lidX[q] * IR, root._lidY[q] * IR, Rb);
                                const ls2 = dotSize;
                                ctx.fillRect(_sx - ls2 * 0.5, _sy - ls2 * 0.5, ls2, ls2);
                            }
                        }

                        ctx.save();
                        ctx.beginPath();
                        ctx.moveTo(ox[0], oy[0]);
                        for (let s = 1; s < ox.length; s++)
                            ctx.lineTo(ox[s], oy[s]);
                        ctx.closePath();

                        // Cavidade escura: fundo CHAPADO. Segura o preto da
                        // pupila e impede os pontos dourados do rosto de vazarem
                        // entre os pontos da esclera. É ela que FORMA a pupila —
                        // a íris não tem fibra dentro de r<0.36, então o que
                        // aparece nesse miolo é este fundo.
                        ctx.globalAlpha = sideAlpha;
                        ctx.fillStyle = "rgba(9,7,6,0.96)";
                        ctx.fill();
                        ctx.clip();

                        // Esclera: nível de grade cujo passo, na tela, chega
                        // mais perto do tamanho de ponto desejado — e o passo
                        // vira o tamanho do ponto, o que faz eles ladrilharem.
                        ctx.globalAlpha = eyeAlpha * sideAlpha;
                        if (root._sclLevels.length > 0) {
                            let lv = root._sclLevels[0], bestD = 1e9;
                            for (let li = 0; li < root._sclLevels.length; li++) {
                                const cand = root._sclLevels[li];
                                const d = Math.abs(cand.g * irPx - eDot);
                                if (d < bestD) { bestD = d; lv = cand; }
                            }
                            const sPx = Math.max(1, lv.g * irPx * 1.12);
                            let lastSK = -1;
                            for (let j = 0; j < lv.n; j++) {
                                const sk = lv.k[j];
                                if (sk !== lastSK) {
                                    ctx.fillStyle = root._sclColor[sk];
                                    lastSK = sk;
                                }
                                pt(lv.x[j] * IR, lv.y[j] * IR);
                                ctx.fillRect(_sx - sPx * 0.5, _sy - sPx * 0.5, sPx, sPx);
                            }
                        }

                        // Íris, limbo e reflexo. O olhar desliza a calota pela
                        // esfera (gaU/gaV somados em a/b): a íris some no bordo
                        // e vira elipse sozinha, como num olho de verdade.
                        let lastKey = -1;
                        for (let kk = 0; kk < eyeN; kk++) {
                            const j = (kk * eyeStep) | 0;
                            const key = root._eyeDotKey[j];
                            if (key !== lastKey) {
                                ctx.fillStyle = root._eyeKeyColor[key];
                                lastKey = key;
                            }
                            pt(root._eyeDotX[j] * IR + gaU,
                               root._eyeDotY[j] * IR + gaV);
                            const ds = Math.max(1, eDot * root._eyeDotSize[j]);
                            ctx.fillRect(_sx - ds * 0.5, _sy - ds * 0.5, ds, ds);
                        }

                        ctx.restore();

                        // Cílios: pontinhos na pálpebra de cima, reaproveitando
                        // as amostras já projetadas do contorno (fora do
                        // recorte, senão seriam aparados).
                        ctx.globalAlpha = sideAlpha * eyeOpen;
                        ctx.fillStyle = "rgba(26,17,10,0.85)";
                        for (let s = 0; s < upperEnd; s++) {
                            const ls = Math.max(1, eDot * (s % 3 === 0 ? 1.15 : 0.8));
                            ctx.fillRect(ox[s] - ls * 0.5, oy[s] - ls * 0.5, ls, ls);
                        }
                    }

                    ctx.globalAlpha = 1;
                    ctx.globalCompositeOperation = "lighter";
                }
            }

            // Marca de identidade: pequeno nó de circuito na testa. É um
            // PONTO REAL do modelo (índice medido offline em face-data.json —
            // meio da testa, no eixo central, alta AO/frente), então gira com
            // a pose em vez de ficar colado na tela. Cor secundária
            // (dourado), bem sutil — não compete com a cor do humor.
            if (FOREHEAD_IDX < N) {
                const bi = FOREHEAD_IDX * 3;
                const hx = work[bi], hy = work[bi + 1], hz = work[bi + 2];
                const hX = hx * cyw + hz * syw;
                const hZ0 = -hx * syw + hz * cyw;
                const hY = hy * cpi - hZ0 * spi;
                const hZ = hy * spi + hZ0 * cpi;
                const hPersp = 1 / (1 - hZ * 0.34);
                const hsx = cx + hX * R * hPersp * breathe;
                const hsy = cy - hY * R * hPersp * breathe;
                const markR = R * 0.045;
                const pulse = 0.5 + 0.5 * Math.sin(t * 1.3);

                ctx.strokeStyle = "rgba(232,199,107,0.5)";
                ctx.fillStyle = "rgba(232,199,107,0.7)";
                ctx.lineWidth = Math.max(1, R * 0.006);
                ctx.beginPath();
                for (let k = 0; k < 6; k++) {
                    const ang = Math.PI / 6 + k * Math.PI / 3;
                    const px = hsx + Math.cos(ang) * markR;
                    const py = hsy + Math.sin(ang) * markR;
                    if (k === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
                }
                ctx.closePath();
                ctx.stroke();
                ctx.beginPath();
                ctx.arc(hsx, hsy, markR * 0.26 * (0.85 + 0.3 * pulse), 0, Math.PI * 2);
                ctx.fill();
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