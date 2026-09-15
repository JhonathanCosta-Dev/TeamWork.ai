pragma Singleton
import QtQuick

// Tema do Team Work AI.
//
// Direção visual: vidro escuro sobre um fundo quase preto azulado, com um
// acento ciano→violeta que só aparece onde importa (foco, ação, quem está
// falando). A regra que segura o conjunto: superfícies são neutras e o brilho
// é caro — se tudo brilha, nada chama atenção.
//
// Os nomes antigos (background, surface, accent, radius…) continuam válidos:
// as telas todas dependem deles. Os tokens novos (glass, accentAlt, glow,
// radiusLarge, elevation…) somam, não substituem.
QtObject {
    // ------------------------------------------------------------------
    // Superfícies — do fundo para a frente
    // ------------------------------------------------------------------
    // Fundo da tela cheia: opaco de propósito, para o holograma e as bolhas
    // terem um preto real por trás em vez do papel de parede do usuário.
    readonly property color backgroundDeep: "#05070d"
    readonly property color background: Qt.rgba(0.035, 0.045, 0.07, 0.94)
    // Vidro: camadas claras com alfa baixo sobre o fundo escuro. Empilhar
    // vidro sobre vidro é o que dá a sensação de profundidade sem sombra.
    readonly property color surface: Qt.rgba(1, 1, 1, 0.045)
    readonly property color surfaceAlt: Qt.rgba(1, 1, 1, 0.075)
    readonly property color surfaceStrong: Qt.rgba(1, 1, 1, 0.11)
    // Painéis que precisam esconder o que está atrás (menus, cartões sobre
    // conteúdo) — vidro translúcido não serve aí.
    readonly property color panel: "#0b0f1a"
    readonly property color panelAlt: "#111624"

    readonly property color border: Qt.rgba(1, 1, 1, 0.09)
    readonly property color borderStrong: Qt.rgba(1, 1, 1, 0.16)

    // ------------------------------------------------------------------
    // Texto
    // ------------------------------------------------------------------
    readonly property color textPrimary: "#e9edf7"
    readonly property color textSecondary: "#96a0b8"
    readonly property color textDisabled: "#5a6479"

    // ------------------------------------------------------------------
    // Acentos
    // ------------------------------------------------------------------
    // O par ciano→violeta é a identidade: ciano para estado e foco, violeta
    // como segunda parada dos gradientes.
    readonly property color accent: "#38d6f5"
    readonly property color accentAlt: "#8b7dfb"
    readonly property color accentDeep: "#1b6ef3"
    readonly property color success: "#4ade9b"
    readonly property color warning: "#fbbf5c"
    readonly property color danger: "#fb7185"
    readonly property color info: "#7dd3fc"

    // Halo de foco/atividade. Usado como cor de uma borda ou retângulo atrás
    // do elemento — Qt não tem box-shadow sem shader.
    function glow(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    // ------------------------------------------------------------------
    // Métricas
    // ------------------------------------------------------------------
    readonly property int radiusLarge: 18
    readonly property int radius: 14
    readonly property int radiusSmall: 9
    readonly property int radiusPill: 999
    readonly property int spacing: 8
    readonly property int spacingLarge: 14
    readonly property int padding: 12

    // ------------------------------------------------------------------
    // Tipografia
    // ------------------------------------------------------------------
    readonly property string fontFamily: "Inter, Cantarell, Noto Sans, sans-serif"
    readonly property string monoFamily: "JetBrains Mono, Fira Code, monospace"
    readonly property int fontSizeTiny: 10
    readonly property int fontSizeSmall: 11
    readonly property int fontSize: 13
    readonly property int fontSizeLarge: 15
    readonly property int fontSizeTitle: 19

    // ------------------------------------------------------------------
    // Animações (curtas — a interface responde, não faz show)
    // ------------------------------------------------------------------
    readonly property int animFast: 120
    readonly property int animNormal: 200
    readonly property int animSlow: 380

    function statusColor(status) {
        switch (status) {
        case "working":
        case "planning":
        case "communicating":
        case "reviewing":
            return accent;
        case "completed":
            return success;
        case "waiting":
        case "paused":
        case "rate_limited":
            return warning;
        case "error":
        case "cancelled":
            return danger;
        case "offline":
            return textDisabled;
        default:
            return textSecondary; // idle
        }
    }

    /// O agente está ocupado com alguma coisa agora?
    function statusBusy(status) {
        return status === "working" || status === "planning"
            || status === "communicating" || status === "reviewing"
            || status === "waiting";
    }

    // Cor fixa por IDENTIDADE do agente (não por status) — usada no chat pra
    // deixar claro de relance quem está falando. As cores dos agentes
    // padrão espelham a cor principal do próprio avatar SVG de cada um
    // (apps/widget/assets/avatars/*.svg), então a identidade visual já
    // combina com o avatar que aparece do lado da mensagem.
    readonly property var _agentColors: ({
        "atlas": "#5aa2ff",
        "forge": "#f5a962",
        "iris": "#4fe3c1",
        "sentinel": "#fb7185",
        "jorginho": "#e08463",
        "speed": "#38d6f5"
    })
    // Paleta pra agentes criados pelo usuário (sem cor fixa conhecida) — cada
    // nome sempre cai na mesma cor (hash determinístico), sem colidir com as
    // cores acima.
    readonly property var _agentFallbackPalette: [
        "#b78bfa", "#4ade9b", "#ff9e64", "#38d6f5", "#c0caf5", "#f472b6"
    ]

    function _deaccent(s) {
        const map = { "á":"a","à":"a","â":"a","ã":"a","é":"e","ê":"e","í":"i",
                      "ó":"o","ô":"o","õ":"o","ú":"u","ü":"u","ç":"c" };
        let out = "";
        for (const ch of s.toLowerCase())
            out += map[ch] ?? ch;
        return out;
    }

    // Cor estável para o nome/menção de um agente (padrão ou criado pelo
    // usuário). Mesma normalização usada no backend (`normalize_name`).
    function agentColor(name) {
        const key = _deaccent(name ?? "");
        if (_agentColors[key] !== undefined)
            return _agentColors[key];
        let hash = 0;
        for (let i = 0; i < key.length; i++)
            hash = (hash * 31 + key.charCodeAt(i)) >>> 0;
        return _agentFallbackPalette[hash % _agentFallbackPalette.length];
    }

    function statusLabel(status) {
        const map = {
            "idle": "ocioso",
            "planning": "planejando",
            "waiting": "aguardando",
            "working": "trabalhando",
            "communicating": "comunicando",
            "reviewing": "revisando",
            "completed": "concluído",
            "paused": "pausado",
            "cancelled": "cancelado",
            "error": "erro",
            "rate_limited": "limite da API",
            "offline": "offline"
        };
        return map[status] ?? status;
    }

    /// Hora no formato do chat ("14:03").
    function clock(d) {
        if (!d || isNaN(d.getTime?.()))
            return "";
        const two = n => (n < 10 ? "0" : "") + n;
        return two(d.getHours()) + ":" + two(d.getMinutes());
    }
}
