const state = {
  profiles: [],
  activeProfile: null,
  view: "servers",
  dataDir: "",
  pollTimer: null,
  listTimer: null,
  sse: null,
};

// 新增服务器时预填的默认配置：反代本机 claude-code-router (CCR)。
// 换其他 provider 时，在表单里直接改这几个字段即可。
const CCR_DEFAULTS = {
  local_api_port: 18990,
  remote_api_port: 18990,
  api_provider_name: "claude-code-router",
  wire_api: "responses",
  model: "codex2api/gpt-5.5",
  model_catalog_path: "~/.codex/ccr-model-catalog.json",
};

const els = {
  navItems: document.querySelectorAll(".nav-item"),
  viewTitle: document.querySelector("#view-title"),
  rows: document.querySelector("#profile-rows"),
  empty: document.querySelector("#empty-state"),
  search: document.querySelector("#search"),
  add: document.querySelector("#add-profile"),
  repairActive: document.querySelector("#repair-active"),
  emptyAdd: document.querySelector("#empty-add"),
  toolbar: document.querySelector("#toolbar"),
  serverView: document.querySelector("#server-view"),
  viewPanel: document.querySelector("#view-panel"),
  panel: document.querySelector("#detail-panel"),
  closePanel: document.querySelector("#close-panel"),
  form: document.querySelector("#profile-form"),
  save: document.querySelector("#save-profile"),
  title: document.querySelector("#detail-title"),
  count: document.querySelector("#server-count"),
  dataDir: document.querySelector("#data-dir"),
  logDrawer: document.querySelector("#log-drawer"),
  closeLog: document.querySelector("#close-log"),
  jobState: document.querySelector("#job-state"),
  jobTitle: document.querySelector("#job-title"),
  jobLog: document.querySelector("#job-log"),
  toast: document.querySelector("#toast"),
  shell: document.querySelector("#app-shell"),
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({ error: response.statusText }));
    throw new Error(body.error || response.statusText);
  }
  if (response.status === 204) return null;
  return response.json();
}

async function loadProfiles() {
  const body = await api("/api/profiles");
  state.profiles = body.profiles;
  state.dataDir = body.data_dir;
  els.count.textContent = String(state.profiles.length);
  renderActiveView();
}

function setView(view) {
  state.view = view;
  renderActiveView();
}

function renderActiveView() {
  const meta = viewMeta(state.view);
  els.viewTitle.textContent = meta.title;
  els.dataDir.textContent = meta.subtitle;

  els.navItems.forEach((item) => {
    item.classList.toggle("active", item.dataset.view === state.view);
  });

  const isServerView = state.view === "servers";
  els.toolbar.hidden = !isServerView;
  els.serverView.hidden = !isServerView;
  els.viewPanel.hidden = isServerView;

  if (isServerView) {
    renderRows();
  } else {
    renderUtilityView();
  }

  updateListAutoRefresh();
}

const LIST_REFRESH_MS = 15000;

// 仅在服务器视图、且没有 job 抽屉在轮询或 SSE 订阅时,后台每 15s 静默刷新列表健康状态。
function updateListAutoRefresh() {
  const shouldRun = state.view === "servers" && state.pollTimer === null && state.sse === null;
  if (shouldRun && state.listTimer === null) {
    state.listTimer = setInterval(() => {
      loadProfiles().catch(() => {});
    }, LIST_REFRESH_MS);
  } else if (!shouldRun && state.listTimer !== null) {
    clearInterval(state.listTimer);
    state.listTimer = null;
  }
}

function renderRows() {
  const query = els.search.value.trim().toLowerCase();
  const profiles = state.profiles.filter((profile) => {
    const haystack = `${profile.alias} ${profile.host} ${profile.user} ${profile.note}`.toLowerCase();
    return haystack.includes(query);
  });

  els.rows.innerHTML = profiles.map(rowTemplate).join("");
  els.empty.style.display = profiles.length ? "none" : "block";

  bindActionButtons(els.rows);
}

function bindActionButtons(root) {
  root.querySelectorAll("[data-action]").forEach((button) => {
    button.addEventListener("click", onRowAction);
  });
}

