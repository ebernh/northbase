# Northbase

A personal notes and file management system with an AI-native interface. Northbase is an iOS app (SwiftUI, iOS 26) backed by Supabase, paired with an MCP server that lets Claude read and write your notes directly.

## Project Overview

Northbase has two components that live in this repo:

| Directory | What it is |
|-----------|------------|
| `ios/` | SwiftUI iPhone app — sign in, browse folders, read and edit Markdown notes with a Liquid Glass UI |
| `mcp/` | Node.js MCP server — exposes file and todo operations as tools so Claude can read and write your notes in real time |

The iOS app stores notes as plain text files in a Supabase `files` table, scoped to the authenticated user via Row Level Security. The MCP server authenticates as the same user and talks to the same table, so notes written by Claude appear in the app instantly.

---

## Setup

### Prerequisites

- Xcode 26 beta or later (iOS 26 SDK required for Liquid Glass APIs)
- Node.js >= 18
- A Supabase project with the schema below

### Supabase schema

```sql
create table public.files (
  path        text primary key,
  content     text not null default '',
  owner_id    uuid not null references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.files enable row level security;

create policy "owner access" on public.files
  for all using (owner_id = auth.uid());

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger files_updated_at
  before update on public.files
  for each row execute procedure public.set_updated_at();
```

### iOS app

1. Open `ios/MyBot.xcodeproj` in Xcode
2. Select your development team under **Signing & Capabilities**
3. Choose a simulator or connected iPhone and press **Run**

The Supabase URL and publishable anon key are hardcoded in `ios/MyBot/SupabaseClient.swift`. These are public client-side credentials — they are safe to commit.

### MCP server

```bash
cd mcp
npm install

# Log in with your Supabase account (same credentials as the iOS app)
npx northbase login
```

Your session is saved to `~/.northbase/session.json` and refreshed automatically. You only need to log in once.

---

## Usage

### iOS app

1. Sign up or log in with your email and password
2. Confirm your email if prompted
3. Browse your files and folders from the main list
4. Tap any file to open the editor; tap the compose button to create a new one
5. Pull down to refresh — changes made via Claude appear immediately

### MCP server with Claude Desktop

Add the following to your `claude_desktop_config.json` (usually at `~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "northbase": {
      "command": "node",
      "args": ["/absolute/path/to/northbase/mcp/packages/northbase-mcp/src/index.mjs"]
    }
  }
}
```

Restart Claude Desktop. You will then have access to these tools in any Claude conversation:

| Tool | Description |
|------|-------------|
| `northbase_get` | Read a file by path |
| `northbase_put` | Write or overwrite a file |
| `northbase_list` | List all files, with optional prefix filter |
| `northbase_pull` | Bulk-sync files to local cache |
| `northbase_whoami` | Show the authenticated user |
| `northbase_session_status` | Show session expiry details |

**Example:** Ask Claude to "write a summary of our conversation to notes/summary.md" — it will call `northbase_put` and the file appears in the iOS app.

---

## AI Usage Disclosure

This project was built with significant assistance from [Claude Code](https://claude.ai/code) (Anthropic). AI assistance was used for:

- SwiftUI view architecture and Liquid Glass API adoption
- Supabase integration in both Swift and Node.js
- MCP server design and tool implementation
- Debugging, refactoring, and code review throughout development

All AI-generated code was reviewed, tested, and integrated by the author. The overall system design, product decisions, and Supabase schema were authored by the developer.

---

## Acknowledgements

- [Supabase](https://supabase.com) — open source Firebase alternative; provides auth, database, and RLS
- [Anthropic / Claude](https://anthropic.com) — AI assistant used during development via Claude Code
- [Model Context Protocol (MCP)](https://modelcontextprotocol.io) — open protocol by Anthropic for connecting AI models to external tools and data sources
- [Supabase Swift SDK](https://github.com/supabase/supabase-swift) — official Swift client for Supabase
- [@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk) — official TypeScript/Node.js SDK for building MCP servers
- Apple SwiftUI and the iOS 26 Liquid Glass design system

---

## External Resources

- [Supabase docs](https://supabase.com/docs)
- [MCP specification](https://modelcontextprotocol.io/docs)
- [Supabase Swift SDK docs](https://supabase.com/docs/reference/swift/introduction)
- [Apple Human Interface Guidelines — iOS 26](https://developer.apple.com/design/human-interface-guidelines)
- [Claude Code](https://claude.ai/code)
