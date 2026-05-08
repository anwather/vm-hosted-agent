// SSE chat client for Task Orchestrator (caller-stack multi-agent routing).
//
// State model:
//   conversations: Map<agentName, history[]>  // per-agent message history
//   callerStack: agentName[]                   // stack of who called whom
//   activeAgent: agentName                     // who the user is talking to
//
// Routing markers (intercepted server-side, surfaced as SSE `routing` events):
//   forward { direction:"forward", target:"windows|linux|pricing", summary? }
//     -> push current agent onto callerStack; switch to target; replay
//        either the original user message (orchestrator -> specialist) or
//        the summary as the seed prompt (specialist -> pricing).
//   back    { direction:"back", summary? }
//     -> pop callerStack; switch back; auto-send `[handback from <fromAgent>:
//        <summary>]` to the caller as a user-role turn so the caller
//        immediately greets/summarises/routes without waiting for the user.

const messagesEl = document.getElementById("messages");
const toolsEl = document.getElementById("tools-list");
const tfLogEl = document.getElementById("tf-log");
const form = document.getElementById("chat-form");
const input = document.getElementById("message");
const sendBtn = document.getElementById("send");
const headerEl = document.querySelector("header");
const activeAgentDisplay = document.getElementById("active-agent-display");
const handoffBanner = document.getElementById("handoff-banner");
const handoffTargetEl = document.getElementById("handoff-target");
const handbackBanner = document.getElementById("handback-banner");
const handbackTargetEl = document.getElementById("handback-target");
const startOverBtn = document.getElementById("start-over");

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
// Stack of agent names representing who delegated to whom. Top = most
// recent caller of the current active agent.
let callerStack = [];
// Currently active agent name (default: orchestrator).
let activeAgent = ORCHESTRATOR;

// Per-turn state.
let pendingForward = null;       // { target, targetAgent, summary }
let pendingHandback = null;      // { summary }
let lastUserMessageForTurn = null;
let currentAssistantText = "";

const toolCallIndex = new Map();

const tokenTotalEl = document.getElementById("token-total");
const tokenInEl = document.getElementById("token-in");
const tokenOutEl = document.getElementById("token-out");
const sessionTokens = { input: 0, output: 0, total: 0, estimated: false };

function fmt(n) { return n.toLocaleString(); }

function setActiveAgent(name) {
  activeAgent = name;
  activeAgentDisplay.textContent = name;
}

function showForwardBanner(target) {
  const targetAgent = AGENTS[target] || target;
  handoffTargetEl.textContent = targetAgent;
  handoffBanner.hidden = false;
  handbackBanner.hidden = true;
}

function showHandbackBanner(callerAgent) {
  handbackTargetEl.textContent = callerAgent;
  handbackBanner.hidden = false;
  handoffBanner.hidden = true;
}

function clearBanners() {
  handoffBanner.hidden = true;
  handbackBanner.hidden = true;
}

function getHistory(agent) {
  let h = conversations.get(agent);
  if (!h) { h = []; conversations.set(agent, h); }
  return h;
}

function pushSyntheticHandbackNote(agent, summary) {
  // Deprecated — see handback flow in `done` handler. Kept as no-op for
  // safety in case any callsite still references it.
  return;
}

function renderMarkdown(text) {
  if (!text) return "";
  if (typeof marked === "undefined" || typeof DOMPurify === "undefined") {
    // Libraries failed to load — fall back to escaped text with line breaks.
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML.replace(/\n/g, "<br>");
  }
  marked.setOptions({ gfm: true, breaks: true });
  return DOMPurify.sanitize(marked.parse(text));
}

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

function appendBubble(role, text) {
  const div = document.createElement("div");
  div.className = `bubble ${role}`;
  div.textContent = text;
  messagesEl.appendChild(div);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return div;
}

