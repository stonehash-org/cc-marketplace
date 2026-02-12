---
name: clickup
description: Use when the user mentions ClickUp tasks, asks about tasks/lists/spaces, wants to create/view/update tasks, check sprint or workspace status, or manage their ClickUp workflow. Triggers on keywords like "clickup", "task", "list", "space", "folder", "sprint", "backlog", or task ID patterns (e.g., "#abc123").
---

# ClickUp

Natural language interaction with ClickUp. Supports multiple MCP backends.

## Backend Detection

**Run this check first** to determine which backend to use:

```
1. Check for Official ClickUp MCP:
   -> Look for mcp__clickup__* tools
   -> If available: USE OFFICIAL MCP BACKEND

2. If no official MCP, check for Community MCP:
   -> Look for mcp__clickup-mcp-server__* or similar tools
   -> If available: USE COMMUNITY MCP BACKEND

3. If neither available:
   -> GUIDE USER TO SETUP
```

| Backend | When to Use | Reference |
|---------|-------------|-----------|
| **Official MCP** | `mcp__clickup__*` tools available | See Quick Reference below |
| **Community MCP** | `mcp__clickup-mcp-server__*` tools available | `references/mcp.md` |
| **None** | Neither available | Guide to install MCP |

---

## Quick Reference (Official MCP)

> The official ClickUp MCP server (mcp.clickup.com) uses OAuth and provides these capabilities.

| Intent | Tool / Approach |
|--------|-----------------|
| Search tasks | Search with natural language query |
| View task | Get task by task ID |
| Create task | Create task in a specific list |
| Update task | Update task fields (name, description, status, priority, assignees) |
| Add comment | Add comment to a task |
| Get spaces | List spaces in workspace |
| Get folders | List folders in a space |
| Get lists | List lists in a space or folder |
| Get members | List workspace members |
| Time tracking | Start/stop timer, log time entries |

---

## Quick Reference (Community MCP)

> Community MCP servers (e.g., taazkareem/clickup-mcp-server) typically use Personal API Token.

| Intent | Typical Tool Name |
|--------|------------------|
| List workspaces | `get_workspaces` |
| List spaces | `get_spaces` |
| List folders | `get_folders` |
| List lists | `get_lists` / `get_folderless_lists` |
| Get task | `get_task` |
| Search tasks | `search_tasks` |
| Create task | `create_task` |
| Update task | `update_task` |
| Delete task | `delete_task` |
| Add comment | `create_task_comment` |
| Get comments | `get_task_comments` |
| Get members | `get_list_members` |
| Create list | `create_list` |
| Create folder | `create_folder` |
| Move task | `move_task` |
| Get statuses | `get_list_statuses` (custom statuses per list) |
| Bulk update | `bulk_update_tasks` |

See `references/mcp.md` for full community MCP patterns.

---

## Triggers

- "create a clickup task"
- "show me task #abc123"
- "list my tasks"
- "move task to done"
- "what's in the current sprint"
- "show tasks in the backlog list"
- "add a comment to the task"

---

## Task ID Detection

ClickUp task IDs are alphanumeric strings (e.g., `abc123`, `9hx`). They may appear:
- With a `#` prefix: `#abc123`
- As a URL: `https://app.clickup.com/t/abc123`
- As a custom task ID if enabled: `PROJ-123` (project-specific prefix)

When a user mentions a task ID:
- Fetch the task details first
- Display: name, status, assignees, priority, list, due date

---

## ClickUp Hierarchy

Understanding ClickUp's hierarchy is critical:

```
Workspace (Team)
  -> Space
    -> Folder (optional)
      -> List
        -> Task
          -> Subtask
          -> Checklist
```

- **Workspace**: Top-level organization (like a Jira instance)
- **Space**: Major area of work (like a Jira project)
- **Folder**: Optional grouping within a space
- **List**: Container for tasks (like a Jira board/sprint)
- **Task**: Individual work item (like a Jira issue)

---

## Workflow

**Creating tasks:**
1. Research context if user references code/tasks/PRs
2. Determine target list (ask user if ambiguous)
3. Draft task content (name, description, priority, assignees)
4. Review with user
5. Create using appropriate backend

