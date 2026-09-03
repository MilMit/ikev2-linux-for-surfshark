import React, { useState, useEffect, useRef, useMemo } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Terminal, Copy, Check, Trash2, Search, ArrowDown, Pause, Play, X, ShieldAlert } from 'lucide-react';
import { useI18n } from '../i18n/LanguageContext';

interface LogTerminalProps {
  isOpen: boolean;
  onClose: () => void;
}

interface LogEntry {
  id: string;
  timestamp: string;
  level: 'info' | 'warning' | 'error' | 'success';
  text: string;
}

function redact(v: string) {
  return v
    .replace(/SERVICE_(?:USER|PASS)=[^\s]+/gi, 'SERVICE_CREDENTIAL=[redacted]')
    .replace(/secret\s*=\s*"[^"]+"/gi, 'secret = [redacted]')
    .replace(/password[^\n]*/gi, 'password=[redacted]')
    .replace(/(^|\n)(\s*)(?:eap_id|id):\s*[A-Za-z0-9_-]{16,}(?=\s|$)/gi, '$1$2identity: [redacted]')
    .replace(/(^|\n)(\s*local\s+)'[^']+'\s+@/gi, "$1$2'[redacted]' @")
    .replace(/sending\s+'[A-Za-z0-9_-]{16,}'/gi, "sending '[redacted]'");
}

function detectLevel(line: string): 'info' | 'warning' | 'error' | 'success' {
  if (/error|failed|timeout|reject|fail|fatal|denied/i.test(line)) return 'error';
  if (/warn|warning|fallback|retrying/i.test(line)) return 'warning';
  if (/success|connected|completed|established|verified|ok/i.test(line)) return 'success';
  return 'info';
}

export const LogTerminal: React.FC<LogTerminalProps> = ({ isOpen, onClose }) => {
  const { t } = useI18n();
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [filter, setFilter] = useState('');
  const [levelFilter, setLevelFilter] = useState<'all' | 'error' | 'warning' | 'success'>('all');
  const [isPaused, setIsPaused] = useState(false);
  const [copied, setCopied] = useState(false);
  const lastBackendRef = useRef('');
  const logContainerRef = useRef<HTMLDivElement>(null);

  // Poll backend log updates
  useEffect(() => {
    if (!isOpen) return;

    const pull = async () => {
      if (isPaused) return;
      try {
        const raw = await invoke<string>('connection_attempt_log');
        if (raw && raw !== lastBackendRef.current) {
          const delta = raw.startsWith(lastBackendRef.current)
            ? raw.slice(lastBackendRef.current.length).replace(/^\n/, '')
            : raw;
          lastBackendRef.current = raw;

          if (delta.trim()) {
            const time = new Date().toLocaleTimeString([], { hour12: false });
            const newLines: LogEntry[] = redact(delta)
              .split('\n')
              .filter(l => l.trim().length > 0)
              .map((line, idx) => ({
                id: `${Date.now()}-${idx}-${Math.random()}`,
                timestamp: time,
                level: detectLevel(line),
                text: line,
              }));

            setLogs(prev => [...prev.slice(-600), ...newLines]);
          }
        }
      } catch {}
    };

    pull();
    const interval = setInterval(pull, 1200);
    return () => clearInterval(interval);
  }, [isOpen, isPaused]);

  // Auto scroll to bottom
  useEffect(() => {
    if (!isPaused && logContainerRef.current) {
      logContainerRef.current.scrollTop = logContainerRef.current.scrollHeight;
    }
  }, [logs, isPaused]);

  const filteredLogs = useMemo(() => {
    return logs.filter(item => {
      if (levelFilter !== 'all' && item.level !== levelFilter) return false;
      if (filter && !item.text.toLowerCase().includes(filter.toLowerCase())) return false;
      return true;
    });
  }, [logs, filter, levelFilter]);

  const handleCopy = () => {
    const text = logs.map(l => `[${l.timestamp}] [${l.level.toUpperCase()}] ${l.text}`).join('\n');
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleClear = () => {
    setLogs([]);
    lastBackendRef.current = '';
  };

  if (!isOpen) return null;

  return (
    <div className="terminal-overlay" onClick={onClose}>
      <div className="terminal-drawer" onClick={e => e.stopPropagation()}>
        {/* Terminal Header */}
        <div className="terminal-header">
          <div className="terminal-title">
            <span className="term-icon">
              <Terminal size={17} />
            </span>
            <b>{t('terminalModalTitle')}</b>
            <span className="log-count-badge">{filteredLogs.length}</span>
          </div>

          <div className="terminal-controls">
            <button
              className={`term-btn ${isPaused ? 'active-pause' : ''}`}
              onClick={() => setIsPaused(!isPaused)}
              title={isPaused ? 'Resume streaming' : 'Pause streaming'}
            >
              {isPaused ? <Play size={14} /> : <Pause size={14} />}
              <span>{isPaused ? 'Paused' : 'Live'}</span>
            </button>
            <button className="term-btn" onClick={handleCopy} title={t('copyLogs')}>
              {copied ? <Check size={14} className="text-emerald" /> : <Copy size={14} />}
              <span>{copied ? t('logsCopied') : t('copyLogs')}</span>
            </button>
            <button className="term-btn" onClick={handleClear} title={t('clearLogs')}>
              <Trash2 size={14} />
              <span>{t('clearLogs')}</span>
            </button>
            <button className="term-close-btn" onClick={onClose} aria-label={t('close')}>
              <X size={18} />
            </button>
          </div>
        </div>

        {/* Filter Bar */}
        <div className="terminal-filter-bar">
          <div className="search-box-term">
            <Search size={14} />
            <input
              type="text"
              placeholder="Search logs (e.g. ike, ip, established, dns)..."
              value={filter}
              onChange={e => setFilter(e.target.value)}
            />
            {filter && (
              <button className="clear-search" onClick={() => setFilter('')}>
                ×
              </button>
            )}
          </div>

          <div className="level-filters">
            {(['all', 'error', 'warning', 'success'] as const).map(lvl => (
              <button
                key={lvl}
                className={`lvl-filter-btn ${levelFilter === lvl ? 'active ' + lvl : ''}`}
                onClick={() => setLevelFilter(lvl)}
              >
                {lvl.toUpperCase()}
              </button>
            ))}
          </div>
        </div>

        {/* Terminal Body */}
        <div className="terminal-body" ref={logContainerRef}>
          {filteredLogs.length === 0 ? (
            <div className="terminal-empty">
              <ShieldAlert size={28} opacity={0.4} />
              <p>{logs.length === 0 ? 'Waiting for connection events or helper output…' : 'No logs match your filter.'}</p>
            </div>
          ) : (
            filteredLogs.map(item => (
              <div key={item.id} className={`terminal-line line-${item.level}`}>
                <span className="log-ts">[{item.timestamp}]</span>
                <span className={`log-lvl-badge ${item.level}`}>{item.level.slice(0, 4).toUpperCase()}</span>
                <span className="log-msg">{item.text}</span>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
};
