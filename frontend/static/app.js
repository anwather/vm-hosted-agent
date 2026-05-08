// SSE chat client for Task Orchestrator (caller-stack multi-agent routing).
//
// State model:
//   conversations: Map<agentName, history[]>   per-agent message history
//   callerStack: agentName[]                   stack of who called whom
//   activeAgent: agentName                     who the user is talking to
//
// UI model (Phase O):
//   Right pane = single "Agent activity" timeline. Each time setActiveAgent
//   transitions to a new agent, we close+collapse the previous card and
//   append a fresh card for the new active agent. Tool calls render as
//   collapsible <details> rows under the active card. Card status dot
//   rolls up its rows: any in_progress=>yellow, any error=>red, else green.

const messagesEl = document.getElementById("messages");
const activityEl = document.getElementById("activity");
const form = document.getElementById("chat-form");
const input = document.getElementById("message");
const sendBtn = document.getElementById("send");
const headerEl = document.querySelector("header");
const activeAgentDisplay = document.getElementById("active-agent-display");
const startOverBtn = document.getElementById("start-over");
const themeToggleBtn = document.getElementById("theme-toggle");

const ORCHESTRATOR = headerEl.dataset.orchestrator;
const AGENT_WINDOWS = headerEl.dataset.agentWindows;
const AGENT_LINUX = headerEl.dataset.agentLinux;
const AGENT_PRICING = headerEl.dataset.agentPricing;

// Short-label -> full agent name mapping. Markers carry short labels.
const AGENTS = {
  orchestrator: ORCHESTRATOR,
  windows: AGENT_WINDOWS,
  linux: AGENT_LINUX,
  pricing: AGENT_PRICING,
};

// Per-agent conversation history.
let conversations = new Map();
// Stack of agent names representing who delegated to whom.
let callerStack = [];
// Currently active agent name (default: orchestrator).
let activeAgent = ORCHESTRATOR;

// Per-turn state.
let pendingForward = null;
let pendingHandback = null;
let lastUserMessageForTurn = null;
let currentAssistantText = "";

// callId -> { rowEl, cardEl, toolName, status }
const toolCallIndex = new Map();
// Active agent card (the one new tool calls are appended to).
let activeAgentCard = null;
// "Thinking" placeholder bubble (visible while a turn is in flight).
let thinkingBubble = null;

function shortAgentLabel(name) {
  if (!name) return "agent";
  if (name === ORCHESTRATOR) return "orchestrator";
  if (name === AGENT_WINDOWS) return "windows agent";
  if (name === AGENT_LINUX) return "linux agent";
  if (name === AGENT_PRICING) return "pricing agent";
  return name;
}

function showThinking(label) {
  if (thinkingBubble) {
    const lab = thinkingBubble.querySelector(".label");
    if (lab) lab.textContent = label || `${shortAgentLabel(activeAgent)} is thinking…`;
    return;
  }
  const div = document.createElement("div");
  div.className = "bubble thinking";
  div.innerHTML =
    '<span class="dot"></span><span class="dot"></span><span class="dot"></span>' +
    `<span class="label">${label || shortAgentLabel(activeAgent) + " is thinking\u2026"}</span>`;
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  thinkingBubble = div;
}

function hideThinking() {
  if (thinkingBubble) {
    thinkingBubble.remove();
    thinkingBubble = null;
  }
}

const tokenTotalEl = document.getElementById("token-total");
const tokenInEl = document.getElementById("token-in");
const tokenOutEl = document.getElementById("token-out");
const sessionTokens = { input: 0, output: 0, total: 0, estimated: false };

function fmt(n) { return n.toLocaleString(); }

// ---------- Theme ----------

function applyTheme(theme) {
  document.documentElement.setAttribute("data-theme", theme);
  if (themeToggleBtn) themeToggleBtn.textContent = theme === "light" ? "☀️" : "🌙";
  try { localStorage.setItem("vmagent-theme", theme); } catch (e) { /* ignore */ }
}
function initTheme() {
  let saved = "dark";
  try { saved = localStorage.getItem("vmagent-theme") || "dark"; } catch (e) { /* ignore */ }
  applyTheme(saved);
}
if (themeToggleBtn) {
  themeToggleBtn.addEventListener("click", () => {
    const cur = document.documentElement.getAttribute("data-theme") || "dark";
    applyTheme(cur === "light" ? "dark" : "light");
  });
}
initTheme();