function rowTemplate(profile, index) {
  const status = statusMeta(profile.last_status);
  const tunnel = tunnelMeta(profile.tunnel_state);
  const recent = profile.last_connected_at ? formatDate(profile.last_connected_at) : "未连接";
  const keyState = profile.has_ssh_password ? "已保存密码" : "未存密码";
  const api = profile.has_api_key ? "Key 已存" : "Key 复用";
  const busy = profile.last_status === "running";
  const disabled = busy ? "disabled aria-disabled=\"true\"" : "";
  const connectLabel = busy ? "连接中" : "连接";

  return `
    <tr>
      <td><input type="checkbox" aria-label="选择 ${escapeHtml(profile.alias)}" /></td>
      <td>${index + 1}</td>
      <td>
        <div class="server-name">
          <strong>${escapeHtml(profile.alias)}</strong>
          <span>${escapeHtml(keyState)} · ${escapeHtml(api)}</span>
        </div>
      </td>
      <td><span class="ssh-badge">${escapeHtml(profile.user)}@${escapeHtml(profile.host)}:${profile.port}</span></td>
      <td><span class="port-badge">${profile.local_api_port} → ${profile.remote_api_port}</span></td>
      <td><span class="status-badge ${status.className}">${status.label}</span></td>
      <td>
        <div class="health">
          <div class="health-track"><span class="health-fill" style="width: ${profile.health_score}%"></span></div>
          <span class="health-label">${profile.health_score}%</span>
        </div>
      </td>
      <td>
        <div class="tunnel-cell">
          <div class="mini-track"><span class="mini-fill" style="width: ${tunnel.width}%"></span></div>
          <span>${tunnel.label}</span>
        </div>
      </td>
      <td>${escapeHtml(recent)}</td>
      <td>
        <div class="row-actions">
          <button class="secondary-button" type="button" data-action="connect" data-alias="${escapeAttr(profile.alias)}" ${disabled}>${connectLabel}</button>
          <button class="secondary-button" type="button" data-action="repair" data-alias="${escapeAttr(profile.alias)}" ${disabled}>修复</button>
          <button class="secondary-button" type="button" data-action="diagnose" data-alias="${escapeAttr(profile.alias)}" ${disabled}>诊断</button>
          <button class="icon-button" type="button" data-action="edit" data-alias="${escapeAttr(profile.alias)}" aria-label="编辑">✎</button>
          <button class="icon-button" type="button" data-action="delete" data-alias="${escapeAttr(profile.alias)}" aria-label="删除">×</button>
        </div>
      </td>
    </tr>
  `;
}

function renderUtilityView() {
  if (state.view === "tunnels") {
    els.viewPanel.innerHTML = tunnelViewTemplate();
  } else if (state.view === "diagnostics") {
    els.viewPanel.innerHTML = diagnosticsViewTemplate();
  } else {
    els.viewPanel.innerHTML = settingsViewTemplate();
  }
  bindActionButtons(els.viewPanel);
}

function tunnelViewTemplate() {
  const running = state.profiles.filter((profile) => profile.tunnel_state === "running").length;
  const stale = state.profiles.filter((profile) => profile.tunnel_state === "stale").length;
  const missing = state.profiles.length - running - stale;

  return `
    ${summaryTemplate([
      ["watchdog 运行", running],
      ["pid 失效", stale],
      ["未发现隧道", missing],
    ])}
    ${state.profiles.length ? state.profiles.map(tunnelCardTemplate).join("") : emptyUtilityTemplate("还没有服务器", "先新增服务器后，这里会显示每台机器的 SSH 反向隧道状态。")}
  `;
}

function tunnelCardTemplate(profile) {
  const tunnel = tunnelMeta(profile.tunnel_state);
  const busy = profile.last_status === "running";
  const disabled = busy ? "disabled aria-disabled=\"true\"" : "";
  const connectLabel = busy ? "连接中" : "启动连接";

  return `
    <article class="ops-card">
      <div class="ops-main">
        <div>
          <h2>${escapeHtml(profile.alias)}</h2>
          <p>远端 127.0.0.1:${profile.remote_api_port} → 本机 127.0.0.1:${profile.local_api_port}</p>
        </div>
        <span class="status-badge ${profile.tunnel_state === "running" ? "status-connected" : "status-new"}">${tunnel.label}</span>
      </div>
      <div class="mini-track"><span class="mini-fill" style="width: ${tunnel.width}%"></span></div>
      <div class="ops-actions">
        <button class="primary-button" type="button" data-action="connect" data-alias="${escapeAttr(profile.alias)}" ${disabled}>${connectLabel}</button>
        <button class="secondary-button" type="button" data-action="repair" data-alias="${escapeAttr(profile.alias)}" ${disabled}>修复隧道</button>
        <button class="secondary-button" type="button" data-action="diagnose" data-alias="${escapeAttr(profile.alias)}" ${disabled}>诊断</button>
      </div>
    </article>
  `;
}

