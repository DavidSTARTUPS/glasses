import React, { useState, useEffect, useRef } from 'react';
import { 
  Glasses, 
  Bluetooth, 
  Wifi, 
  BatteryCharging, 
  Mic, 
  Camera, 
  Terminal, 
  Bot, 
  User, 
  Sparkles,
  Send,
  RefreshCw,
  Activity
} from 'lucide-react';

export default function App() {
  const [wsConnected, setWsConnected] = useState(false);
  const [state, setState] = useState({
    ble_status: 'Disconnected',
    device_name: 'MT5 Ultra',
    device_mac: '--:--:--:--:--:--',
    rtsp_status: 'Offline',
    audio_status: 'Idle',
    last_snapshot: null,
    battery_level: 85,
  });

  const [logs, setLogs] = useState([]);
  const [conversations, setConversations] = useState([]);
  const [inputText, setInputText] = useState('');

  const terminalEndRef = useRef(null);
  const chatEndRef = useRef(null);
  const wsRef = useRef(null);

  useEffect(() => {
    let ws;
    let reconnectTimeout;

    const connectWebSocket = () => {
      const wsUrl = `ws://${window.location.hostname}:8000/ws`;
      ws = new WebSocket(wsUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        setWsConnected(true);
      };

      ws.onmessage = (event) => {
        try {
          const message = JSON.parse(event.data);

          if (message.type === 'state_update') {
            setState(prev => ({ ...prev, ...message.data }));
          } else if (message.type === 'log') {
            setLogs(prev => [...prev.slice(-150), message.data]);
          } else if (message.type === 'conversation') {
            setConversations(prev => [...prev, message.data]);
          }
        } catch (err) {
          console.error("WS Parse error", err);
        }
      };

      ws.onclose = () => {
        setWsConnected(false);
        reconnectTimeout = setTimeout(connectWebSocket, 2500);
      };

      ws.onerror = () => {
        ws.close();
      };
    };

    connectWebSocket();

    return () => {
      if (ws) ws.close();
      clearTimeout(reconnectTimeout);
    };
  }, []);

  useEffect(() => {
    terminalEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [logs]);

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [conversations]);

  const handleManualSnapshot = () => {
    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ action: 'trigger_snapshot' }));
    }
  };

  const handleSendPrompt = (e) => {
    e.preventDefault();
    if (!inputText.trim()) return;

    if (wsRef.current && wsRef.current.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ action: 'ask_text', prompt: inputText.trim() }));
      setInputText('');
    }
  };

  const getStatusBadge = (status) => {
    switch (status) {
      case 'Connected':
      case 'Online':
        return <span className="flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"><span className="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></span> {status}</span>;
      case 'Connecting':
      case 'Scanning':
        return <span className="flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-amber-500/10 text-amber-400 border border-amber-500/20"><span className="w-2 h-2 rounded-full bg-amber-400 animate-pulse"></span> {status}</span>;
      default:
        return <span className="flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold bg-rose-500/10 text-rose-400 border border-rose-500/20"><span className="w-2 h-2 rounded-full bg-rose-400"></span> {status}</span>;
    }
  };

  const getAudioBadge = (audioStatus) => {
    switch (audioStatus) {
      case 'Listening':
        return <span className="flex items-center gap-1 text-xs px-2.5 py-1 bg-cyan-500/20 text-cyan-300 rounded-md border border-cyan-500/30 font-medium animate-pulse"><Mic className="w-3.5 h-3.5" /> Ascultă microfon</span>;
      case 'Processing':
        return <span className="flex items-center gap-1 text-xs px-2.5 py-1 bg-purple-500/20 text-purple-300 rounded-md border border-purple-500/30 font-medium animate-pulse"><Sparkles className="w-3.5 h-3.5" /> GLM-5.3 Procesează...</span>;
      case 'Speaking':
        return <span className="flex items-center gap-1 text-xs px-2.5 py-1 bg-emerald-500/20 text-emerald-300 rounded-md border border-emerald-500/30 font-medium animate-pulse"><Activity className="w-3.5 h-3.5" /> Redare Voce Emil</span>;
      default:
        return <span className="flex items-center gap-1 text-xs px-2.5 py-1 bg-gray-800 text-gray-400 rounded-md border border-gray-700 font-medium"><Mic className="w-3.5 h-3.5 opacity-50" /> Microfon Standby</span>;
    }
  };

  return (
    <div className="min-h-screen bg-[#0B0F19] text-gray-100 flex flex-col">
      {/* HEADER */}
      <header className="border-b border-gray-800 bg-[#111827]/80 backdrop-blur-md sticky top-0 z-50 px-6 py-3.5 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="p-2 bg-gradient-to-tr from-cyan-600 to-purple-600 rounded-xl shadow-lg shadow-cyan-500/20">
            <Glasses className="w-6 h-6 text-white" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-lg font-bold tracking-tight text-white">MT5 Ultra Smart Glasses</h1>
              <span className="text-[10px] uppercase font-bold tracking-wider px-2 py-0.5 bg-purple-500/20 text-purple-300 border border-purple-500/30 rounded">GLM-5.3-Flash</span>
            </div>
            <p className="text-xs text-gray-400">Autonomous Edge AI &amp; OpenRouter Vision Platform</p>
          </div>
        </div>

        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2 text-xs text-gray-400 bg-gray-900/90 px-3 py-1.5 rounded-lg border border-gray-800">
            <span className={`w-2 h-2 rounded-full ${wsConnected ? 'bg-emerald-400 animate-pulse' : 'bg-rose-500'}`}></span>
            <span>WebSocket {wsConnected ? 'Conectat' : 'Reconectare...'}</span>
          </div>
          {getAudioBadge(state.audio_status)}
        </div>
      </header>

      {/* MAIN CONTAINER */}
      <main className="flex-1 p-6 grid grid-cols-1 lg:grid-cols-12 gap-6 max-w-7xl mx-auto w-full">
        
        {/* LEFT COLUMN: Hardware Status & Live Camera (5 Cols) */}
        <div className="lg:col-span-5 flex flex-col gap-6">
          
          {/* HARDWARE STATUS CARD */}
          <div className="bg-[#111827] border border-gray-800/80 rounded-2xl p-5 shadow-xl shadow-black/40">
            <h2 className="text-sm font-semibold text-gray-300 uppercase tracking-wider mb-4 flex items-center gap-2">
              <Activity className="w-4 h-4 text-cyan-400" /> Stare Hardware Ochelari
            </h2>

            <div className="grid grid-cols-2 gap-3">
              {/* BLE Status */}
              <div className="bg-gray-900/80 border border-gray-800 p-3.5 rounded-xl flex flex-col justify-between">
                <div className="flex items-center justify-between mb-2">
                  <span className="text-xs text-gray-400 flex items-center gap-1.5">
                    <Bluetooth className="w-4 h-4 text-cyan-400" /> Bluetooth BLE
                  </span>
                </div>
                <div>{getStatusBadge(state.ble_status)}</div>
                <div className="text-[11px] font-mono text-gray-400 mt-2 truncate">
                  MAC: <span className="text-gray-200">{state.device_mac || 'N/A'}</span>
                </div>
              </div>

              {/* Wi-Fi RTSP Status */}
              <div className="bg-gray-900/80 border border-gray-800 p-3.5 rounded-xl flex flex-col justify-between">
                <div className="flex items-center justify-between mb-2">
                  <span className="text-xs text-gray-400 flex items-center gap-1.5">
                    <Wifi className="w-4 h-4 text-emerald-400" /> Wi-Fi RTSP
                  </span>
                </div>
                <div>{getStatusBadge(state.rtsp_status)}</div>
                <div className="text-[11px] font-mono text-gray-400 mt-2 truncate">
                  Stream: <span className="text-gray-200">192.168.43.1</span>
                </div>
              </div>

              {/* Battery */}
              <div className="bg-gray-900/80 border border-gray-800 p-3.5 rounded-xl">
                <span className="text-xs text-gray-400 flex items-center gap-1.5 mb-2">
                  <BatteryCharging className="w-4 h-4 text-amber-400" /> Baterie (300mAh)
                </span>
                <div className="flex items-baseline gap-2">
                  <span className="text-xl font-bold text-white">{state.battery_level}%</span>
                  <span className="text-[11px] text-emerald-400">Optimizat On-Demand</span>
                </div>
              </div>

              {/* Model Vision */}
              <div className="bg-gray-900/80 border border-gray-800 p-3.5 rounded-xl">
                <span className="text-xs text-gray-400 flex items-center gap-1.5 mb-2">
                  <Sparkles className="w-4 h-4 text-purple-400" /> AI Engine
                </span>
                <div className="text-xs font-semibold text-purple-300">GLM-5.3-Flash</div>
                <div className="text-[11px] text-gray-400">edge-tts (ro-RO-Emil)</div>
              </div>
            </div>
          </div>

          {/* LIVE CAMERA SNAPSHOT CARD */}
          <div className="bg-[#111827] border border-gray-800/80 rounded-2xl p-5 shadow-xl shadow-black/40 flex-1 flex flex-col">
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-sm font-semibold text-gray-300 uppercase tracking-wider flex items-center gap-2">
                <Camera className="w-4 h-4 text-cyan-400" /> Vizualizare Cameră (Snapshot)
              </h2>
              <button
                onClick={handleManualSnapshot}
                className="flex items-center gap-1.5 px-3 py-1.5 bg-cyan-600/20 hover:bg-cyan-600/30 text-cyan-300 border border-cyan-500/30 text-xs font-medium rounded-lg transition-all active:scale-95"
              >
                <RefreshCw className="w-3.5 h-3.5" /> Fă Poză Acum
              </button>
            </div>

            <div className="flex-1 min-h-[260px] bg-black/60 rounded-xl border border-gray-800 overflow-hidden relative flex items-center justify-center group">
              {state.last_snapshot ? (
                <img 
                  src={`data:image/jpeg;base64,${state.last_snapshot}`} 
                  alt="Glasses Snapshot" 
                  className="w-full h-full object-cover"
                />
              ) : (
                <div className="text-center p-6 text-gray-500">
                  <Camera className="w-12 h-12 mx-auto mb-2 opacity-30 stroke-[1.5]" />
                  <p className="text-sm font-medium">Niciun cadru capturat încă</p>
                  <p className="text-xs mt-1 text-gray-600">Camera se declanșează automat când pui o întrebare.</p>
                </div>
              )}

              {state.last_snapshot && (
                <div className="absolute top-3 left-3 bg-black/70 backdrop-blur-md px-2.5 py-1 rounded-md text-[10px] font-mono text-emerald-400 border border-white/10 flex items-center gap-1">
                  <span className="w-1.5 h-1.5 rounded-full bg-emerald-400"></span> LIVE CAPTURE 1080P
                </div>
              )}
            </div>
          </div>

        </div>

        {/* RIGHT COLUMN: Chat Conversation & Terminal Debug Logs (7 Cols) */}
        <div className="lg:col-span-7 flex flex-col gap-6">
          
          {/* CONVERSATION HISTORY */}
          <div className="bg-[#111827] border border-gray-800/80 rounded-2xl p-5 shadow-xl shadow-black/40 flex flex-col h-[400px]">
            <h2 className="text-sm font-semibold text-gray-300 uppercase tracking-wider mb-4 flex items-center gap-2">
              <Bot className="w-4 h-4 text-purple-400" /> Istoric Conversație Asistent AI
            </h2>

            <div className="flex-1 overflow-y-auto space-y-4 pr-2">
              {conversations.length === 0 ? (
                <div className="h-full flex flex-col items-center justify-center text-center text-gray-500">
                  <Bot className="w-10 h-10 mb-2 opacity-20" />
                  <p className="text-sm">Vorbește cu ochelarii sau scrie o întrebare mai jos.</p>
                  <p className="text-xs text-gray-600 mt-1">Ex: „Ce am în fața mea?” sau „Citește eticheta asta”</p>
                </div>
              ) : (
                conversations.map((msg, idx) => (
                  <div key={idx} className={`flex gap-3 ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                    {msg.role === 'assistant' && (
                      <div className="w-7 h-7 rounded-lg bg-purple-600/30 border border-purple-500/40 flex items-center justify-center shrink-0">
                        <Bot className="w-4 h-4 text-purple-300" />
                      </div>
                    )}
                    <div className={`max-w-[80%] rounded-2xl p-3.5 text-sm ${
                      msg.role === 'user' 
                        ? 'bg-cyan-600/20 text-cyan-100 border border-cyan-500/30' 
                        : 'bg-gray-800/80 text-gray-200 border border-gray-700/60'
                    }`}>
                      <div className="flex items-center justify-between gap-4 mb-1 text-[10px] opacity-60">
                        <span>{msg.role === 'user' ? 'Utilizator (Voce / Text)' : 'GLM-5.3-Flash'}</span>
                        <span>{msg.timestamp}</span>
                      </div>
                      <p className="leading-relaxed">{msg.text}</p>
                    </div>
                    {msg.role === 'user' && (
                      <div className="w-7 h-7 rounded-lg bg-cyan-600/30 border border-cyan-500/40 flex items-center justify-center shrink-0">
                        <User className="w-4 h-4 text-cyan-300" />
                      </div>
                    )}
                  </div>
                ))
              )}
              <div ref={chatEndRef} />
            </div>

            {/* Test Prompt Input */}
            <form onSubmit={handleSendPrompt} className="mt-4 flex gap-2">
              <input
                type="text"
                placeholder="Testează o întrebare (ex: Ce obiect vezi în cadru?)..."
                value={inputText}
                onChange={(e) => setInputText(e.target.value)}
                className="flex-1 bg-gray-900 border border-gray-700 rounded-xl px-4 py-2 text-sm text-gray-200 placeholder-gray-500 focus:outline-none focus:border-cyan-500 transition-colors"
              />
              <button
                type="submit"
                className="bg-gradient-to-r from-cyan-600 to-purple-600 hover:from-cyan-500 hover:to-purple-500 text-white px-4 py-2 rounded-xl text-sm font-semibold flex items-center gap-1.5 transition-all active:scale-95"
              >
                <Send className="w-4 h-4" /> Trimite
              </button>
            </form>
          </div>

          {/* REAL-TIME TERMINAL LOGS */}
          <div className="bg-[#0D1117] border border-gray-800/80 rounded-2xl p-5 shadow-xl shadow-black/40 flex flex-col h-[280px]">
            <div className="flex items-center justify-between mb-2">
              <h2 className="text-sm font-semibold text-gray-300 uppercase tracking-wider flex items-center gap-2 font-mono">
                <Terminal className="w-4 h-4 text-emerald-400" /> Live System Logs
              </h2>
              <span className="text-[10px] font-mono text-gray-500">{logs.length} mesaje</span>
            </div>

            <div className="flex-1 overflow-y-auto bg-black/70 p-3 rounded-xl border border-gray-800/90 font-mono text-xs space-y-1 text-gray-300">
              {logs.length === 0 ? (
                <div className="text-gray-600">Se așteaptă evenimente BLE &amp; AI...</div>
              ) : (
                logs.map((log, i) => (
                  <div key={i} className="flex gap-2 leading-relaxed">
                    <span className="text-gray-500 shrink-0">[{log.timestamp}]</span>
                    <span className={
                      log.level === 'error' ? 'text-rose-400' :
                      log.level === 'warning' ? 'text-amber-400' :
                      'text-gray-200'
                    }>
                      {log.message}
                    </span>
                  </div>
                ))
              )}
              <div ref={terminalEndRef} />
            </div>
          </div>

        </div>

      </main>
    </div>
  );
}
