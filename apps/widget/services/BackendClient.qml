import QtQuick
import Quickshell
import Quickshell.Io

// Cliente do daemon: NDJSON sobre Unix socket, com reconexão automática.
// Nenhuma lógica de negócio aqui — apenas transporte.
Item {
    id: root

    readonly property bool connected: socket.connected
    property string socketPath: {
        const dir = Quickshell.env("XDG_RUNTIME_DIR");
        return (dir && dir.length > 0 ? dir : "/tmp") + "/teamwork-ai/teamwork-ai.sock";
    }

    signal eventReceived(var event)

    property var _pending: ({})
    property int _seq: 0

    // Chama um método RPC; cb(result, error) é opcional.
    function call(method, params, cb) {
        if (!socket.connected) {
            if (cb)
                cb(null, { code: -1, message: "daemon offline" });
            return;
        }
        _seq += 1;
        const id = "w-" + _seq + "-" + Date.now();
        if (cb)
            _pending[id] = cb;
        socket.write(JSON.stringify({
            version: 1,
            id: id,
            method: method,
            params: params ?? {}
        }) + "\n");
    }

    function _handleLine(line) {
        if (!line || line.length === 0)
            return;
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            console.warn("linha inválida do daemon:", line.substring(0, 120));
            return;
        }
        if (msg.event !== undefined) {
            root.eventReceived(msg);
        } else if (msg.id !== undefined) {
            const cb = _pending[msg.id];
            if (cb) {
                delete _pending[msg.id];
                cb(msg.result ?? null, msg.error ?? null);
            }
        }
    }

    Socket {
        id: socket
        path: root.socketPath
        connected: true
        parser: SplitParser {
            onRead: message => root._handleLine(message)
        }
    }

    // Reconexão sem polling agressivo.
    Timer {
        interval: 3000
        repeat: true
        running: !socket.connected
        onTriggered: socket.connected = true
    }
}
