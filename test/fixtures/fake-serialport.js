const { EventEmitter } = require("events");
const ports = JSON.parse(process.env.FAKE_SERIAL_PORTS || "[]");
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
    return Promise.resolve(ports);
  }
}
process.on("message", (message) => {
  if (!message || !message.op) return;
  const port = instances.get(message.port);
  if (!port) return;
  if (message.op === "data") port.emit("data", Buffer.from(message.data));
  if (message.op === "close") port.emit("close");
});
module.exports = { SerialPort, list: SerialPort.list };