**Updating tasks:**
1. Fetch task details first
2. Check current status and assignees
3. Show current vs proposed changes
4. Get approval before updating
5. Add comment explaining changes if significant

**Moving tasks (status changes):**
1. Fetch task to get current status
2. Get available statuses for the task's list (`get_list_statuses`)
3. ClickUp statuses are **custom per list** - never assume status names
4. Show available statuses and confirm target
5. Update the task status

---

## Before Any Operation

Ask yourself:

1. **What's the current state?** -- Always fetch the task first. Don't assume status, assignee, or fields.

2. **Which list/space?** -- ClickUp tasks live in lists. If the user doesn't specify, ask or search.

3. **What are the valid statuses?** -- Statuses are custom per list. Always fetch available statuses before transitioning.

4. **Who else is affected?** -- Check watchers, linked tasks, parent tasks. Updates may notify people.

5. **Is this reversible?** -- Task deletion is permanent (not just archived). Description edits have no built-in undo.

---

## NEVER

- **NEVER change status without fetching available statuses** -- ClickUp statuses are custom per list. "Done", "Complete", "Closed" vary by list configuration. Always get list statuses first.

- **NEVER assume workspace/space/list hierarchy** -- Always navigate the hierarchy: workspace -> space -> folder/list. Don't guess IDs.

- **NEVER edit description without showing original** -- ClickUp has no built-in undo for descriptions. User must see what they're replacing.

- **NEVER delete tasks without explicit approval** -- Task deletion is permanent in ClickUp. Prefer closing/archiving over deletion.

- **NEVER bulk-modify without explicit approval** -- Each task update may notify watchers. 10 updates = 10 notification storms.

- **NEVER assume custom field names or types** -- Custom fields vary by space. Always fetch available custom fields first.

---

## Priority Mapping

ClickUp uses numeric priorities:

| Priority | Value | Color |
|----------|-------|-------|
| Urgent | 1 | Red |
| High | 2 | Orange |
| Normal | 3 | Yellow |
| Low | 4 | Blue |
| No Priority | null | Grey |

---

## Safety

- Always show the tool call details before running it
- Always get approval before modifying tasks
- Preserve original information when editing descriptions
- Verify updates after applying
- Always surface authentication issues clearly so the user can resolve them

---

## No Backend Available

If no MCP backend is available, guide the user:

```
To use ClickUp, you need one of:

1. **Official ClickUp MCP** (recommended):
   Add to your MCP config (~/.claude/.mcp.json or project .mcp.json):

   {
     "mcpServers": {
       "clickup": {
         "command": "npx",
         "args": ["-y", "mcp-remote", "https://mcp.clickup.com/mcp"]
       }
     }
   }

   Uses OAuth - will prompt for authentication on first use.

2. **Community MCP** (taazkareem/clickup-mcp-server):
   Requires a ClickUp Personal API Token.

   {
     "mcpServers": {
       "clickup": {
         "command": "npx",
         "args": ["-y", "@taazkareem/clickup-mcp-server"],
         "env": {
           "CLICKUP_API_KEY": "pk_YOUR_API_TOKEN"
         }
       }
     }
   }

   Get your token: ClickUp Settings -> Apps -> API Token
```

---

## Deep Dive

**LOAD reference when:**
- Working with community MCP tool patterns in detail
- Troubleshooting errors or authentication issues
- Using advanced features like custom fields, time tracking, or dependencies
- Building complex search queries or filters

**Do NOT load reference for:**
- Simple view/list operations (Quick Reference above is sufficient)
- Basic task creation with name only
- Checking task status

| Task | Load Reference? |
|------|-----------------|
| View single task | No |
| List my tasks | No |
| Create with custom fields | **Yes** -- need field IDs |
| Search with complex filters | **Yes** -- for query patterns |
| Time tracking operations | **Yes** -- for timer/entry tools |
| Bulk operations | **Yes** -- safety patterns |

References:
- Community MCP patterns: `references/mcp.md`
