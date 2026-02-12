# ClickUp MCP Reference

Detailed patterns for community MCP backends (e.g., taazkareem/clickup-mcp-server).

## Authentication

Community MCP servers typically use a **Personal API Token**:

1. Go to ClickUp Settings -> Apps -> API Token
2. Generate or copy your token (starts with `pk_`)
3. Set as `CLICKUP_API_KEY` environment variable in MCP config

## Hierarchy Navigation

Always navigate the hierarchy before operating on tasks:

```
Step 1: Get workspaces
  -> get_workspaces
  -> Returns: workspace IDs and names

Step 2: Get spaces in workspace
  -> get_spaces(workspace_id)
  -> Returns: space IDs and names

Step 3: Get folders/lists in space
  -> get_folders(space_id)        # folders within space
  -> get_folderless_lists(space_id)  # lists directly in space
  -> get_lists(folder_id)         # lists within a folder

Step 4: Operate on tasks in a list
  -> get_tasks(list_id)
  -> create_task(list_id, ...)
```

## Task Operations

### Get Task

```
Tool: get_task
Parameters:
  - task_id: string (required)
  - include_subtasks: boolean (optional)

Returns: Full task details including:
  - id, name, description, status
  - assignees, watchers, priority
  - due_date, start_date, time_estimate
  - list, folder, space info
  - custom_fields, tags
  - parent (if subtask)
```

### Search Tasks

```
Tool: search_tasks
Parameters:
  - workspace_id: string (required)
  - query: string (search by name)
  - assignees: string[] (filter by assignee IDs)
  - statuses: string[] (filter by status names)
  - list_ids: string[] (filter by lists)
  - space_ids: string[] (filter by spaces)
  - folder_ids: string[] (filter by folders)
  - date_created_gt: number (Unix ms timestamp)
  - date_created_lt: number (Unix ms timestamp)
  - date_updated_gt: number (Unix ms timestamp)
  - date_updated_lt: number (Unix ms timestamp)
  - due_date_gt: number (Unix ms timestamp)
  - due_date_lt: number (Unix ms timestamp)
  - include_closed: boolean (default: false)
  - page: number (pagination, starts at 0)
```

### Create Task

```
Tool: create_task
Parameters:
  - list_id: string (required)
  - name: string (required)
  - description: string (optional, supports markdown)
  - assignees: string[] (member IDs, not names)
  - priority: number (1=urgent, 2=high, 3=normal, 4=low)
  - due_date: number (Unix ms timestamp)
  - start_date: number (Unix ms timestamp)
  - time_estimate: number (milliseconds)
  - status: string (must match list's custom statuses)
  - tags: string[] (tag names)
  - parent: string (parent task ID for subtasks)
  - notify_all: boolean (notify assignees, default: true)
```

### Update Task

```
Tool: update_task
Parameters:
  - task_id: string (required)
  - name: string (optional)
  - description: string (optional)
  - status: string (optional, must match list's statuses)
  - priority: number (optional)
  - assignees_add: string[] (member IDs to add)
  - assignees_remove: string[] (member IDs to remove)
  - due_date: number (optional, Unix ms timestamp)
  - start_date: number (optional, Unix ms timestamp)
  - time_estimate: number (optional, milliseconds)
  - archived: boolean (optional)
```

### Delete Task

```
Tool: delete_task
Parameters:
  - task_id: string (required)

WARNING: Permanent deletion. Always confirm with user first.
Prefer updating status to "Closed" or archiving instead.
```

## Status Management

ClickUp statuses are **custom per list**. Never hardcode status names.

### Get Available Statuses

```
Tool: get_list_statuses  (or get_list -> extract statuses)
Parameters:
  - list_id: string (required)

Returns: Array of status objects
  - status: string (name)
  - type: string ("open", "closed", "custom")
  - orderindex: number
  - color: string (hex)
```

### Common Status Patterns

While statuses are custom, common patterns include:

```
Simple:     "to do" -> "in progress" -> "done"
Kanban:     "backlog" -> "to do" -> "in progress" -> "review" -> "done"
Scrum:      "backlog" -> "sprint" -> "in progress" -> "qa" -> "done"
```