function diagnosticsViewTemplate() {
  const connected = state.profiles.filter((profile) => profile.last_status === "connected").length;
  const failed = state.profiles.filter((profile) => profile.last_status === "failed").length;
  const avgHealth = state.profiles.length
    ? Math.round(state.profiles.reduce((sum, profile) => sum + profile.health_score, 0) / state.profiles.length)
    : 0;

  return `
    ${summaryTemplate([
      ["可连接", connected],
      ["失败", failed],
      ["平均健康度", `${avgHealth}%`],
    ])}
    ${state.profiles.length ? state.profiles.map(diagnosticCardTemplate).join("") : emptyUtilityTemplate("还没有可诊断的服务器", "添加服务器后，可以在这里集中查看密码、Key、隧道和最近状态。")}
  `;
}

function diagnosticCardTemplate(profile) {
  const status = statusMeta(profile.last_status);
  const tunnel = tunnelMeta(profile.tunnel_state);
  const busy = profile.last_status === "running";
  const disabled = busy ? "disabled aria-disabled=\"true\"" : "";

  return `
    <article class="ops-card">
      <div class="ops-main">
        <div>
          <h2>${escapeHtml(profile.alias)}</h2>
          <p>${escapeHtml(profile.last_message || "等待诊断")}</p>
        </div>
        <span class="status-badge ${status.className}">${status.label}</span>
      </div>
      <dl class="check-list">
        <div><dt>SSH 密码</dt><dd>${profile.has_ssh_password ? "已保存" : "未保存"}</dd></div>
        <div><dt>API Key</dt><dd>${profile.has_api_key ? "已保存" : "复用/未保存"}</dd></div>
        <div><dt>端口</dt><dd>${profile.local_api_port} → ${profile.remote_api_port}</dd></div>
        <div><dt>隧道</dt><dd>${tunnel.label}</dd></div>
      </dl>
      <div class="health">
        <div class="health-track"><span class="health-fill" style="width: ${profile.health_score}%"></span></div>
        <span class="health-label">${profile.health_score}%</span>
      </div>
      <div class="ops-actions">
        <button class="primary-button" type="button" data-action="diagnose" data-alias="${escapeAttr(profile.alias)}" ${disabled}>运行诊断</button>
        <button class="secondary-button" type="button" data-action="repair" data-alias="${escapeAttr(profile.alias)}" ${disabled}>修复隧道</button>
        <button class="secondary-button" type="button" data-action="connect" data-alias="${escapeAttr(profile.alias)}" ${disabled}>连接</button>
      </div>
    </article>
  `;
}

function settingsViewTemplate() {
  return `
    <article class="settings-panel">
      <h2>本地配置</h2>
      <dl class="settings-list">
        <div><dt>数据目录</dt><dd>${escapeHtml(state.dataDir || "未加载")}</dd></div>
        <div><dt>SSH 主配置</dt><dd>~/.ssh/config</dd></div>
        <div><dt>SSH 副配置</dt><dd>~/.ssh/codex2autodl/config</dd></div>
        <div><dt>删除同步</dt><dd>删除面板服务器时，同步清理 SSH Host 和 Codex remote-ssh 状态索引</dd></div>
      </dl>
    </article>
    <article class="settings-panel">
      <h2>维护命令</h2>
      <p>清空 codex2autodl 写入的 AutoDL SSH/Codex 远程历史：</p>
      <code>cargo run -- clear-autodl-history</code>
    </article>
  `;
}

function summaryTemplate(items) {
  return `
    <div class="summary-grid">
      ${items
        .map(
          ([label, value]) => `
            <div class="summary-card">
              <span>${escapeHtml(label)}</span>
              <strong>${escapeHtml(value)}</strong>
            </div>
          `,
        )
        .join("")}
    </div>
  `;
}

function emptyUtilityTemplate(title, message) {
  return `
    <div class="utility-empty">
      <strong>${escapeHtml(title)}</strong>
      <p>${escapeHtml(message)}</p>
    </div>
  `;
}

