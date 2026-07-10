pragma Singleton
import QtQuick

// Tema do Team Work AI: escuro semitransparente, discreto e leve.
QtObject {
    // Superfícies
    readonly property color background: Qt.rgba(0.07, 0.08, 0.10, 0.92)
    readonly property color surface: Qt.rgba(0.12, 0.13, 0.16, 0.95)
    readonly property color surfaceAlt: Qt.rgba(0.16, 0.17, 0.21, 0.95)
    readonly property color border: Qt.rgba(1, 1, 1, 0.08)

    // Texto
    readonly property color textPrimary: "#e8eaf0"
    readonly property color textSecondary: "#9aa0ae"
    readonly property color textDisabled: "#5c6270"

    // Destaques
    readonly property color accent: "#7aa2f7"
    readonly property color success: "#9ece6a"
    readonly property color warning: "#e0af68"
    readonly property color danger: "#f7768e"
    readonly property color info: "#7dcfff"

    // Métricas
    readonly property int radius: 12
    readonly property int radiusSmall: 8
    readonly property int spacing: 8
    readonly property int padding: 12

    // Tipografia
    readonly property string fontFamily: "Inter, Cantarell, Noto Sans, sans-serif"
    readonly property string monoFamily: "JetBrains Mono, Fira Code, monospace"
    readonly property int fontSizeSmall: 11
    readonly property int fontSize: 13
    readonly property int fontSizeLarge: 15

    // Animações (curtas, sem efeitos pesados)
    readonly property int animFast: 120
    readonly property int animNormal: 200

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

    // Cor fixa por IDENTIDADE do agente (não por status) — usada no chat pra
    // deixar claro de relance quem está falando. As cores dos quatro agentes
    // padrão espelham a cor principal do próprio avatar SVG de cada um
    // (apps/widget/assets/avatars/*.svg), então a identidade visual já
    // combina com o avatar que aparece do lado da mensagem.
    readonly property var _agentColors: ({
        "atlas": "#7aa2f7",
        "forge": "#e0af68",
        "iris": "#73daca",
        "sentinel": "#f7768e"
    })
    // Paleta pra agentes criados pelo usuário (sem cor fixa conhecida) — cada
    // nome sempre cai na mesma cor (hash determinístico), sem colidir com as
    // cores acima.
    readonly property var _agentFallbackPalette: [
        "#bb9af7", "#9ece6a", "#ff9e64", "#2ac3de", "#c0caf5", "#ff007c"
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
}
