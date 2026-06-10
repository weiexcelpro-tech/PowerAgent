# ============================================================================
#  PowerAgent Test — Test Data Fixtures
#  Shared data used across multiple test files
# ============================================================================

# Sample messages for reuse
$script:TEST_MESSAGES = @(
    @{ role = "system"; content = "You are a helpful assistant." },
    @{ role = "user"; content = "Hello, how are you?" },
    @{ role = "assistant"; content = "I'm doing well, thank you for asking!" },
    @{ role = "user"; content = "What is the capital of France?" },
    @{ role = "assistant"; content = "The capital of France is Paris." }
)

# Sample agent definition
$script:TEST_AGENT_DEF = @"
name: test_agent
description: A unit test agent
model: test-model
---
You are a test agent. Respond concisely.
"@

# Sample settings JSON
$script:TEST_SETTINGS_JSON = @"
{
  "api_key": "test-api-key",
  "model": "test-model",
  "max_tokens": 4096,
  "mcp_servers": {
    "test_stdio": {
      "command": "npx",
      "args": ["-y", "@test/mcp-server"],
      "transport": "stdio"
    },
    "test_sse": {
      "url": "http://localhost:8080/mcp/sse",
      "transport": "sse"
    }
  }
}
"@

# Sample TODO items
$script:TEST_TODO_ITEMS = @(
    @{ title = "High priority task"; body = "Do this first"; priority = "high" },
    @{ title = "Medium priority task"; body = "Do this second"; priority = "medium" },
    @{ title = "Low priority task"; body = "Do this last"; priority = "low" }
)
