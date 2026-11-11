import readline from "node:readline";

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");

send({ op: "hello", version: 1, pid: process.pid, node: process.version });

const input = readline.createInterface({ input: process.stdin });

input.on("line", (line) => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  const id = request.id;
  switch (request.op) {
    case "ping":
      send({ id, status: ["done"], value: "pong" });
      break;
    case "eval":
      if (String(request.code).includes("throw")) {
        send({
          id,
          status: ["eval-error", "done"],
          ex: { name: "Error", message: "boom", stack: "" },
        });
      } else if (String(request.code).includes("slow")) {
        // Deliberately do not answer, to test the client-side timeout.
      } else {
        send({ id, op: "out", out: "mock-out\n" });
        send({
          id,
          status: ["done"],
          value: `mock:${request.ns || "user"}:${request.code}`,
          ns: request.ns || "user",
        });
      }
      break;
    case "ns-list":
      send({ id, status: ["done"], namespaces: ["mock", "user"] });
      break;
    case "ns-vars":
      send({ id, status: ["done"], vars: ["x", "y"] });
      break;
    case "load-file":
      send({ id, status: ["done"], ns: request.ns || "user" });
      break;
    case "quit":
      send({ id, status: ["done"] });
      setTimeout(() => process.exit(0), 10);
      break;
    default:
      send({
        id,
        status: ["error", "done"],
        ex: { name: "Error", message: `unknown op: ${request.op}`, stack: "" },
      });
  }
});
