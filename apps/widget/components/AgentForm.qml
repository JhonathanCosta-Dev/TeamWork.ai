pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Formulário de criação/edição de agente.
// Em edição, `agent` vem preenchido; em criação, é null.
Rectangle {
    id: root

    property var store
    property var agent: null // null = novo agente
    signal closed()

    readonly property bool editing: agent !== null
    property string selectedAvatar: agent ? (agent.avatar ?? "") : "atlas.svg"
    property string errorText: ""

    radius: Theme.radiusSmall
    color: Theme.surfaceAlt
    border.width: 1
    border.color: Theme.accent
    implicitHeight: form.implicitHeight + Theme.padding * 2

    Column {
        id: form
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.padding
        anchors.rightMargin: Theme.padding
        spacing: Theme.spacing

        Text {
            text: root.editing ? "Editar agente" : "Novo agente"
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSize
            font.bold: true
        }

        FormField {
            id: nameField
            width: parent.width
            label: "Nome"
            placeholder: "ex.: Nova"
            text: root.agent ? root.agent.name : ""
        }

        FormField {
            id: roleField
            width: parent.width
            label: "Função"
            placeholder: "ex.: Redatora"
            text: root.agent ? root.agent.role : ""
        }

        FormField {
            id: promptField
            width: parent.width
            label: "Prompt de sistema"
            placeholder: "Você é…"
            multiline: true
            text: root.agent ? (root.agent.system_prompt ?? "") : ""
        }

        Text {
            text: "Avatar padrão:"
            color: Theme.textSecondary
            font.pixelSize: Theme.fontSizeSmall
            font.family: Theme.fontFamily
        }

        Row {
            spacing: 6
            Repeater {
                model: ["atlas.svg", "forge.svg", "iris.svg", "sentinel.svg"]
                delegate: Rectangle {
                    id: avatarChip
                    required property var modelData
                    width: 36
                    height: 36
                    radius: 18
                    color: "transparent"
                    border.width: 2
                    border.color: root.selectedAvatar === avatarChip.modelData
                                  ? Theme.accent : Theme.border
                    Image {
                        anchors.centerIn: parent
                        width: 30
                        height: 30
                        source: Qt.resolvedUrl("../assets/avatars/" + avatarChip.modelData)
                        sourceSize.width: width
                        sourceSize.height: height
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.selectedAvatar = avatarChip.modelData;
                            customAvatarField.text = "";
                        }
                    }
                }
            }
        }

        FormField {
            id: customAvatarField
            width: parent.width
            label: "Ou imagem personalizada (caminho completo do arquivo)"
            placeholder: "ex.: /home/voce/Imagens/avatar.png"
            text: root.agent && (root.agent.avatar ?? "").startsWith("/")
                  ? root.agent.avatar : ""
        }

        Text {
            visible: root.errorText.length > 0
            width: parent.width
            text: root.errorText
            color: Theme.danger
            font.pixelSize: Theme.fontSizeSmall
            font.family: Theme.fontFamily
            wrapMode: Text.WordWrap
        }

        Row {
            spacing: 6

            Rectangle {
                width: saveText.implicitWidth + 24
                height: 28
                radius: 14
                color: Qt.alpha(Theme.accent, 0.25)
                border.width: 1
                border.color: Theme.accent
                Text {
                    id: saveText
                    anchors.centerIn: parent
                    text: root.editing ? "Salvar" : "Criar agente"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.submit()
                }
            }

            Rectangle {
                width: cancelText.implicitWidth + 24
                height: 28
                radius: 14
                color: "transparent"
                border.width: 1
                border.color: Theme.border
                Text {
                    id: cancelText
                    anchors.centerIn: parent
                    text: "Cancelar"
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.closed()
                }
            }
        }
    }

    function submit() {
        const name = nameField.text.trim();
        const role = roleField.text.trim();
        if (name.length === 0 || role.length === 0) {
            root.errorText = "Nome e função são obrigatórios.";
            return;
        }
        const customPath = customAvatarField.text.trim();
        if (customPath.length > 0 && !customPath.startsWith("/")) {
            root.errorText = "O caminho da imagem deve ser completo (começar com /).";
            return;
        }
        const avatar = customPath.length > 0 ? customPath : root.selectedAvatar;
        root.errorText = "";
        const done = function (r, err) {
            if (err) {
                root.errorText = err.message;
            } else {
                root.closed();
            }
        };
        if (root.editing) {
            root.store.backend.call("agent.update", {
                agent_id: root.agent.id,
                name: name,
                role: role,
                system_prompt: promptField.text,
                avatar: avatar
            }, done);
        } else {
            root.store.backend.call("agent.create", {
                name: name,
                role: role,
                system_prompt: promptField.text,
                avatar: avatar
            }, done);
        }
    }
}