function appendToolCall(callId, name, args) {
  let li = toolCallIndex.get(callId);
  if (!li) {
    li = document.createElement("li");
    li.className = "in_progress";
    li.innerHTML = `<span class="tool-name"></span><span class="tool-args"></span><span class="tool-result"></span>`;
    toolsEl.appendChild(li);
    toolCallIndex.set(callId, li);
  }
  li.querySelector(".tool-name").textContent = name || "(tool)";
  if (args !== undefined) li.querySelector(".tool-args").textContent = typeof args === "string" ? args : JSON.stringify(args);
  toolsEl.scrollTop = toolsEl.scrollHeight;
  return li;
}

function completeToolCall(callId, result, ok = true) {
  const li = toolCallIndex.get(callId);
  if (!li) return;
  li.classList.remove("in_progress");
  li.classList.add(ok ? "done" : "error");
  if (result !== undefined) li.querySelector(".tool-result").textContent = "→ " + (typeof result === "string" ? result : JSON.stringify(result, null, 2));
  if (typeof result === "string" && /terraform|Plan:|Apply complete|tf-/.test(result)) {
    tfLogEl.textContent += (tfLogEl.textContent ? "\n" : "") + result;
    tfLogEl.scrollTop = tfLogEl.scrollHeight;
  }
}

let assistantBubble = null;

function handleEvent(eventType, data) {
  console.log("[sse]", eventType, data);
  switch (eventType) {
    case "response.created":
      assistantBubble = appendBubble("assistant", "");
      currentAssistantText = "";
      break;
    case "response.output_text.delta": {
      const delta = data.delta || data.text || "";
      if (!assistantBubble) assistantBubble = appendBubble("assistant", "");
      currentAssistantText += delta;
      // Render the running text as markdown on each delta. marked tolerates
      // partial/unclosed syntax (e.g. an open ** will just render literally
      // until the closer arrives, then re-renders as bold on the next delta).
      assistantBubble.innerHTML = renderMarkdown(currentAssistantText);
      assistantBubble.classList.add("md");
      messagesEl.scrollTop = messagesEl.scrollHeight;
      break;
    }
    case "response.output_item.added": {
      const item = data.item || {};
      if (item.type === "function_call") {
        appendToolCall(item.call_id || item.id, item.name, item.arguments);
      }
      break;
    }
    case "response.function_call_arguments.delta": {
      const li = toolCallIndex.get(data.call_id || data.item_id);
      if (li) {
        const argsEl = li.querySelector(".tool-args");
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
      }
      break;
    }
    case "routing": {
      // The active agent emitted a routing marker. Capture it; the actual
      // switch + replay/handback happens on `done` so the current stream
      // can finish flushing first (e.g. the trailing "Handing you over"
      // sentence).
      const direction = data?.direction || "forward";
      if (direction === "forward") {
        const target = data?.target;
        const targetAgent = AGENTS[target];
        if (!targetAgent) {
          console.warn("[routing] unknown forward target", target);
          break;
        }
        pendingForward = { target, targetAgent, summary: data?.summary || "" };
        showForwardBanner(target);
      } else if (direction === "back") {
        // Resolve the caller from our stack (peek; pop happens on `done`).
        const caller = callerStack.length ? callerStack[callerStack.length - 1] : ORCHESTRATOR;
        pendingHandback = { summary: data?.summary || "" };
        showHandbackBanner(caller);
      }
      break;
    }
    case "usage":
      addUsage(data);
      break;
    case "response.completed":
    case "response.done":
      // Persist the assistant's reply (sans markers — backend already
      // stripped them) into the CURRENTLY active agent's history. This is
      // the agent that produced the reply; the swap (if any) hasn't
      // happened yet.
      if (currentAssistantText) {
        getHistory(activeAgent).push({ role: "assistant", content: currentAssistantText });
      }
      // Re-render the assistant bubble as markdown HTML now that the full
      // text is known (avoids partial-syntax issues during streaming).
      if (assistantBubble && currentAssistantText) {
        assistantBubble.innerHTML = renderMarkdown(currentAssistantText);
        assistantBubble.classList.add("md");
        messagesEl.scrollTop = messagesEl.scrollHeight;
      }
      assistantBubble = null;
      currentAssistantText = "";
      break;
    case "error":
      appendBubble("system", "Error: " + (data.message || JSON.stringify(data)));
      break;
    case "done":
      // Safety net: if no response.completed/done fired, render markdown now.
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
        // Push current onto caller stack, switch to target.
        callerStack.push(activeAgent);
        const callerAgent = activeAgent;
        setActiveAgent(targetAgent);
        // Pricing always starts fresh — every cost question is self-contained.
        if (target === "pricing") {
          conversations.set(targetAgent, []);
        }
        // Seed message: when caller provided a summary (specialist ->
        // pricing), the summary IS the prompt. Otherwise replay the
        // user's last message (orchestrator -> specialist).
        const seed = summary ? summary : lastUserMessageForTurn;
        appendBubble("system", `→ Handed off from ${callerAgent} to ${targetAgent}${summary ? `: ${summary}` : ""}.`);
        sendToActiveAgent(seed, /*alreadyShown=*/true);
      } else if (pendingHandback) {
        const { summary } = pendingHandback;
        pendingHandback = null;
        const fromAgent = activeAgent;
        const callerAgent = callerStack.pop() || ORCHESTRATOR;
        console.log("[handback] popping stack: from=%s -> caller=%s, summary=%s", fromAgent, callerAgent, summary);
        setActiveAgent(callerAgent);
        appendBubble(
          "system",
          `↩ Returned from ${fromAgent} to ${callerAgent}${summary ? ` — ${summary}` : ""}.`
        );
        // Auto-trigger the caller so it greets/summarises/routes without
        // waiting for the user to type. Sent as a user-role turn (the
        // caller's prompt teaches it to recognise "[handback from X: Y]"
        // as a control message rather than user speech).
        const trigger = `[handback from ${fromAgent}: ${summary || "(no summary provided)"}]`;
        console.log("[handback] auto-triggering caller with:", trigger);
        // Schedule via setTimeout so it runs AFTER the current reader-loop
        // iteration completes — avoids re-entering handleEvent while the
        // outer reader is still inside its read cycle.
        setTimeout(() => sendToActiveAgent(trigger, /*alreadyShown=*/true), 0);
      } else {
        sendBtn.disabled = false;
        input.disabled = false;
        input.focus();
      }
      break;
  }
}