Always verify with `get_list_statuses` before transitioning.

## Comments

### Add Comment

```
Tool: create_task_comment
Parameters:
  - task_id: string (required)
  - comment_text: string (required, supports markdown)
  - notify_all: boolean (optional, default: false)
  - assignee: string (optional, member ID to mention)
```

### Get Comments

```
Tool: get_task_comments
Parameters:
  - task_id: string (required)
  - start: number (optional, pagination)
  - start_id: string (optional, comment ID to start from)
```

## Members and Assignment

### Get Workspace Members

```
Tool: get_workspace_members  (or get_list_members)
Parameters:
  - workspace_id: string (or list_id)

Returns: Array of member objects
  - id: number (use this for assignment)
  - username: string
  - email: string
  - role: number
```

**IMPORTANT**: Always use member IDs (numbers) for assignment, never display names.

### Assignment Pattern

```
1. Get members: get_list_members(list_id)
2. Find target member by name/email
3. Use member ID for assignment
4. update_task(task_id, assignees_add: [member_id])
```

## Custom Fields

### Get Custom Fields

```
Tool: get_custom_fields  (or get_accessible_custom_fields)
Parameters:
  - list_id: string (required)

Returns: Array of custom field definitions
  - id: string (field ID)
  - name: string (display name)
  - type: string ("text", "number", "dropdown", "date", "checkbox", etc.)
  - type_config: object (options for dropdown, etc.)
```

### Set Custom Field Value

```
Tool: set_custom_field_value
Parameters:
  - task_id: string (required)
  - field_id: string (required, from get_custom_fields)
  - value: any (type depends on field type)

Value formats by type:
  - text: "string value"
  - number: 42
  - checkbox: true/false
  - dropdown: "option_id" (from type_config.options)
  - date: Unix ms timestamp
  - currency: 99.99
  - labels: ["label_id1", "label_id2"]
```

## Time Tracking

### Start Timer

```
Tool: start_time_entry  (or start_timer)
Parameters:
  - task_id: string (required)
  - description: string (optional)
```

### Stop Timer

```
Tool: stop_time_entry  (or stop_timer)
Parameters:
  - workspace_id: string (required)
```

### Log Time Entry

```
Tool: create_time_entry
Parameters:
  - workspace_id: string (required)
  - task_id: string (required)
  - start: number (Unix ms timestamp)
  - duration: number (milliseconds)
  - description: string (optional)
```

## Dependencies and Links

### Add Dependency

```
Tool: add_task_dependency
Parameters:
  - task_id: string (required)
  - depends_on: string (task ID that must complete first)
  - dependency_of: string (task ID that depends on this)

Use ONE of depends_on or dependency_of, not both.
```

### Add Task Link

```
Tool: add_task_link
Parameters:
  - task_id: string (required)
  - links_to: string (target task ID)
```

## Error Handling

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| 401 Unauthorized | Invalid or expired API token | Regenerate token in ClickUp settings |
| 403 Forbidden | Insufficient permissions | Check workspace/space access |
| 404 Not Found | Invalid ID or deleted resource | Verify ID, check trash |
| 429 Rate Limited | Too many requests | Wait and retry (100 requests/min) |
| 500 Server Error | ClickUp API issue | Retry after a moment |

### Rate Limits

ClickUp API has a rate limit of **100 requests per minute** per token.
For bulk operations, add delays between requests.

## Workspace Discovery Pattern

When user doesn't specify where to create/find tasks:

```
1. get_workspaces -> list all workspaces
2. If single workspace: use it
3. If multiple: ask user which one
4. get_spaces(workspace_id) -> list spaces
5. Ask user to specify space, or search across spaces
6. Navigate to list level before creating tasks
```

## Sprint / Iteration Pattern

ClickUp doesn't have built-in sprints like Jira. Sprints are typically:

1. **Sprint Lists**: Separate lists named "Sprint 1", "Sprint 2", etc.
2. **Sprint Folders**: Folders containing sprint-related lists
3. **Due Date Ranges**: Tasks with due dates within sprint window
4. **Custom Fields**: A "Sprint" dropdown custom field on tasks

Ask the user how their team manages sprints before searching.