// ---------- Active agent / activity cards ----------

function createAgentCard(name) {
  const li = document.createElement("li");
  li.className = "agent-card status-yellow";
  li.dataset.agent = name;
  li.innerHTML = `
    <div class="agent-card-head">
      <span class="status-dot"></span>
      <span class="agent-name"></span>
      <span class="agent-tool-count">0 tools</span>
      <span class="caret">▾</span>
    </div>
    <div class="agent-card-body">
      <ul class="tool-rows"><li class="empty">waiting for tool calls…</li></ul>
    </div>`;
  li.querySelector(".agent-name").textContent = name;
  li.querySelector(".agent-card-head").addEventListener("click", () => {
    li.classList.toggle("collapsed");
  });
  activityEl.appendChild(li);
  activityEl.scrollTop = activityEl.scrollHeight;
  return li;
}

function setCardStatus(card, status) {
  if (!card) return;
  card.classList.remove("status-yellow", "status-green", "status-red");
  card.classList.add(`status-${status}`);
}

function rollupCardStatus(card) {
  if (!card) return;
  const rows = card.querySelectorAll(".tool-row");
  if (!rows.length) { setCardStatus(card, "yellow"); return; }
  let anyInProgress = false, anyError = false;
  rows.forEach(r => {
    if (r.classList.contains("status-yellow")) anyInProgress = true;
    if (r.classList.contains("status-red")) anyError = true;
  });
  if (anyError) setCardStatus(card, "red");
  else if (anyInProgress) setCardStatus(card, "yellow");
  else setCardStatus(card, "green");
}

function setActiveAgent(name) {
  // If switching to a different agent, finalise + collapse previous card.
  if (activeAgentCard && activeAgentCard.dataset.agent !== name) {
    // Roll up any leftover state on the previous card; if everything was
    // green/done, leave it green; otherwise mark green as the "card finished
    // its turn" signal (errors stay red; in-progress shouldn't really happen
    // by handoff time but if it does we mark green to avoid spinning).
    const prev = activeAgentCard;
    const hasErr = prev.querySelector(".tool-row.status-red");
    setCardStatus(prev, hasErr ? "red" : "green");
    prev.classList.add("collapsed");
    activeAgentCard = null;
  }
  activeAgent = name;
  activeAgentDisplay.textContent = name;
  // Always append a fresh card on transition (including initial set).
  if (!activeAgentCard) {
    activeAgentCard = createAgentCard(name);
  }
}

function getHistory(agent) {
  let h = conversations.get(agent);
  if (!h) { h = []; conversations.set(agent, h); }
  return h;
}

// ---------- Chat / dividers ----------

function appendBubble(role, text) {
  const div = document.createElement("div");
  div.className = `bubble ${role}`;
  div.textContent = text;
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return div;
}

function appendDivider(text) {
  const div = document.createElement("div");
  div.className = "chat-divider";
  const span = document.createElement("span");
  span.className = "divider-text";
  span.textContent = text;
  div.appendChild(span);
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return div;
}

function renderMarkdown(text) {
  if (!text) return "";
  if (typeof marked === "undefined" || typeof DOMPurify === "undefined") {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML.replace(/\n/g, "<br>");
  }
  marked.setOptions({ gfm: true, breaks: true });
  return DOMPurify.sanitize(marked.parse(text));
}

// ---------- Token usage ----------

