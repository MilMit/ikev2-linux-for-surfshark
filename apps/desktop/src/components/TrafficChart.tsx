import React, { useMemo } from 'react';

interface TrafficChartProps {
  history: { rx: number; tx: number }[];
  currentRx: number;
  currentTx: number;
}

function fmtRateShort(n: number) {
  if (!Number.isFinite(n) || n <= 0) return '0 B/s';
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

export const TrafficChart: React.FC<TrafficChartProps> = ({ history, currentRx, currentTx }) => {
  const maxPoints = 24;
  const data = useMemo(() => {
    const padded = [...history];
    while (padded.length < maxPoints) {
      padded.unshift({ rx: 0, tx: 0 });
    }
    return padded.slice(-maxPoints);
  }, [history]);

  const maxVal = useMemo(() => {
    const peak = Math.max(...data.map(d => Math.max(d.rx, d.tx)), 1024 * 10);
    return peak * 1.15;
  }, [data]);

  const width = 320;
  const height = 75;

  const pointsRx = useMemo(() => {
    return data.map((d, i) => {
      const x = (i / (maxPoints - 1)) * width;
      const y = height - (d.rx / maxVal) * (height - 10) - 5;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });
  }, [data, maxVal]);

  const pointsTx = useMemo(() => {
    return data.map((d, i) => {
      const x = (i / (maxPoints - 1)) * width;
      const y = height - (d.tx / maxVal) * (height - 10) - 5;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    });
  }, [data, maxVal]);

  const pathRx = `M ${pointsRx.join(' L ')}`;
  const areaRx = `${pathRx} L ${width},${height} L 0,${height} Z`;

  const pathTx = `M ${pointsTx.join(' L ')}`;
  const areaTx = `${pathTx} L ${width},${height} L 0,${height} Z`;

  return (
    <div className="traffic-chart-container">
      <div className="traffic-chart-header">
        <div className="traffic-badge rx">
          <span className="dot pulse-rx" />
          <span className="label">↓ {fmtRateShort(currentRx)}</span>
        </div>
        <div className="traffic-badge tx">
          <span className="dot pulse-tx" />
          <span className="label">↑ {fmtRateShort(currentTx)}</span>
        </div>
      </div>
      <div className="traffic-chart-svg-wrap">
        <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" className="traffic-chart-svg">
          <defs>
            <linearGradient id="rxGrad" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#10b981" stopOpacity="0.45" />
              <stop offset="100%" stopColor="#10b981" stopOpacity="0.0" />
            </linearGradient>
            <linearGradient id="txGrad" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#38bdf8" stopOpacity="0.35" />
              <stop offset="100%" stopColor="#38bdf8" stopOpacity="0.0" />
            </linearGradient>
          </defs>
          <path d={areaRx} fill="url(#rxGrad)" />
          <path d={areaTx} fill="url(#txGrad)" />
          <path d={pathRx} fill="none" stroke="#10b981" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
          <path d={pathTx} fill="none" stroke="#38bdf8" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>
    </div>
  );
};