async function onRowAction(event) {
  const button = event.currentTarget;
  if (button.disabled) return;

  const alias = button.dataset.alias;
  const action = button.dataset.action;

  if (action === "edit") {
    openPanel(state.profiles.find((profile) => profile.alias === alias));
    return;
  }

  if (action === "delete") {
    if (!window.confirm(`删除 ${alias}？`)) return;
    await api(`/api/profiles/${encodeURIComponent(alias)}`, { method: "DELETE" });
    showToast("已删除");
    await loadProfiles();
    return;
  }

  if (action === "connect") {
    await startProfileJob(alias, "connect");
    return;
  }

  if (action === "repair") {
    await startProfileJob(alias, "repair");
    return;
  }

  if (action === "diagnose") {
    await startProfileJob(alias, "diagnose");
  }
}

async function startProfileJob(alias, action) {
  markProfileRunning(alias);
  try {
    const job = await api(`/api/profiles/${encodeURIComponent(alias)}/${action}`, { method: "POST" });
    watchJob(job);
  } catch (error) {
    await loadProfiles();
    showToast(error.message);
  }
}

async function repairActiveRemotes() {
  try {
    const job = await api("/api/active-remotes/repair", { method: "POST" });
    watchJob(job);
  } catch (error) {
    await loadProfiles();
    showToast(error.message);
  }
}

function markProfileRunning(alias) {
  state.profiles = state.profiles.map((profile) =>
    profile.alias === alias
      ? { ...profile, last_status: "running", last_message: "任务运行中" }
      : profile,
  );
  renderRows();
}

function openPanel(profile = null) {
  state.activeProfile = profile;
  els.title.textContent = profile ? "编辑服务器" : "新增服务器";
  els.form.reset();

  els.form.alias.value = profile?.alias || "";
  els.form.ssh_command.value = profile?.ssh_command || "";
  const d = profile ? {} : CCR_DEFAULTS;
  els.form.local_api_port.value = profile?.local_api_port || d.local_api_port || 8080;
  els.form.remote_api_port.value = profile?.remote_api_port || d.remote_api_port || 8080;
  els.form.api_provider_name.value = profile?.api_provider_name || d.api_provider_name || "";
  els.form.wire_api.value = profile?.wire_api || d.wire_api || "responses";
  els.form.model.value = profile?.model || d.model || "";
  els.form.model_catalog_path.value = profile?.model_catalog_path || d.model_catalog_path || "";
  els.form.note.value = profile?.note || "";
  els.form.ssh_password.placeholder = profile?.has_ssh_password ? "已保存，留空不修改" : "";
  els.form.api_key.placeholder = profile?.has_api_key ? "已保存，留空不修改" : "";
  els.panel.classList.add("open");
  els.shell.classList.add("panel-open");
  els.form.alias.focus();
}

function closePanel() {
  els.panel.classList.remove("open");
  els.shell.classList.remove("panel-open");
}

function formPayload() {
  const data = Object.fromEntries(new FormData(els.form).entries());
  return {
    alias: data.alias.trim(),
    ssh_command: data.ssh_command.trim(),
    ssh_password: data.ssh_password,
    api_key: data.api_key,
    local_api_port: Number(data.local_api_port || 8080),
    remote_api_port: Number(data.remote_api_port || data.local_api_port || 8080),
    api_provider_name: (data.api_provider_name || "").trim(),
    wire_api: data.wire_api || "responses",
    model: (data.model || "").trim(),
    model_catalog_path: (data.model_catalog_path || "").trim(),
    note: data.note.trim(),
    tags: [],
  };
}

