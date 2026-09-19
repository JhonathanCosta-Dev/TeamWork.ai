import QtQuick
import Quickshell
import Quickshell.Io

// Descobre em qual tela você está trabalhando, para os avisos de gesto e o
// espelho da mão aparecerem ali em vez de numa tela que você não está olhando.
//
// A fonte é `niri msg focused-output`, a noção do PRÓPRIO compositor de tela
// ativa. Não existe, no Wayland, como um cliente comum perguntar onde está o
// ponteiro — não há API para isso, de propósito. O que dá para saber é qual
// saída o compositor considera focada, e ela acompanha o mouse de verdade se
// `focus-follows-mouse` estiver ligado na config do niri. Sem isso, segue a
// janela em que você está, que na prática é a mesma tela quase sempre.
//
// Só consulta enquanto `active`: fora disso não roda processo nenhum. O aviso
// fica segundos na tela de cada vez, e uma consulta em laço permanente
// custaria mais CPU do que tudo o que ela serve.
Item {
    id: root

    // Ligue só enquanto o resultado for usado. Desligado, não custa nada.
    property bool active: false
    // Nome da saída focada ("DP-2"), ou "" enquanto não se sabe.
    property string name: ""

    onActiveChanged: {
        if (root.active)
            root._consultar();
        else
            consulta.running = false;
    }

    function _consultar() {
        // Reatribuir `running` num Process que já roda não o reinicia, e uma
        // consulta presa deixaria a tela errada para sempre.
        if (!consulta.running)
            consulta.running = true;
    }

    Process {
        id: consulta
        running: false
        command: ["niri", "msg", "--json", "focused-output"]
        stdout: SplitParser {
            onRead: message => {
                try {
                    const saida = JSON.parse(message);
                    if (saida && saida.name)
                        root.name = saida.name;
                } catch (e) {
                    // Sem niri, ou saída inesperada: fica com o que tinha, e
                    // quem consome cai no monitor padrão.
                }
            }
        }
    }

    // Reconsulta enquanto o aviso está na tela, para acompanhar quem troca de
    // tela no meio do gesto. 1,5 s é devagar o bastante para não pesar e
    // rápido o bastante para não parecer travado.
    Timer {
        interval: 1500
        repeat: true
        running: root.active
        onTriggered: root._consultar()
    }
}
