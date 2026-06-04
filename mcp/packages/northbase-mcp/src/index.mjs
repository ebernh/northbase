#!/usr/bin/env node
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { getFile, putFile, listFiles, pullFiles, whoami, sessionStatus, listTodos, addTodo, toggleTodo, deleteTodo } from "northbase";

// ── tool definitions ──────────────────────────────────────────────────────────

const TOOLS = [
  {
    name: "northbase_get",
    description:
      "Get the content of a file stored in northbase by its path. " +
      "Uses a local cache at ~/.northbase/files/ and only fetches from the remote " +
      "when the cached copy is stale.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description:
            "Relative file path (e.g. 'ideas.md' or 'notes/todo.txt'). " +
            "Must not contain '..', '.', empty segments, or leading slashes.",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "northbase_put",
    description:
      "Write content to a file in northbase. Creates the file if it doesn't exist, " +
      "or overwrites it if it does. Updates the local cache after writing.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Relative file path (e.g. 'ideas.md' or 'notes/todo.txt').",
        },
        content: {
          type: "string",
          description: "The full text content to write to the file.",
        },
      },
      required: ["path", "content"],
    },
  },
  {
    name: "northbase_list",
    description:
      "List all file paths stored in northbase. Optionally filter to paths starting " +
      "with a given prefix. Returns one path per line.",
    inputSchema: {
      type: "object",
      properties: {
        prefix: {
          type: "string",
          description:
            "Optional path prefix to filter by (e.g. 'memory/' returns only paths " +
            "that start with 'memory/'). Omit to list all files.",
        },
      },
      required: [],
    },
  },
  {
    name: "northbase_pull",
    description:
      "Bulk-sync files from northbase to the local cache at ~/.northbase/files/. " +
      "Only downloads files whose remote updated_at differs from the cached value. " +
      "Useful before running northbase_get on many files. Never deletes local files.",
    inputSchema: {
      type: "object",
      properties: {
        prefix: {
          type: "string",
          description:
            "Optional path prefix to limit the sync (e.g. 'memory/'). Omit to sync everything.",
        },
      },
      required: [],
    },
  },
  {
    name: "northbase_whoami",
    description:
      "Return the email and user ID of the currently authenticated northbase user, " +
      "as read from ~/.northbase/session.json. Returns an error if not logged in.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "docket_list",
    description: "List all todos for the logged-in user. Returns id, title, completed status, and timestamps.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "docket_add",
    description: "Add a new todo for the logged-in user.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "The text of the todo item." },
      },
      required: ["title"],
    },
  },
  {
    name: "docket_toggle",
    description: "Toggle the completed state of a todo (true→false or false→true).",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "UUID of the todo to toggle." },
      },
      required: ["id"],
    },
  },
  {
    name: "docket_delete",
    description: "Permanently delete a todo by ID.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "UUID of the todo to delete." },
      },
      required: ["id"],
    },
  },
  {
    name: "northbase_session_status",
    description:
      "Return detailed session information: login status, email, token expiry time, " +
      "seconds remaining, and whether a refresh is imminent. Useful for diagnosing " +
      "auth issues without making a network call.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
];

// ── server setup ──────────────────────────────────────────────────────────────

const server = new Server(
  { name: "northbase-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case "northbase_get": {
        const content = await getFile(args.path);
        return { content: [{ type: "text", text: content }] };
      }

      case "northbase_put": {
        const result = await putFile(args.path, args.content);
        return {
          content: [
            {
              type: "text",
              text: `PUT ok ${args.path} bytes=${result.bytes} updated_at=${result.updated_at}`,
            },
          ],
        };
      }

      case "northbase_list": {
        const paths = await listFiles(args.prefix || undefined);
        return {
          content: [
            {
              type: "text",
              text: paths.length > 0 ? paths.join("\n") : "(no files found)",
            },
          ],
        };
      }

      case "northbase_pull": {
        const result = await pullFiles(args.prefix || undefined);
        return {
          content: [
            {
              type: "text",
              text: `PULL ok files=${result.total} downloaded=${result.downloaded} skipped=${result.skipped}`,
            },
          ],
        };
      }

      case "northbase_whoami": {
        const result = whoami();
        if (!result.loggedIn) {
          return {
            content: [{ type: "text", text: "Not logged in. Run `northbase login` in a terminal." }],
            isError: true,
          };
        }
        return {
          content: [
            { type: "text", text: `Logged in as ${result.email} (${result.id})` },
          ],
        };
      }

      case "northbase_session_status": {
        const s = sessionStatus();
        if (!s.loggedIn) {
          return {
            content: [{ type: "text", text: "Not logged in. Run `northbase login` in a terminal." }],
            isError: true,
          };
        }
        const lines = [
          `email=${s.email}`,
          `now=${s.nowSec}`,
          `expires_at=${s.expiresAt}`,
          `seconds_remaining=${s.secsRemaining}`,
          `will_refresh_soon=${s.willRefreshSoon}`,
        ];
        return { content: [{ type: "text", text: lines.join("\n") }] };
      }

      case "docket_list": {
        const todos = await listTodos();
        if (todos.length === 0) {
          return { content: [{ type: "text", text: "(no todos)" }] };
        }
        const lines = todos.map((t) =>
          `[${t.completed ? "x" : " "}] ${t.title}  (id=${t.id})`
        );
        return { content: [{ type: "text", text: lines.join("\n") }] };
      }

      case "docket_add": {
        const todo = await addTodo(args.title);
        return { content: [{ type: "text", text: `Added: "${todo.title}" (id=${todo.id})` }] };
      }

      case "docket_toggle": {
        const todo = await toggleTodo(args.id);
        return {
          content: [
            { type: "text", text: `Toggled id=${todo.id} → completed=${todo.completed}` },
          ],
        };
      }

      case "docket_delete": {
        const result = await deleteTodo(args.id);
        return { content: [{ type: "text", text: `Deleted id=${result.deleted}` }] };
      }

      default:
        return {
          content: [{ type: "text", text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }
  } catch (err) {
    return {
      content: [{ type: "text", text: `Error: ${err?.message ?? err}` }],
      isError: true,
    };
  }
});

// ── start ─────────────────────────────────────────────────────────────────────

const transport = new StdioServerTransport();
await server.connect(transport);
