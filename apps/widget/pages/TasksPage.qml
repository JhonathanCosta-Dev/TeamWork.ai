pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

// Tarefas atuais + linha do tempo + resultados recentes.
Column {
    id: root

    property var store
    spacing: Theme.spacing

    Text {
        text: "TAREFAS"
        color: Theme.textDisabled
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeTiny
        font.bold: true
        font.letterSpacing: 1.4
    }

    Repeater {
        model: root.store.tasks.slice(0, 8)
        delegate: TaskProgress {
            required property var modelData
            width: root.width
            task: modelData
            store: root.store
        }
    }

    EmptyState {
        visible: root.store.tasks.length === 0
        width: root.width
        title: "Nenhuma tarefa ainda"
        subtitle: "Escreva no chat: @forge analise o projeto"
    }

    Text {
        text: "LINHA DO TEMPO"
        color: Theme.textDisabled
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeTiny
        font.bold: true
        font.letterSpacing: 1.4
    }

    TaskTimeline {
        width: root.width
        height: 180
        store: root.store
    }
}