async function saveProfile({ connect = false } = {}) {
  const payload = formPayload();
  await api("/api/profiles", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  showToast("已保存");
  closePanel();
  await loadProfiles();

  if (connect) {
    await startProfileJob(payload.alias, "connect");
  }
}

function watchJob(job) {
  clearInterval(state.pollTimer);
  state.pollTimer = null;
  stopSse();
  els.logDrawer.classList.add("open");
  renderJob(job);

  // 优先用 SSE 实时推送日志;不支持或建连失败时回退到 1 秒轮询。
  if (typeof EventSource !== "undefined") {
    watchJobViaSse(job);
  } else {
    watchJobViaPolling(job);
  }
  // job 观察期间暂停列表定时刷新,结束后再恢复。
  updateListAutoRefresh();
}

function stopSse() {
  if (state.sse) {
    state.sse.close();
    state.sse = null;
  }
}

async function finishJobWatch() {
  if (state.pollTimer !== null) {
    clearInterval(state.pollTimer);
    state.pollTimer = null;
  }
  stopSse();
  await loadProfiles();
  updateListAutoRefresh();
}

function watchJobViaSse(job) {
  // 增量拼接日志:renderJob 用整段,这里维护本地行缓冲逐条追加。
  const lines = [...job.logs];
  const source = new EventSource(`/api/jobs/${encodeURIComponent(job.id)}/stream`);
  state.sse = source;
  let fellBack = false;

  source.addEventListener("log", (event) => {
    lines.push(event.data);
    renderJobLines(job, lines, "running");
  });
  source.addEventListener("done", async (event) => {
    renderJobLines(job, lines, event.data);
    await finishJobWatch();
  });
  source.onerror = () => {
    // 建连或传输出错:关闭 SSE,回退轮询,避免浏览器无限自动重连。
    if (fellBack) return;
    fellBack = true;
    stopSse();
    watchJobViaPolling(job);
  };
}

function watchJobViaPolling(job) {
  state.pollTimer = setInterval(async () => {
    let next;
    try {
      next = await api(`/api/jobs/${encodeURIComponent(job.id)}`);
    } catch (error) {
      return;
    }
    renderJob(next);
    if (next.status !== "running") {
      await finishJobWatch();
    }
  }, 1000);
}

function renderJob(job) {
  renderJobLines(job, job.logs, job.status);
}

function jobStateLabel(status) {
  if (status === "running") return "运行中";
  if (status === "succeeded") return "完成";
  return "失败";
}

function renderJobLines(job, lines, status) {
  els.jobState.textContent = jobStateLabel(status);
  els.jobTitle.textContent = `${job.alias} · ${actionLabel(job.action)}`;
  els.jobLog.textContent = lines.join("\n");
  els.jobLog.scrollTop = els.jobLog.scrollHeight;
}

function statusMeta(status) {
  if (status === "connected") return { label: "可连接", className: "status-connected" };
  if (status === "running") return { label: "运行中", className: "status-running" };
  if (status === "failed") return { label: "失败", className: "status-failed" };
  if (status === "stopped") return { label: "已停止", className: "status-stopped" };
  return { label: "待连接", className: "status-new" };
}

function tunnelMeta(stateName) {
  if (stateName === "running") return { label: "watchdog 运行", width: 94 };
  if (stateName === "stale") return { label: "pid 失效", width: 42 };
  return { label: "未发现", width: 12 };
}

function actionLabel(action) {
  if (action === "connect") return "连接";
  if (action === "quick_reconnect") return "修复隧道";
  if (action === "repair_active") return "修复当前活跃连接";
  if (action === "diagnose") return "诊断";
  if (action === "stop_tunnel") return "停止隧道";
  return action;
}

function viewMeta(view) {
  if (view === "tunnels") {
    return { title: "隧道", subtitle: "查看和启动每台服务器的 API 反向隧道" };
  }
  if (view === "diagnostics") {
    return { title: "诊断", subtitle: "集中检查连接状态、密钥、端口和最近任务结果" };
  }
  if (view === "settings") {
    return { title: "设置", subtitle: state.dataDir };
  }
  return { title: "服务器", subtitle: state.dataDir };
}

function formatDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function showToast(message) {
  els.toast.textContent = message;
  els.toast.classList.add("show");
  setTimeout(() => els.toast.classList.remove("show"), 1800);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function escapeAttr(value) {
  return escapeHtml(value);
}

els.add.addEventListener("click", () => openPanel());
els.repairActive.addEventListener("click", repairActiveRemotes);
els.emptyAdd.addEventListener("click", () => openPanel());
els.closePanel.addEventListener("click", closePanel);
els.save.addEventListener("click", () => saveProfile());
els.form.addEventListener("submit", (event) => {
  event.preventDefault();
  saveProfile({ connect: true }).catch((error) => showToast(error.message));
});
els.search.addEventListener("input", renderRows);
els.closeLog.addEventListener("click", () => {
  els.logDrawer.classList.remove("open");
  if (state.pollTimer !== null) {
    clearInterval(state.pollTimer);
    state.pollTimer = null;
  }
  stopSse();
  updateListAutoRefresh();
});
els.navItems.forEach((item) => {
  item.addEventListener("click", () => setView(item.dataset.view));
});

loadProfiles().catch((error) => showToast(error.message));