function addUsage(usage) {
  if (!usage || typeof usage !== "object") return;
  const inp = Number(usage.input_tokens ?? usage.prompt_tokens ?? 0) || 0;
  const out = Number(usage.output_tokens ?? usage.completion_tokens ?? 0) || 0;
  const tot = Number(usage.total_tokens ?? (inp + out)) || 0;
  if (!inp && !out && !tot) return;
  sessionTokens.input += inp;
  sessionTokens.output += out;
  sessionTokens.total += tot;
  if (usage.estimated) sessionTokens.estimated = true;
  tokenInEl.textContent = fmt(sessionTokens.input);
  tokenOutEl.textContent = fmt(sessionTokens.output);
  tokenTotalEl.textContent = fmt(sessionTokens.total) + (sessionTokens.estimated ? "~" : "");
}

function findUsage(obj, depth = 0) {
  if (!obj || typeof obj !== "object" || depth > 4) return null;
  if (obj.usage && typeof obj.usage === "object" &&
      ("input_tokens" in obj.usage || "prompt_tokens" in obj.usage ||
       "output_tokens" in obj.usage || "total_tokens" in obj.usage)) {
    return obj.usage;
  }
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    if (v && typeof v === "object") {
      const found = findUsage(v, depth + 1);
      if (found) return found;
    }
  }
  return null;
}

const countedResponseIds = new Set();
function maybeCountUsage(data) {
  const id = data?.response?.id || data?.id;
  if (id && countedResponseIds.has(id)) return;
  const usage = findUsage(data);
  if (!usage) return;
  if (id) countedResponseIds.add(id);
  addUsage(usage);
}

// ---------- Tool rows ----------

function shortSummary(text, max = 60) {
  if (text === undefined || text === null) return "";
  let s = typeof text === "string" ? text : JSON.stringify(text);
  s = s.replace(/\s+/g, " ").trim();
  if (s.length > max) s = s.slice(0, max - 1) + "…";
  return s;
}

function ensureActiveCardForTool() {
  if (!activeAgentCard) {
    activeAgentCard = createAgentCard(activeAgent);
  }
  return activeAgentCard;
}

function appendToolCall(callId, name, args) {
  let entry = toolCallIndex.get(callId);
  if (!entry) {
    const card = ensureActiveCardForTool();
    const ul = card.querySelector(".tool-rows");
    const empty = ul.querySelector(".empty");
    if (empty) empty.remove();
    const row = document.createElement("details");
    row.className = "tool-row status-yellow";
    row.innerHTML = `
      <summary>
        <span class="status-dot"></span>
        <span class="tool-name"></span>
        <span class="tool-summary">running…</span>
        <span class="row-caret">▸</span>
      </summary>
      <div class="tool-detail">
        <span class="label">arguments</span>
        <pre class="tool-args"></pre>
        <span class="label result-label" hidden>result</span>
        <pre class="tool-result" hidden></pre>
      </div>`;
    row.querySelector(".tool-name").textContent = name || "(tool)";
    ul.appendChild(row);
    entry = { rowEl: row, cardEl: card, toolName: name || "(tool)", status: "in_progress" };
    toolCallIndex.set(callId, entry);
    updateCardCount(card);
    setCardStatus(card, "yellow");
  }
  if (args !== undefined) {
    const argsStr = typeof args === "string" ? args : JSON.stringify(args, null, 2);
    entry.rowEl.querySelector(".tool-args").textContent = argsStr;
  }
  if (name && entry.toolName !== name) {
    entry.toolName = name;
    entry.rowEl.querySelector(".tool-name").textContent = name;
  }
  return entry.rowEl;
}

function completeToolCall(callId, result, ok = true) {
  const entry = toolCallIndex.get(callId);
  if (!entry) return;
  const row = entry.rowEl;
  row.classList.remove("status-yellow");
  row.classList.add(ok ? "status-green" : "status-red");
  entry.status = ok ? "done" : "error";
  if (result !== undefined) {
    const resStr = typeof result === "string" ? result : JSON.stringify(result, null, 2);
    const resEl = row.querySelector(".tool-result");
    const resLabel = row.querySelector(".result-label");
    resEl.textContent = resStr;
    resEl.hidden = false;
    resLabel.hidden = false;
    row.querySelector(".tool-summary").textContent = (ok ? "ok · " : "error · ") + shortSummary(resStr);
  } else {
    row.querySelector(".tool-summary").textContent = ok ? "ok" : "error";
  }
  rollupCardStatus(entry.cardEl);
}

