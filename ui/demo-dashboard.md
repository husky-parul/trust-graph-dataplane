# Skill: Build a Single Pane Agent Ops Dashboard (Agents, Users, System View, Chat)

## Goal
Create one lightweight web UI that replaces curl workflows with a navigable single pane dashboard. The UI must support click based navigation across four views:

1. Render `:8080/agents` in the UI
2. Render `:8080/users` and show what each user can access
3. Show a system view of agents and resources running
4. Provide a chat interface that sends queries without curl and sets required headers automatically

The chat must use a different base URL from the rest of the dashboard so traces remain clean.

---

## Requirements:
- Message input with send button
- Conversation transcript in the same pane
- Must set headers automatically per request:
  - `x-caller-type: principal`
  - `trust.principal_id: user:<selected_user>` or the equivalent header used in your system
  - `trust.run_id` can be generated client-side per chat session, or obtained from response headers
  - Any additional headers required by the ingress gateway
 
 ---

## Layout
Single page app with a left nav and one main pane. No multi page routing required.

Left nav
- Agents
- Users
- System
- Chat

Top bar
- Base URL selector for core APIs (agents, users, system)
- Base URL selector for chat API
- Active principal selector used for header injection in chat requests

---

## Base URLs
- Core API base URL example: `http://localhost:8080`
- Chat API base URL example: `http://localhost:8090`

All non chat views use the core base URL.
Chat view uses the chat base URL only.

---

## A) Agents View
### Source
- **GET** `{core_base}/agents`

### UI
- Render as a searchable list or table
- Columns
  - agent id or name
  - description or capability summary if present
  - endpoint or service name if present
- Click a row to open an inline detail panel in the same pane
  - render the full JSON as a readable key value view
  - include copy JSON button

---



## B) Users View
### Source
- **GET** `{core_base}/users`

### UI
- Left side list of users
- Right side detail panel for selected user
- Show access summary as returned by the API
  - which resources
  - which agents
- Click an agent name to jump to that agent in Agents view
- Click a resource name to jump to that item in System view

---

## C) System View
This is not a graph. It is an ops system view that answers what is running.

### Source
Choose one based on what exists today.
- **GET** `{core_base}/system` or `{core_base}/topology` if that is what the service exposes

### UI
Render as a structured system inventory with sections:
- Agents running
- Resources connected
- Gateways or sidecars if present

For each item show
- name
- type
- status if present
- endpoint if present

Interactions
- Click an agent to jump to Agents view
- Click a resource to open a detail panel showing all available fields

---

## D) Chat View
Chat is used to send queries without curl and inject required headers.

### Source
- **POST** `{chat_base}/chat` or the existing entry agent endpoint used for interactive queries

### UI
- Transcript panel
- Message composer
- Clear conversation button

Request behavior
- Each send issues one HTTP request to the chat base URL
- The UI must set required headers for every message
  - `x-caller-type: principal`
  - `trust.principal_id` or the equivalent principal header used by the system
  - `trust.run_id` if required by your gateway contract, otherwise omit
  - any additional headers required by your ingress layer

Response behavior
- Render the assistant response text
- Optionally show raw JSON in a collapsible section for debugging

---

## Navigation Rules
- All navigation stays within one pane
- Left nav switches views without reload
- Cross links
  - From Users view, clicking an agent jumps to Agents view
  - From Users view, clicking a resource jumps to System view
  - From System view, clicking an agent jumps to Agents view

---

## Acceptance Checks
1. Agents view renders `{core_base}/agents` and supports click to view details
2. Users view renders `{core_base}/users` and shows per user access to agents and resources
3. System view shows what agents and resources are running as a structured inventory, not a graph
4. Chat view sends messages to `{chat_base}` and injects required headers correctly
5. All views are navigable by clicks in a single pane UI
