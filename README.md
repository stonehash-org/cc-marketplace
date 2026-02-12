# cc-mkp

Custom Claude Code plugins marketplace.

## Installation

```bash
/plugin marketplace add jaybee-sths/cc-mkp
```

## Available Plugins

| Plugin | Description |
|--------|-------------|
| **clickup** | ClickUp task management via MCP |

## Plugin Setup

### ClickUp

Requires a ClickUp Personal API Token:

1. Go to ClickUp Settings > Apps > API Token
2. Set environment variable: `export CLICKUP_API_KEY=pk_YOUR_TOKEN`
3. Install the plugin: `/plugin install clickup@cc-mkp`

## Adding New Plugins

1. Create a directory under `plugins/your-plugin/`
2. Add `.claude-plugin/plugin.json` manifest
3. Add skills, commands, agents, hooks as needed
4. Register in `.claude-plugin/marketplace.json`
