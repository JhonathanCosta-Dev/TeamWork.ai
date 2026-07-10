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
        text: "Tarefas"
        color: Theme.textPrimary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeLarge
        font.bold: true
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
        subtitle: "Use o terminal: @forge analise o projeto"
    }

    Text {
        text: "Linha do tempo"
        color: Theme.textPrimary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeLarge
        font.bold: true
    }

    TaskTimeline {
        width: root.width
        height: 180
        store: root.store
    }
}