function updateCardCount(card) {
  if (!card) return;
  const rows = card.querySelectorAll(".tool-row");
  const cnt = rows.length;
  const el = card.querySelector(".agent-tool-count");
  if (el) el.textContent = cnt === 1 ? "1 tool" : `${cnt} tools`;
}

// ---------- SSE event handler ----------

let assistantBubble = null;

function handleEvent(eventType, data) {
  console.log("[sse]", eventType, data);
  switch (eventType) {
    case "response.created":
      // Don't create a real bubble yet — keep the thinking indicator
      // until the first text delta arrives. (If the model emits only
      // tool calls, the thinking bubble stays through the tool-call
      // phase, which is the desired behavior.)
      currentAssistantText = "";
      break;
    case "response.output_text.delta": {
      const delta = data.delta || data.text || "";
      hideThinking();
      if (!assistantBubble) assistantBubble = appendBubble("assistant", "");
      currentAssistantText += delta;
      assistantBubble.innerHTML = renderMarkdown(currentAssistantText);
      assistantBubble.classList.add("md");
      messagesEl.scrollTop = messagesEl.scrollHeight;
      break;
    }
    case "response.output_item.added": {
      const item = data.item || {};
      if (item.type === "function_call") {
        showThinking(`${shortAgentLabel(activeAgent)} is calling ${item.name}\u2026`);
        appendToolCall(item.call_id || item.id, item.name, item.arguments);
      }
      break;
    }
    case "response.function_call_arguments.delta": {
      const entry = toolCallIndex.get(data.call_id || data.item_id);
      if (entry) {
        const argsEl = entry.rowEl.querySelector(".tool-args");
        argsEl.textContent = (argsEl.textContent || "") + (data.delta || "");
      }
      break;
    }
    case "response.output_item.done": {
      const item = data.item || {};
      if (item.type === "function_call") {
        appendToolCall(item.call_id || item.id, item.name, item.arguments);
      } else if (item.type === "function_call_output") {
        completeToolCall(item.call_id, item.output, true);
        // Tool finished; model is about to think again about next step.
        showThinking(`${shortAgentLabel(activeAgent)} is thinking\u2026`);
      }
      break;
    }
    case "routing": {
      const direction = data?.direction || "forward";
      if (direction === "forward") {
        const target = data?.target;
        const targetAgent = AGENTS[target];
        if (!targetAgent) {
          console.warn("[routing] unknown forward target", target);
          break;
        }
        pendingForward = { target, targetAgent, summary: data?.summary || "" };
      } else if (direction === "back") {
        pendingHandback = { summary: data?.summary || "" };
      }
      break;
    }
    case "usage":
      addUsage(data);
      break;
    case "response.completed":
    case "response.done":
      if (currentAssistantText) {
        getHistory(activeAgent).push({ role: "assistant", content: currentAssistantText });
      }
      if (assistantBubble && currentAssistantText) {
        assistantBubble.innerHTML = renderMarkdown(currentAssistantText);
        assistantBubble.classList.add("md");
        messagesEl.scrollTop = messagesEl.scrollHeight;
      }
      assistantBubble = null;
      currentAssistantText = "";
      break;
    case "error":
      hideThinking();
      appendBubble("error", "Error: " + (data.message || JSON.stringify(data)));
      if (activeAgentCard) setCardStatus(activeAgentCard, "red");
      break;
    case "done":
      // Safety net: render markdown if not already done.
      if (assistantBubble && currentAssistantText) {
        getHistory(activeAgent).push({ role: "assistant", content: currentAssistantText });
        assistantBubble.innerHTML = renderMarkdown(currentAssistantText);
        assistantBubble.classList.add("md");
        assistantBubble = null;
        currentAssistantText = "";
      }
      if (pendingForward) {
        const { target, targetAgent, summary } = pendingForward;
        pendingForward = null;
        callerStack.push(activeAgent);
        const callerAgent = activeAgent;
        setActiveAgent(targetAgent);
        if (target === "pricing") {
          conversations.set(targetAgent, []);
        }
        const seed = summary ? summary : lastUserMessageForTurn;
        hideThinking();
        appendDivider(`handed off to ${targetAgent}`);
        sendToActiveAgent(seed, /*alreadyShown=*/true);
      } else if (pendingHandback) {
        const { summary } = pendingHandback;
        pendingHandback = null;
        const fromAgent = activeAgent;
        const callerAgent = callerStack.pop() || ORCHESTRATOR;
        console.log("[handback] popping stack: from=%s -> caller=%s, summary=%s", fromAgent, callerAgent, summary);
        setActiveAgent(callerAgent);
        hideThinking();
        appendDivider(`returned to ${callerAgent}`);
        const trigger = `[handback from ${fromAgent}: ${summary || "(no summary provided)"}]`;
        console.log("[handback] auto-triggering caller with:", trigger);
        setTimeout(() => sendToActiveAgent(trigger, /*alreadyShown=*/true), 0);
      } else {
        // Turn complete with no routing — mark active card green if no error.
        if (activeAgentCard) rollupCardStatus(activeAgentCard);
        hideThinking();
        sendBtn.disabled = false;
        input.disabled = false;
        input.focus();
      }
      break;
  }
}

