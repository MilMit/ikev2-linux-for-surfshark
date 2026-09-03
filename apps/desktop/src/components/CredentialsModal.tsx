import React, { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Shield, Key, User, Lock, CheckCircle2, AlertCircle, X, LoaderCircle } from 'lucide-react';
import { useI18n } from '../i18n/LanguageContext';

interface CredentialsModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSuccess: (msg: string) => void;
}

export const CredentialsModal: React.FC<CredentialsModalProps> = ({ isOpen, onClose, onSuccess }) => {
  const { t } = useI18n();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [isSaved, setIsSaved] = useState(false);
  const [loading, setLoading] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!isOpen) return;
    setLoading(true);
    setError('');
    invoke<string>('helper_action', { action: 'credentials-status', args: [] })
      .then(out => {
        setIsSaved(out.includes('SAVED=1'));
      })
      .catch(() => setIsSaved(false))
      .finally(() => setLoading(false));

    // Try reading cached username from localStorage if present
    const cachedUser = localStorage.getItem('milmit-surfshark-service-user');
    if (cachedUser) setUsername(cachedUser);
  }, [isOpen]);

  if (!isOpen) return null;

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!username.trim() || !password.trim()) {
      setError('Both service username and password are required.');
      return;
    }

    setSaving(true);
    setError('');
    try {
      // Save credentials via Tauri command / helper action
      await invoke('save_service_credentials', { username: username.trim(), password: password.trim() });
      localStorage.setItem('milmit-surfshark-service-user', username.trim());
      setIsSaved(true);
      setPassword('');
      onSuccess('Surfshark service credentials saved securely.');
      setTimeout(() => onClose(), 600);
    } catch (err) {
      setError(`Failed to save: ${String(err)}`);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="credentials-overlay" onClick={onClose}>
      <div className="credentials-card" onClick={e => e.stopPropagation()} role="dialog" aria-modal="true">
        <div className="credentials-head">
          <div className="credentials-head-title">
            <div className="cred-icon-box">
              <Key size={18} />
            </div>
            <div>
              <h3>{t('credentialsModalTitle')}</h3>
              <small>{t('credentialsModalDesc')}</small>
            </div>
          </div>
          <button className="icon-btn-close" onClick={onClose} aria-label={t('close')}>
            <X size={20} />
          </button>
        </div>

        <form onSubmit={handleSave} className="credentials-body">
          <div className="credentials-note-box">
            <Shield size={16} />
            <p>{t('credentialsModalDesc')}</p>
          </div>

          <div className={`credentials-status-pill ${isSaved ? 'ok' : 'pending'}`}>
            {loading ? (
              <LoaderCircle size={15} className="spin" />
            ) : isSaved ? (
              <CheckCircle2 size={16} />
            ) : (
              <AlertCircle size={16} />
            )}
            <span>{loading ? '...' : isSaved ? t('credentialsSaved') : '—'}</span>
          </div>

          {error && <div className="credentials-error-box">{error}</div>}

          <div className="input-group">
            <label htmlFor="service-user">
              <User size={14} /> {t('username')}
            </label>
            <input
              id="service-user"
              type="text"
              value={username}
              onChange={e => setUsername(e.target.value)}
              placeholder="e.g. 74kLwQ90aB..."
              autoComplete="username"
              spellCheck={false}
              required
            />
          </div>

          <div className="input-group">
            <label htmlFor="service-pass">
              <Lock size={14} /> {t('password')}
            </label>
            <input
              id="service-pass"
              type="password"
              value={password}
              onChange={e => setPassword(e.target.value)}
              placeholder="••••••••••••••••••••"
              autoComplete="new-password"
              required
            />
          </div>

          <div className="credentials-actions">
            <button type="button" className="btn-secondary" onClick={onClose} disabled={saving}>
              {t('cancel')}
            </button>
            <button type="submit" className="btn-primary" disabled={saving || !username.trim() || !password.trim()}>
              {saving ? <LoaderCircle size={16} className="spin" /> : <Key size={16} />}
              {saving ? '...' : t('saveCredentials')}
            </button>
          </div>

          <div className="security-notice">
            <span>🔒 Stored securely: Protected by root boundary helper and never saved in plaintext configs.</span>
          </div>
        </form>
      </div>
    </div>
  );
};
