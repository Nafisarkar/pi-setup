/**
 * NTLite tools for pi.
 *
 * pi (0.87.x) has no MCP client, so the stdio server in src/server.mjs cannot
 * be attached to it directly. This extension closes that gap: it imports the
 * exact same tool definitions the MCP server serves and re-registers them as
 * native pi tools. There is one implementation of every tool, so the two front
 * ends can never drift apart.
 *
 * Install by copying this directory to ~/.pi/agent/extensions/ntlite/, or run
 * pi with:  pi --extension F:/dev/Win11CustomIso/mcp-ntlite/pi-extension/ntlite.ts
 *
 * Every tool that actually runs NTLite raises one UAC prompt, because NTLite
 * requires administrator rights. ntlite_status and ntlite_list_presets are
 * read-only and never do.
 */

import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";

import { Type } from "@earendil-works/pi-ai";
import { type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * Locate src/tools.mjs.
 *
 * The extension is normally installed away from the project, so a plain
 * relative import would break. NTLITE_MCP_SRC wins, then a walk up from this
 * file, then the known checkout location.
 */
function findToolsModule() {
  const candidates = [];
  if (process.env.NTLITE_MCP_SRC) candidates.push(process.env.NTLITE_MCP_SRC);

  let dir = HERE;
  for (let i = 0; i < 6; i += 1) {
    candidates.push(join(dir, "src", "tools.mjs")); // installed as a sibling of src/
    candidates.push(join(dir, "mcp-ntlite", "src", "tools.mjs")); // inside the project tree
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }

  candidates.push("F:/dev/Win11CustomIso/mcp-ntlite/src/tools.mjs");

  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return resolve(candidate);
  }
  return null;
}

/** Build a TypeBox schema from the neutral params list shared with the MCP server. */
function toTypeBox(param) {
  const opts = {};
  if (param.description) opts.description = param.description;
  if (param.default !== undefined) opts.default = param.default;

  let schema;
  if (param.type === "number") {
    schema = Type.Number(opts);
  } else if (param.type === "boolean") {
    schema = Type.Boolean(opts);
  } else if (param.type === "array") {
    if (param.items?.type === "object") {
      schema = Type.Array(
        Type.Object({
          name: Type.String({ description: "Switch name without the leading slash, e.g. Path" }),
          value: Type.Optional(Type.String({ description: "Value; omit for a bare flag." })),
          quote: Type.Optional(
            Type.Boolean({ description: "Quote the value; required when it contains spaces." }),
          ),
        }),
        opts,
      );
    } else if (param.items?.enum) {
      schema = Type.Array(Type.Union(param.items.enum.map((v) => Type.Literal(v))), opts);
    } else if (param.items?.type === "number") {
      schema = Type.Array(Type.Number(), opts);
    } else {
      schema = Type.Array(Type.String(), opts);
    }
  } else {
    schema = param.enum
      ? Type.Union(param.enum.map((v) => Type.Literal(v)), opts)
      : Type.String(opts);
  }

  return param.required ? schema : Type.Optional(schema);
}

export default async function (pi: ExtensionAPI) {
  const modulePath = findToolsModule();

  if (!modulePath) {
    pi.registerCommand("ntlite-setup", {
      description: "Show how to point the pi NTLite extension at mcp-ntlite",
      handler: async (_args, ctx) => {
        ctx.ui.notify(
          "mcp-ntlite/src/tools.mjs not found. Set NTLITE_MCP_SRC to the directory containing it.",
          "error",
        );
      },
    });
    log("could not find mcp-ntlite/src/tools.mjs; set NTLITE_MCP_SRC to its directory");
    return;
  }

  let mod;
  try {
    mod = await import(pathToFileURL(modulePath).href);
  } catch (error) {
    log(`failed to load tools from ${modulePath}: ${error.message}`);
    return;
  }

  const { TOOLS, callTool } = mod;

  for (const tool of TOOLS) {
    const properties = {};
    for (const param of tool.params) {
      properties[param.name] = toTypeBox(param);
    }

    pi.registerTool({
      name: tool.name,
      label: tool.label,
      description: tool.description,
      parameters: Type.Object(properties),
      async execute(_toolCallId, params) {
        // pi only marks a result as failed when execute() throws, so an
        // isError result from the shared handler is re-thrown here.
        const result = await callTool(tool.name, params ?? {});
        if (result.isError) throw new Error(result.text);
        return {
          content: [{ type: "text", text: result.text }],
          details: result.details ?? {},
        };
      },
    });
  }

  // Convenience command: the fastest way to see whether the install is sane.
  pi.registerCommand("ntlite-status", {
    description: "Show the NTLite install, edition and whether this session is elevated",
    handler: async (_args, ctx) => {
      const result = await callTool("ntlite_status", {});
      if (result.isError) {
        ctx.ui.notify(result.text, "error");
        return;
      }
      ctx.ui.notify(result.text.split("\n").slice(0, 8).join("\n"), "info");
    },
  });

  log(`ready: ${TOOLS.length} tools from ${modulePath}`);
}

/**
 * Boot diagnostics. Deliberately stderr-only: the factory can run before a
 * session exists, so no UI is guaranteed to be attached yet.
 */
function log(message) {
  process.stderr.write(`[ntlite] ${message}\n`);
}
