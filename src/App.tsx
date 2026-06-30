import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import "./App.css";

interface ClientMetadata {
  deviceModel: string;
  androidVersion: string;
  capabilities: {
    microphone: boolean;
    camera: boolean;
    speaker: boolean;
  };
}

interface AudioStats {
  status: string;
  bitrate: number;
  packets: number;
  latency: number;
  micBytes: number;
  speakerBytes: number;
  speakerActive: boolean;
}

const MicrophoneIcon = () => (
  <svg
    viewBox="0 0 24 24"
    width="20"
    height="20"
    stroke="currentColor"
    strokeWidth="2"
    fill="none"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
    <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
    <line x1="12" x2="12" y1="19" y2="22" />
  </svg>
);

const SpeakerIcon = () => (
  <svg
    viewBox="0 0 24 24"
    width="20"
    height="20"
    stroke="currentColor"
    strokeWidth="2"
    fill="none"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
    <path d="M15.54 8.46a5 5 0 0 1 0 7.07" />
    <path d="M19.07 4.93a10 10 0 0 1 0 14.14" />
  </svg>
);

const RadarMicIcon = () => (
  <svg
    viewBox="0 0 24 24"
    width="32"
    height="32"
    stroke="currentColor"
    strokeWidth="2.5"
    fill="none"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
    <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
    <line x1="12" x2="12" y1="19" y2="22" />
  </svg>
);

