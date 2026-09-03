import React from 'react';
import { Laptop, ArrowRight, ShieldCheck, Zap } from 'lucide-react';

interface RouteBeamProps {
  connected: boolean;
  connecting: boolean;
  userIp?: string | null;
  selectedCity: string;
  selectedCountry: string;
  selectedFlag: string;
  ping?: number | null;
}

export const RouteBeam: React.FC<RouteBeamProps> = ({
  connected,
  connecting,
  userIp,
  selectedCity,
  selectedCountry,
  selectedFlag,
  ping,
}) => {
  return (
    <div className={`route-beam-card ${connected ? 'is-connected' : connecting ? 'is-connecting' : 'is-idle'}`}>
      <div className="route-node origin">
        <div className="node-icon-box">
          <Laptop size={16} />
        </div>
        <div className="node-info">
          <span className="node-title">Your Device</span>
          <span className="node-subtitle">{userIp ? `${userIp}` : 'Direct Network'}</span>
        </div>
      </div>

      <div className="route-beam-line-wrap">
        <div className="beam-track">
          <div className={`beam-pulse ${connected ? 'active-connected' : connecting ? 'active-connecting' : ''}`} />
        </div>
        <div className="beam-center-badge">
          {connected ? (
            <ShieldCheck size={14} className="icon-shield" />
          ) : connecting ? (
            <Zap size={14} className="icon-zap spin" />
          ) : (
            <ArrowRight size={14} className="icon-arrow" />
          )}
        </div>
      </div>

      <div className="route-node destination">
        <div className="node-icon-box flag-box">
          <span className="flag-emoji">{selectedFlag}</span>
        </div>
        <div className="node-info">
          <span className="node-title">{selectedCountry}</span>
          <span className="node-subtitle">{selectedCity}</span>
        </div>
        {typeof ping === 'number' && (
          <div className={`ping-chip ${ping < 100 ? 'good' : ping < 200 ? 'medium' : 'high'}`}>
            <span className="ping-dot" />
            <span>{ping}ms</span>
          </div>
        )}
      </div>
    </div>
  );
};
