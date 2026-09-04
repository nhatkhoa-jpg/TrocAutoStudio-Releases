const chat = document.querySelector('#chat');
const welcome = document.querySelector('#welcome');
const input = document.querySelector('#input');
const send = document.querySelector('#send');
const project = document.querySelector('#project');
const mode = document.querySelector('#mode');
const statusText = document.querySelector('#statusText');
const newChat = document.querySelector('#newChat');
const mic = document.querySelector('#mic');
const jobsDialog = document.querySelector('#jobsDialog');
const jobsList = document.querySelector('#jobsList');
const jobsButton = document.querySelector('#jobsButton');
const closeJobs = document.querySelector('#closeJobs');
const jobForm = document.querySelector('#jobForm');
const jobRepo = document.querySelector('#jobRepo');
const jobTask = document.querySelector('#jobTask');

let history = JSON.parse(localStorage.getItem('troc-ai-history') || '[]');
let busy = false;

function saveHistory() {
  localStorage.setItem('troc-ai-history', JSON.stringify(history.slice(-30)));
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
}

function addMessage(role, content, transient = false) {
  welcome?.remove();
  const row = document.createElement('div');
  row.className = `message ${role}`;
  if (role === 'assistant') {
    const avatar = document.createElement('div');
    avatar.className = 'avatar';
    avatar.textContent = 'T';
    row.appendChild(avatar);
  }
  const bubble = document.createElement('div');
  bubble.className = `bubble${transient ? ' typing' : ''}`;
  bubble.textContent = content;
  row.appendChild(bubble);
  chat.appendChild(row);
  window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' });
  return row;
}

function renderHistory() {
  if (!history.length) return;
  welcome?.remove();
  for (const item of history) addMessage(item.role, item.content);
}

function autoSize() {
  input.style.height = 'auto';
  input.style.height = `${Math.min(150, input.scrollHeight)}px`;
}

async function refreshHealth() {
  try {
    const r = await fetch('/api/health', { cache: 'no-store' });
    const h = await r.json();
    if (!h.ok) throw new Error('health');
    const cooldown = h.cooldown_until > Date.now();
    statusText.textContent = cooldown ? 'A1 online • Gemini đang cooldown' : (h.gemini_ready ? `A1 online • ${h.model}` : 'A1 online • thiếu Gemini key');
  } catch {
    statusText.textContent = 'Không kết nối được A1';
  }
}

async function sendMessage(text = input.value) {
  const message = String(text || '').trim();
  if (!message || busy) return;
  busy = true;
  input.value = '';
  autoSize();
  const prior = history.slice(-24);
  history.push({ role:'user', content:message });
  addMessage('user', message);
  saveHistory();
  const typing = addMessage('assistant', 'Đang suy nghĩ…', true);
  try {
    const r = await fetch('/api/chat', {
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({ message, history:prior, project:project.value, mode:mode.value }),
    });
    const data = await r.json();
    if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
    typing.remove();
    history.push({ role:'assistant', content:data.answer });
    addMessage('assistant', data.answer);
    saveHistory();
  } catch (error) {
    typing.querySelector('.bubble').classList.remove('typing');
    typing.querySelector('.bubble').classList.add('error');
    typing.querySelector('.bubble').textContent = `Lỗi: ${error.message}`;
  } finally {
    busy = false;
    refreshHealth();
  }
}

async function loadJobs() {
  jobsList.innerHTML = '<div class="typing">Đang tải…</div>';
  try {
    const r = await fetch('/api/jobs', { cache:'no-store' });
    const data = await r.json();
    const jobs = data.jobs || [];
    if (!jobs.length) {
      jobsList.innerHTML = '<div class="job-card">Chưa có công việc.</div>';
      return;
    }
    jobsList.innerHTML = jobs.map((j) => `<div class="job-card"><strong>${escapeHtml(j.bucket || j.status || 'job')}</strong> • ${escapeHtml(j.target_repo || '')}<div>${escapeHtml(j.task || '').slice(0,300)}</div><small>${escapeHtml(j.created_at || '')}</small></div>`).join('');
  } catch (e) {
    jobsList.innerHTML = `<div class="job-card error">${escapeHtml(e.message)}</div>`;
  }
}

input.addEventListener('input', autoSize);
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
});
send.addEventListener('click', () => sendMessage());
newChat.addEventListener('click', () => { history = []; saveHistory(); location.reload(); });
document.querySelectorAll('[data-prompt]').forEach((button) => button.addEventListener('click', () => sendMessage(button.dataset.prompt)));

jobsButton.addEventListener('click', async () => { await loadJobs(); jobsDialog.showModal(); });
closeJobs.addEventListener('click', () => jobsDialog.close());
jobForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const task = jobTask.value.trim();
  if (!task) return;
  const r = await fetch('/api/jobs', { method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({ repo:jobRepo.value, task }) });
  const data = await r.json();
  if (!r.ok) return alert(data.error || 'Không tạo được job');
  jobTask.value = '';
  await loadJobs();
});

const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
if (SpeechRecognition) {
  mic.addEventListener('click', () => {
    const recognition = new SpeechRecognition();
    recognition.lang = 'vi-VN';
    recognition.interimResults = false;
    recognition.onresult = (event) => { input.value = event.results[0][0].transcript; autoSize(); };
    recognition.start();
  });
} else {
  mic.style.display = 'none';
}

if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
renderHistory();
refreshHealth();
setInterval(refreshHealth, 30_000);
