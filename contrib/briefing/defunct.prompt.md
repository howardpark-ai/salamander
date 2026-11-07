Produce {{OWNER}}'s forwarded-address unsubscribe queue (safe mode, READ ONLY).

Use only the Google Workspace "{{CONNECTOR}}" connector tools (`mcp__claude_ai_Google_Workspace_{{CONNECTOR}}__search_gmail_messages`, `get_gmail_message_content`, `get_gmail_messages_content_batch`, and the thread equivalents). They are already connected; do not look for other Gmail paths, do not call any resource-listing tools, and do not use any other connector, except the portal route in the next paragraph.
If those `mcp__claude_ai_Google_Workspace_{{CONNECTOR}}__*` tools are not in your tool list, read the same mailbox through {{OWNER}}'s MCP Portal instead, with `mcp__mcp-portal__portal_codemode_execute` (if it is deferred, load it with ToolSearch `select:mcp__mcp-portal__portal_codemode_execute`). Its one argument, `code`, is a JavaScript async arrow function that awaits the portal's Google Workspace {{CONNECTOR}} Gmail reads and returns their results, for example `async () => await codemode.{{PORTAL}}_search_gmail_messages({ query: "is:unread", page_size: 50 })` or `async () => await codemode.{{PORTAL}}_get_gmail_threads_content_batch({ thread_ids: ["THREAD_ID_1", "THREAD_ID_2"] })`. The only portal tools you may call are these five reads: `codemode.{{PORTAL}}_search_gmail_messages({ query, page_size, page_token })` (its results give each message's Message ID and Thread ID), `codemode.{{PORTAL}}_get_gmail_message_content({ message_id })`, `codemode.{{PORTAL}}_get_gmail_messages_content_batch({ message_ids })` (at most 25), `codemode.{{PORTAL}}_get_gmail_thread_content({ thread_id })` and `codemode.{{PORTAL}}_get_gmail_threads_content_batch({ thread_ids })` (at most 25). Never call any other `codemode.*` tool: no send, draft, label, filter or modify tool, and no other server or mail account (not any other mail account, not the claude.ai Gmail connector). A few reads may go in one `code` with `Promise.all` (at most 4 run at once). On this route, "the {{CONNECTOR}} connector" below means these portal reads.
If a Gmail tool call returns HTTP 401/403 or an explicit OAuth/authorization error, reply exactly: `Google Workspace {{CONNECTOR}} connector needs re-authorization.`

Query Gmail through the {{CONNECTOR}} connector for unread mail with label `{{FORWARD_LABEL}}`: `is:unread label:"{{FORWARD_LABEL}}"`. Read enough metadata/content to classify the queue. This is SAFE MODE: do not unsubscribe, click, reply, modify labels, archive, delete, or take external action.

Classify each item into exactly one of: Needs review, High confidence unsubscribe, Do not touch. Consolidate duplicate-campaign senders. Drop obvious admin junk (automatic notices of the forwarding setup itself) entirely.

Format:
- Start with exactly: `*📭 Defunct Address Queue*`
- Second line, italic: `_As of YYYY-MM-DD HH:MM AM/PM ZONE · N items_` (ZONE is the zone name in the current local time line below).
- Sections in this order, each rendered as three lines — a blank line, then the rule `━━━━━━━━━━━━━━`, then the bold header — followed by one blank line before the first item: `*🟡 Needs review*`, `*🟢 High confidence unsubscribe*`, `*🔴 Do not touch*`. Empty section: `• none`.
- Item shape (three lines, items separated by one blank line, no leading dash):
  *NAME* — MM-DD HH:MM AM/PM
      • short reason for the classification
      • *Action:* concise recommended human decision
- Gmail marker (required on every item): end each item's bold title line with ` [gmail:THREAD_ID]`, where THREAD_ID is that item's Gmail thread id copied exactly from the tool results (the hex `Thread ID`; for a consolidated sender, its most recent thread); never guess or invent one. The shell turns it into an `open` link.
- No `- ` dashes, no numbered lists, no tables.
- Delivery is a Slack message: keep the whole text under 3500 characters. Use Slack mrkdwn — links as <URL|title>, bold as *text*; never use markdown [title](url) or **text**. Compress as needed; never split parent from child bullets.
- Write in English (keep proper nouns, sender names and subject lines in their original language).
- Return ONLY the formatted queue text. Do not send it anywhere yourself — the shell posts it. Do not start with any machine announcement line.
- ALWAYS deliver the queue, including when it is completely empty. If every section is empty, still emit the full formatted queue with `- None` under each of the three sections.
- NEVER return `NO_REPLY`, an empty reply, or any silent/suppression token, for any reason. Silence from this job is reserved for real failures, so a silent success would be indistinguishable from an outage.