function App() {
  const [ipAddress, setIpAddress] = useState<string>("Retrieving IP...");
  const [connectionStatus, setConnectionStatus] = useState<string>("Listening");
  const [clientMetadata, setClientMetadata] = useState<ClientMetadata | null>(null);
  const [audioStats, setAudioStats] = useState<AudioStats | null>(null);
  const [pairingCode, setPairingCode] = useState<string>("------");

  const [routeSpeakers, setRouteSpeakers] = useState<boolean>(true);
  const [routeVirtualMic, setRouteVirtualMic] = useState<boolean>(false);
  const [audioError, setAudioError] = useState<string>("");

  // Speaker Stream (PC → Phone) State
  const [speakerStreamStatus, setSpeakerStreamStatus] = useState<string>("Idle");
  const [speakerStreamError, setSpeakerStreamError] = useState<string>("");

  const [minimizeToTray, setMinimizeToTray] = useState<boolean>(true);

  useEffect(() => {
    // Retrieve host IP address
    invoke<string>("get_local_ip")
      .then((ip) => setIpAddress(ip))
      .catch((err) => {
        console.error("Failed to retrieve local IP:", err);
        setIpAddress("Unavailable");
      });

    // Retrieve active pairing code
    invoke<string>("get_pairing_code")
      .then((code) => setPairingCode(code))
      .catch((err) => console.error("Failed to retrieve pairing code:", err));



    // Listen to connection state updates
    const unlistenStatusPromise = listen<string>("connection-status", (event) => {
      setConnectionStatus(event.payload);
    });

    // Listen to client metadata updates
    const unlistenMetadataPromise = listen<string>("client-metadata", (event) => {
      const payload = event.payload.trim();
      if (!payload) {
        setClientMetadata(null);
      } else {
        try {
          const parsed: ClientMetadata = JSON.parse(payload);
          setClientMetadata(parsed);
        } catch (e) {
          console.error("Failed to parse client metadata:", e);
        }
      }
    });

    // Listen to audio streaming stats
    const unlistenStatsPromise = listen<string>("audio-stats", (event) => {
      try {
        const parsed: AudioStats = JSON.parse(event.payload);
        setAudioStats(parsed);
      } catch (e) {
        console.error("Failed to parse audio stats:", e);
      }
    });

    // Listen to audio routing/device errors
    const unlistenErrorPromise = listen<string>("audio-error", (event) => {
      setAudioError(event.payload);
      setTimeout(() => setAudioError(""), 5000);
    });

    // Listen to pairing code changes
    const unlistenPairingPromise = listen<string>("pairing-code-changed", (event) => {
      setPairingCode(event.payload);
    });

    // Listen to speaker stream status
    const unlistenSpeakerPromise = listen<string>("speaker-stream-status", (event) => {
      setSpeakerStreamStatus(event.payload);
      if (event.payload !== "Error") setSpeakerStreamError("");
    });

    return () => {

      unlistenStatusPromise.then((unlisten) => unlisten());
      unlistenMetadataPromise.then((unlisten) => unlisten());
      unlistenStatsPromise.then((unlisten) => unlisten());
      unlistenErrorPromise.then((unlisten) => unlisten());
      unlistenPairingPromise.then((unlisten) => unlisten());
      unlistenSpeakerPromise.then((unlisten) => unlisten());
    };
  }, []);

  const isConnected = connectionStatus === "Connected";

  const handleRoutingChange = async (speakers: boolean, vmic: boolean) => {
    setRouteSpeakers(speakers);
    setRouteVirtualMic(vmic);
    try {
      await invoke("update_audio_routing", {
        enableSpeakers: speakers,
        enableVirtualMic: vmic
      });
    } catch (e) {
      console.error("Failed to update audio routing state:", e);
    }
  };


  const handleSpeakerStreamToggle = async () => {
    if (speakerStreamStatus === "Streaming") {
      try {
        await invoke("stop_speaker_stream");
      } catch (e) {
        setSpeakerStreamStatus("Idle");
        setSpeakerStreamError(String(e));
        console.error("Failed to stop speaker stream:", e);
      }
    } else {
      try {
        await invoke("start_speaker_stream");
      } catch (e) {
        setSpeakerStreamStatus("Error");
        setSpeakerStreamError(String(e));
        console.error("Failed to start speaker stream:", e);
      }
    }
  };

  const getSpeakerStatusColor = (status: string) => {
    switch (status) {
      case "Streaming":
        return "var(--accent-green)";
      case "Error":
        return "#ff1744";
      default:
        return "var(--text-secondary)";
    }
  };

  const handleMinimizeToTrayChange = async () => {
    const newValue = !minimizeToTray;
    setMinimizeToTray(newValue);
    try {
      await invoke("update_tray_config", { minimizeToTray: newValue });
    } catch (e) {
      console.error("Failed to update tray config:", e);
    }
  };

  const handleRegenerateCode = async () => {
    try {
      const code = await invoke<string>("regenerate_pairing_code");
      setPairingCode(code);
    } catch (e) {
      console.error("Failed to regenerate code:", e);
    }
  };

  const getAudioStatusText = (status: string) => {
    switch (status) {
      case "Receiving":
        return "Streaming Audio";
      case "Waiting":
        return "Waiting for Audio";
      case "Timeout":
        return "Audio Stream Timeout";
      case "Stopped":
      default:
        return "Audio Stopped";
    }
  };

  const getAudioStatusColor = (status: string) => {
    switch (status) {
      case "Receiving":
        return "var(--accent-green)";
      case "Waiting":
        return "var(--accent-orange)";
      case "Timeout":
        return "var(--accent-orange)";
      case "Stopped":
      default:
        return "var(--text-secondary)";
    }
  };

  const getUiConnectionStatusText = () => {
    if (connectionStatus === "Listening") {
      return "Waiting for Device";
    }
    return connectionStatus;
  };

  const formatDataSize = (bytes: number | undefined) => {
    if (bytes === undefined) return "0.00 MB / 0.0000 GB";
    const mb = (bytes / (1024 * 1024)).toFixed(2);
    const gb = (bytes / (1024 * 1024 * 1024)).toFixed(4);
    return `${mb} MB / ${gb} GB`;
  };

  return (
    <div className={`dashboard ${isConnected ? "connected" : "listening"}`}>
      <div className="bg-glow glow-1"></div>
      <div className="bg-glow glow-2"></div>
      <div className="bg-glow glow-3"></div>
      {isConnected ? (
        <>


          <div className="left-panel">
            <header className="app-header">
              <h1 className="app-title">AirMic</h1>
              <p className="app-subtitle">Wireless mic & camera receiver</p>
            </header>

            <div className="status-indicator-container">
              <div className="status-ring-outer">
                <div className="status-ring-inner">
                  <div className="status-core">
                    <span className="status-icon">
                      <RadarMicIcon />
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <div className="info-card">
              <div className="info-row">
                <span className="info-label">Status</span>
                <span className="status-badge connected">{connectionStatus}</span>
              </div>
              <div className="info-row">
                <span className="info-label">IP Address</span>
                <span className="info-value ip-value">{ipAddress}</span>
              </div>
              <div className="info-row">
                <span className="info-label">Minimize to Tray</span>
                <button
                  onClick={handleMinimizeToTrayChange}
                  className={`tray-toggle-btn ${minimizeToTray ? "active" : ""}`}
                >
                  <span className="tray-toggle-track">
                    <span className="tray-toggle-thumb"></span>
                  </span>
                  <span className="tray-toggle-label">{minimizeToTray ? "On" : "Off"}</span>
                </button>
              </div>
            </div>
          </div>

          <div className="mid-panel">
            <div className="client-card">
              <h3 className="client-card-title">Audio Output Routing</h3>
              
              <div className="routing-toggles-container" style={{ marginTop: "0.4rem" }}>
                <button
                  onClick={() => handleRoutingChange(!routeSpeakers, routeVirtualMic)}
                  className={`routing-toggle-btn ${routeSpeakers ? "active-speakers" : ""}`}
                >
                  <div className="toggle-btn-icon">
                    <SpeakerIcon />
                  </div>
                  <div className="toggle-btn-content">
                    <span className="toggle-btn-title">Speakers</span>
                    <span className="toggle-btn-status">{routeSpeakers ? "Active" : "Off"}</span>
                  </div>
                </button>

                <button
                  onClick={() => handleRoutingChange(routeSpeakers, !routeVirtualMic)}
                  className={`routing-toggle-btn ${routeVirtualMic ? "active-vmic" : ""}`}
                >
                  <div className="toggle-btn-icon">
                    <MicrophoneIcon />
                  </div>
                  <div className="toggle-btn-content">
                    <span className="toggle-btn-title">AirMic Mic</span>
                    <span className="toggle-btn-status">{routeVirtualMic ? "Active" : "Off"}</span>
                  </div>
                </button>
              </div>

              <div className="driver-active-badge" style={{ marginTop: "0.8rem", padding: "0.5rem 0.7rem" }}>
                <span className="driver-active-dot"></span>
                <span>
                  <strong>AirMic Speaker</strong> ready — set as default playback in Sound Settings for PC audio → Phone
                </span>
              </div>

              {audioStats && (
                <div style={{ marginTop: "0.8rem", paddingTop: "0.6rem", borderTop: "1px solid rgba(255, 255, 255, 0.04)" }}>
                  <div className="info-row" style={{ marginBottom: "0.3rem" }}>
                    <span className="info-label">Mic State</span>
                    <span className="info-value" style={{ color: getAudioStatusColor(audioStats.status), fontSize: "0.9rem" }}>
                      {getAudioStatusText(audioStats.status)}
                    </span>
                  </div>
                  <div className="info-row" style={{ marginBottom: "0.3rem" }}>
                    <span className="info-label">Mic Bitrate</span>
                    <span className="info-value" style={{ color: "var(--accent-cyan)", fontSize: "0.9rem" }}>
                      {audioStats.bitrate.toFixed(1)} kbps
                    </span>
                  </div>
                  <div className="info-row" style={{ marginBottom: "0.3rem" }}>
                    <span className="info-label">Mic Latency</span>
                    <span className="info-value" style={{ color: audioStats.latency > 100 ? "var(--accent-orange)" : "var(--accent-green)", fontSize: "0.9rem" }}>
                      {audioStats.latency} ms
                    </span>
                  </div>
                  <div className="info-row" style={{ marginBottom: "0.3rem" }}>
                    <span className="info-label">Mic Data</span>
                    <span className="info-value" style={{ color: "var(--accent-cyan)", fontSize: "0.85rem" }}>
                      {formatDataSize(audioStats.micBytes)}
                    </span>
                  </div>
                </div>
              )}

              {audioError && (
                <div className="audio-error-message" style={{ padding: "0.5rem", marginTop: "0.5rem" }}>
                  {audioError}
                </div>
              )}
            </div>

            <div className="client-card">
              <h3 className="client-card-title">PC Audio → Phone (AirMic Speaker)</h3>
              <p style={{ fontSize: "0.72rem", color: "var(--text-muted)", margin: "0 0 0.6rem", lineHeight: 1.4 }}>
                Captures audio from <strong>AirMic Speaker</strong> (CABLE-A) via WASAPI loopback and streams it to your phone.
              </p>
              <div className="speaker-stream-controls">
                <div className="speaker-stream-status-row">
                  <span className="speaker-stream-indicator" style={{ background: getSpeakerStatusColor(speakerStreamStatus) }}></span>
                  <span className="speaker-stream-label" style={{ color: getSpeakerStatusColor(speakerStreamStatus) }}>
                    {speakerStreamStatus}
                  </span>
                </div>
                <button
                  onClick={handleSpeakerStreamToggle}
                  className={`speaker-stream-btn ${speakerStreamStatus === "Streaming" ? "stop" : "start"}`}
                >
                  {speakerStreamStatus === "Streaming" ? "Stop" : "Start"}
                </button>
              </div>
              {audioStats && (
                <div style={{ marginTop: "0.8rem", paddingTop: "0.6rem", borderTop: "1px solid rgba(255, 255, 255, 0.04)" }}>
                  <div className="info-row" style={{ marginBottom: "0.3rem" }}>
                    <span className="info-label">Speaker Data</span>
                    <span className="info-value" style={{ color: "var(--accent-cyan)", fontSize: "0.85rem" }}>
                      {formatDataSize(audioStats.speakerBytes)}
                    </span>
                  </div>
                </div>
              )}
              {speakerStreamError && (
                <div className="audio-error-message" style={{ padding: "0.4rem", marginTop: "0.5rem", fontSize: "0.75rem" }}>
                  {speakerStreamError}
                </div>
              )}
            </div>
          </div>

          <div className="right-panel">
            {clientMetadata && (
              <div className="client-card">
                <h3 className="client-card-title">Connected Device</h3>
                <div className="info-row" style={{ marginBottom: "0.5rem" }}>
                  <span className="info-label">Device</span>
                  <span className="info-value" style={{ color: "var(--accent-green)" }}>
                    {clientMetadata.deviceModel}
                  </span>
                </div>
                <div className="info-row" style={{ marginBottom: "0.5rem" }}>
                  <span className="info-label">Version</span>
                  <span className="info-value" style={{ fontSize: "0.95rem" }}>Android {clientMetadata.androidVersion}</span>
                </div>

                <div className="capabilities-container" style={{ marginTop: "0.6rem" }}>
                  <div className={`capability-item ${clientMetadata.capabilities.microphone ? "enabled" : ""}`}>
                    <MicrophoneIcon />
                    <span>Microphone</span>
                  </div>
                  <div className={`capability-item ${clientMetadata.capabilities.speaker ? "enabled" : ""}`}>
                    <SpeakerIcon />
                    <span>Speaker</span>
                  </div>
                </div>
              </div>
            )}

            {audioStats && (
              <div className="client-card" style={{ background: "rgba(0, 242, 254, 0.005)", borderColor: "rgba(0, 242, 254, 0.04)" }}>
                <h3 className="client-card-title" style={{ color: "var(--accent-cyan)", borderBottomColor: "rgba(0, 242, 254, 0.04)" }}>
                  Session Data Usage
                </h3>
                <div className="info-row" style={{ marginBottom: "0.4rem" }}>
                  <span className="info-label">Uplink (Mic)</span>
                  <span className="info-value" style={{ color: "var(--text-primary)", fontSize: "0.82rem" }}>
                    {formatDataSize(audioStats.micBytes)}
                  </span>
                </div>
                <div className="info-row" style={{ marginBottom: "0.4rem" }}>
                  <span className="info-label">Downlink (Speaker)</span>
                  <span className="info-value" style={{ color: "var(--text-primary)", fontSize: "0.82rem" }}>
                    {formatDataSize(audioStats.speakerBytes)}
                  </span>
                </div>
                <div className="info-row" style={{ marginTop: "0.5rem", paddingTop: "0.5rem", borderTop: "1px solid rgba(255, 255, 255, 0.04)" }}>
                  <span className="info-label" style={{ fontWeight: "bold" }}>Combined Total</span>
                  <span className="info-value" style={{ color: "var(--accent-cyan)", fontWeight: "bold", fontSize: "0.85rem" }}>
                    {formatDataSize(audioStats.micBytes + audioStats.speakerBytes)}
                  </span>
                </div>
              </div>
            )}
          </div>
        </>
      ) : (
        <>
          <header className="app-header">
            <h1 className="app-title">AirMic</h1>
            <p className="app-subtitle">Wireless microphone & camera receiver</p>
          </header>

          <div className="otp-card">
            <span className="otp-title">Pairing Code</span>
            <div className="otp-display-container">
              {pairingCode.split("").map((digit, idx) => (
                <div key={idx} className="otp-digit-block">
                  {digit}
                </div>
              ))}
            </div>
            <p className="otp-hint">Waiting for device... Enter this code on your mobile app.</p>
            <button className="regenerate-otp-btn" onClick={handleRegenerateCode}>
              Regenerate Code
            </button>
          </div>

          <div className="info-card" style={{ marginTop: "1.5rem" }}>
            <div className="info-row">
              <span className="info-label">Connection Status</span>
              <span className="status-badge">{getUiConnectionStatusText()}</span>
            </div>
            <div className="info-row">
              <span className="info-label">Server IP Address</span>
              <span className="info-value ip-value">{ipAddress}</span>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

export default App;
