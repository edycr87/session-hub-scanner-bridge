const { EventEmitter } = require("events");
// The port list is dynamic: it starts from FAKE_SERIAL_PORTS and a test can
// change it while the bridge runs, to simulate a reader that appears, goes away
// or comes back on another COM number (keyboard HID -> serial VCOM).
//   { op: "ports", ports: [...] }   replace the whole list
//   { op: "add", port: {...} }      add (or replace by path) one port
//   { op: "remove", path: "COM3" }  remove one port (it stays open if it was)
//   { op: "data", port, data }      bytes from an open port
//   { op: "close", port }           the open port reports "close"
let ports = JSON.parse(process.env.FAKE_SERIAL_PORTS || "[]");
const instances = new Map();
class SerialPort extends EventEmitter {
  constructor(options, fallback) {
    super();
    this.path = typeof options === "string" ? options : options.path;
    instances.set(this.path, this);
  }
  open(callback) {
    setImmediate(() => {
      this.emit("open");
      if (callback) callback();
    });
  }
  close(callback) {
    setImmediate(() => {
      this.emit("close");
      if (callback) callback();
    });
  }
  static list() {
    return Promise.resolve(ports.map((port) => ({ ...port })));
  }
}
process.on("message", (message) => {
  if (!message || !message.op) return;
  if (message.op === "ports") {
    ports = Array.isArray(message.ports) ? message.ports : [];
    return;
  }
  if (message.op === "add") {
    ports = ports.filter((port) => port.path !== message.port.path);
    ports.push(message.port);
    return;
  }
  if (message.op === "remove") {
    ports = ports.filter((port) => port.path !== message.path);
    return;
  }
  const port = instances.get(message.port);
  if (!port) return;
  if (message.op === "data") port.emit("data", Buffer.from(message.data));
  if (message.op === "close") port.emit("close");
});
module.exports = { SerialPort, list: SerialPort.list };