async function sendToActiveAgent(text, alreadyShown = false) {
  if (!alreadyShown) {
    appendBubble("user", text);
  }
  // Append to active agent's history.
  getHistory(activeAgent).push({ role: "user", content: text });
  sendBtn.disabled = true;
  input.disabled = true;
  if (!alreadyShown) input.value = "";
  lastUserMessageForTurn = text;

  // History sent to backend = everything except the current user turn
  // (server appends the user message itself).
  const history = getHistory(activeAgent).slice(0, -1);

  const resp = await fetch("/chat", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: text, history, agent: activeAgent }),
  });
  if (!resp.ok || !resp.body) {
    appendBubble("system", "Network error: " + resp.status);
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
    setActiveAgent(ORCHESTRATOR);
    messagesEl.innerHTML = "";
    toolsEl.innerHTML = "";
    tfLogEl.textContent = "";
    toolCallIndex.clear();
    countedResponseIds.clear();
    sessionTokens.input = 0;
    sessionTokens.output = 0;
    sessionTokens.total = 0;
    sessionTokens.estimated = false;
    tokenInEl.textContent = "0";
    tokenOutEl.textContent = "0";
    tokenTotalEl.textContent = "0";
    clearBanners();
    pendingForward = null;
    pendingHandback = null;
    lastUserMessageForTurn = null;
    currentAssistantText = "";
    assistantBubble = null;
    sendBtn.disabled = false;
    input.disabled = false;
    appendBubble("system", `Reset. Connected to ${ORCHESTRATOR}.`);
    input.focus();
  });
}

setActiveAgent(ORCHESTRATOR);
appendBubble(
  "system",
  `Connected to ${ORCHESTRATOR}. Tell me whether you want a Windows VM, a Linux VM, or a cost estimate.`
);
