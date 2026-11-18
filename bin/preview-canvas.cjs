const { readFileSync } = require("node:fs");
const { createServer } = require("node:http");

const [sourcePath, runtimePath, compilerPath] = process.argv.slice(2);
const host = "127.0.0.1";
const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Canvas Preview</title>
</head>
<body>
  <main id="root"></main>
  <script type="module" src="/preview.mjs"></script>
</body>
</html>`;

function compile(ts) {
  const result = ts.transpileModule(readFileSync(sourcePath, "utf8"), {
    fileName: sourcePath,
    reportDiagnostics: true,
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.CommonJS,
      jsx: ts.JsxEmit.React,
      jsxFactory: "globalThis.React.createElement",
      jsxFragmentFactory: "globalThis.React.Fragment",
    },
  });
  const errors = result.diagnostics.filter(
    (diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error,
  );
  if (errors.length) {
    throw new Error(ts.flattenDiagnosticMessageText(errors[0].messageText, "\n"));
  }

  // mountCanvas installs React and the Cursor SDK on globalThis before import().
  return `const module = { exports: {} };
function loadCanvas(require, module, exports) {
${result.outputText}
}
loadCanvas((name) => {
  if (name === "cursor/canvas") return globalThis;
  throw new Error("Unsupported Canvas import: " + name);
}, module, module.exports);
export default module.exports.default;
`;
}

function start() {
  const ts = require(compilerPath);
  const runtime = readFileSync(runtimePath);
  const server = createServer((request, response) => {
    const origin = `${host}:${server.address().port}`;
    response.setHeader("Cache-Control", "no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader(
      "Content-Security-Policy",
      "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src data: blob:; base-uri 'none'; frame-ancestors 'none'",
    );
    if (request.headers.host !== origin || request.method !== "GET") {
      response.writeHead(403).end();
      return;
    }

    switch (request.url) {
      case "/":
        response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" }).end(html);
        break;
      case "/preview.mjs":
        response
          .writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" })
          .end('import { mountCanvas } from "/runtime.mjs";\nmountCanvas("/canvas.mjs");\n');
        break;
      case "/runtime.mjs":
        response.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" }).end(runtime);
        break;
      case "/canvas.mjs": {
        let module;
        try {
          module = compile(ts);
        } catch (error) {
          module = `throw new Error(${JSON.stringify(error.message)});\n`;
        }
        response.writeHead(200, { "Content-Type": "text/javascript; charset=utf-8" }).end(module);
        break;
      }
      default:
        response.writeHead(404).end();
    }
  });
  server.listen(0, host, () => console.log(`http://${host}:${server.address().port}/`));
}

try {
  start();
} catch (error) {
  console.error(`SimplePreview Canvas: ${error.message}`);
  process.exitCode = 1;
}