// ---------- Send ----------

async function sendToActiveAgent(text, alreadyShown = false) {
  if (!alreadyShown) {
    appendBubble("user", text);
  }
  getHistory(activeAgent).push({ role: "user", content: text });
  sendBtn.disabled = true;
  input.disabled = true;
  if (!alreadyShown) input.value = "";
  lastUserMessageForTurn = text;

  showThinking();

  const history = getHistory(activeAgent).slice(0, -1);

  const resp = await fetch("/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: text, history, agent: activeAgent }),
  });
  if (!resp.ok || !resp.body) {
    hideThinking();
    appendBubble("error", "Network error: " + resp.status);
    sendBtn.disabled = false; input.disabled = false; return;
  }

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let sep;
    while ((sep = buffer.indexOf("\n\n")) >= 0) {
      const raw = buffer.slice(0, sep);
      buffer = buffer.slice(sep + 2);
      let evType = "message", dataStr = "";
      for (const line of raw.split("\n")) {
        if (line.startsWith("event:")) evType = line.slice(6).trim();
        else if (line.startsWith("data:")) dataStr += line.slice(5).trim();
      }
      let data;
      try { data = dataStr ? JSON.parse(dataStr) : {}; } catch { data = { raw: dataStr }; }
      handleEvent(evType, data);
    }
  }
}

form.addEventListener("submit", (e) => {
  e.preventDefault();
  const text = input.value.trim();
  if (text) sendToActiveAgent(text);
});

if (startOverBtn) {
  startOverBtn.addEventListener("click", () => {
    if (!confirm("Clear all conversations and start a fresh session?")) return;
    conversations = new Map();
    callerStack = [];
    activeAgentCard = null;
    messagesEl.innerHTML = "";
    activityEl.innerHTML = "";
    toolCallIndex.clear();
    countedResponseIds.clear();
    sessionTokens.input = 0;
    sessionTokens.output = 0;
    sessionTokens.total = 0;
    sessionTokens.estimated = false;
    tokenInEl.textContent = "0";
    tokenOutEl.textContent = "0";
    tokenTotalEl.textContent = "0";
    pendingForward = null;
    pendingHandback = null;
    lastUserMessageForTurn = null;
    currentAssistantText = "";
    assistantBubble = null;
    hideThinking();
    sendBtn.disabled = false;
    input.disabled = false;
    setActiveAgent(ORCHESTRATOR);
    appendBubble("system", `Reset. Connected to ${ORCHESTRATOR}.`);
    input.focus();
  });
}

setActiveAgent(ORCHESTRATOR);
appendBubble(
  "system",
  `Connected to ${ORCHESTRATOR}. Tell me whether you want a Windows VM, a Linux VM, or a cost estimate.`
);
